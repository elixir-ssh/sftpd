defmodule Sftpd.DirectIODevice do
  @moduledoc false

  @type handle :: {:sftpd_direct_io, reference()}

  @replay_chunk_size 5 * 1024 * 1024

  @spec start(map()) :: {:ok, handle()} | {:error, atom()}
  def start(%{path: path, mode: :read, backend: backend, backend_state: backend_state} = opts) do
    session = Map.get(opts, :session, %{})

    with {:ok, attrs} <- backend.file_attrs(to_string(path), session, backend_state),
         {:ok, backend_handle} <- backend.open_read(to_string(path), session, backend_state) do
      handle = new_handle()

      put_state(handle, %{
        mode: :read,
        path: path,
        backend: backend,
        backend_handle: backend_handle,
        backend_state: backend_state,
        session: session,
        position: 0,
        size: Map.get(attrs, :size, 0)
      })

      {:ok, handle}
    end
  end

  def start(%{path: path, mode: :write, backend: backend, backend_state: backend_state} = opts) do
    session = Map.get(opts, :session, %{})

    with {:ok, writer_handle} <- backend.open_write(to_string(path), %{}, session, backend_state),
         {:ok, temp_path, temp_fd} <- open_temp_file(backend, writer_handle, backend_state) do
      handle = new_handle()

      put_state(handle, %{
        mode: :write,
        path: path,
        backend: backend,
        backend_state: backend_state,
        session: session,
        position: 0,
        size: 0,
        writer_handle: writer_handle,
        write_strategy: :direct,
        stream_offset: 0,
        temp_path: temp_path,
        temp_fd: temp_fd
      })

      {:ok, handle}
    end
  end

  def start(
        %{path: path, mode: :read_write, backend: backend, backend_state: backend_state} = opts
      ) do
    session = Map.get(opts, :session, %{})
    path = to_string(path)

    with {:ok, writer_handle} <- backend.open_write(path, %{}, session, backend_state),
         {:ok, temp_path, temp_fd} <- open_temp_file(backend, writer_handle, backend_state) do
      reader_handle =
        case backend.open_read(path, session, backend_state) do
          {:ok, reader_handle} -> reader_handle
          {:error, _reason} -> nil
        end

      size =
        case backend.file_attrs(path, session, backend_state) do
          {:ok, attrs} -> Map.get(attrs, :size, 0)
          {:error, _reason} -> 0
        end

      handle = new_handle()

      put_state(handle, %{
        mode: :read_write,
        path: path,
        backend: backend,
        backend_state: backend_state,
        session: session,
        position: 0,
        size: size,
        backend_handle: reader_handle,
        writer_handle: writer_handle,
        write_strategy: :direct,
        stream_offset: 0,
        temp_path: temp_path,
        temp_fd: temp_fd
      })

      {:ok, handle}
    end
  end

  @spec handle?(term()) :: boolean()
  def handle?({:sftpd_direct_io, ref}) when is_reference(ref), do: true
  def handle?(_handle), do: false

  @spec position(handle(), term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def position(handle, offset) do
    update_state(handle, fn state ->
      case position_from_offset(state, offset) do
        {:ok, position} -> {{:ok, position}, %{state | position: position}}
        {:error, reason} -> {{:error, reason}, state}
      end
    end)
  end

  @spec read(handle(), non_neg_integer()) :: {:ok, binary()} | :eof | {:error, atom()}
  def read(handle, len) do
    update_state(handle, fn
      %{mode: mode, position: position, size: size} = state
      when mode in [:read, :read_write] and position >= size ->
        {:eof, state}

      %{mode: mode, backend_handle: backend_handle} = state
      when mode in [:read, :read_write] and not is_nil(backend_handle) ->
        result =
          state.backend.read_at(state.backend_handle, state.position, len, state.backend_state)

        case result do
          {:ok, data} ->
            data = IO.iodata_to_binary(data)

            if byte_size(data) > 0 do
              {{:ok, data}, %{state | position: state.position + byte_size(data)}}
            else
              {:eof, state}
            end

          :eof ->
            {:eof, state}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      %{mode: :read_write} = state ->
        {{:error, :einval}, state}

      state ->
        {{:error, :einval}, state}
    end)
  end

  @spec write(handle(), iodata(), non_neg_integer()) :: :ok | {:error, atom()}
  def write(handle, data, bytes) do
    case Process.get(key(handle)) do
      nil ->
        {:error, :einval}

      %{mode: mode} = state when mode in [:write, :read_write] ->
        case persist_to_tempfile(state.temp_fd, state.position, data) do
          :ok ->
            position = state.position + bytes
            size = max(state.size, position)

            case maybe_direct_write(state, data, bytes) do
              {:ok, state} ->
                put_state(handle, %{state | position: position, size: size})
                :ok

              {:error, reason} ->
                cleanup_unfinished_write(state)
                _ = pop_state(handle)
                {:error, reason}
            end

          {:error, reason} ->
            cleanup_unfinished_write(state)
            _ = pop_state(handle)
            {:error, reason}
        end

      state ->
        put_state(handle, state)
        {:error, :einval}
    end
  end

  @spec close(handle()) :: :ok | {:error, atom()}
  def close(handle) do
    case pop_state(handle) do
      nil ->
        :ok

      %{mode: :write} = state ->
        finalize_write(state)

      %{mode: :read_write} = state ->
        finalize_write(state)

      %{mode: :read} ->
        :ok
    end
  end

  defp new_handle, do: {:sftpd_direct_io, make_ref()}

  defp key({:sftpd_direct_io, ref}), do: {:sftpd_direct_io, ref}

  defp put_state(handle, state) do
    Process.put(key(handle), state)
  end

  defp pop_state(handle) do
    Process.delete(key(handle))
  end

  defp update_state(handle, fun) do
    case Process.get(key(handle)) do
      nil ->
        {:error, :einval}

      state ->
        {reply, state} = fun.(state)
        put_state(handle, state)
        reply
    end
  end

  defp position_from_offset(%{position: position}, {:cur, offset}) when is_integer(offset) do
    validate_position(position + offset)
  end

  defp position_from_offset(%{size: size}, {:eof, offset}) when is_integer(offset) do
    validate_position(size + offset)
  end

  defp position_from_offset(_state, {:bof, offset}) when is_integer(offset) do
    validate_position(offset)
  end

  defp position_from_offset(_state, offset) when is_integer(offset), do: validate_position(offset)
  defp position_from_offset(_state, _offset), do: {:error, :einval}

  defp validate_position(position) when position >= 0, do: {:ok, position}
  defp validate_position(_position), do: {:error, :einval}

  defp maybe_direct_write(%{write_strategy: :replay} = state, _data, _bytes), do: {:ok, state}

  defp maybe_direct_write(%{position: offset, stream_offset: offset} = state, data, bytes) do
    case state.backend.write_at(state.writer_handle, offset, data, state.backend_state) do
      {:ok, writer_handle} ->
        {:ok, %{state | writer_handle: writer_handle, stream_offset: offset + bytes}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_direct_write(%{write_strategy: :direct} = state, _data, _bytes) do
    _ = state.backend.abort_write(state.writer_handle, state.backend_state)

    {:ok,
     state
     |> Map.put(:write_strategy, :replay)
     |> Map.delete(:writer_handle)
     |> Map.delete(:stream_offset)}
  end

  defp finalize_write(%{write_strategy: :direct} = state) do
    result = state.backend.finish_write(state.writer_handle, state.backend_state)
    cleanup_tempfile(state)
    result
  end

  defp finalize_write(%{write_strategy: :replay} = state) do
    result = replay_tempfile(state)
    cleanup_tempfile(state)
    result
  end

  defp replay_tempfile(%{
         backend: backend,
         backend_state: backend_state,
         session: session,
         path: path,
         temp_fd: temp_fd,
         size: size
       }) do
    with {:ok, writer_handle} <- backend.open_write(to_string(path), %{}, session, backend_state),
         {:ok, writer_handle} <-
           replay_tempfile_chunks(temp_fd, size, writer_handle, backend, backend_state, 0) do
      case backend.finish_write(writer_handle, backend_state) do
        :ok ->
          :ok

        {:error, reason} ->
          _ = backend.abort_write(writer_handle, backend_state)
          {:error, reason}
      end
    else
      {:stream_error, writer_handle, reason} ->
        _ = backend.abort_write(writer_handle, backend_state)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_tempfile_chunks(_temp_fd, size, writer_handle, _backend, _backend_state, offset)
       when offset >= size do
    {:ok, writer_handle}
  end

  defp replay_tempfile_chunks(temp_fd, size, writer_handle, backend, backend_state, offset) do
    bytes_to_read = min(@replay_chunk_size, size - offset)

    with {:ok, data} <- read_temp_chunk(temp_fd, offset, bytes_to_read),
         {:ok, writer_handle} <- backend.write_at(writer_handle, offset, data, backend_state) do
      replay_tempfile_chunks(
        temp_fd,
        size,
        writer_handle,
        backend,
        backend_state,
        offset + byte_size(data)
      )
    else
      {:error, reason} -> {:stream_error, writer_handle, reason}
    end
  end

  defp cleanup_unfinished_write(%{write_strategy: :direct} = state) do
    _ = state.backend.abort_write(state.writer_handle, state.backend_state)
    cleanup_tempfile(state)
  end

  defp cleanup_unfinished_write(state), do: cleanup_tempfile(state)

  defp open_temp_file(backend, writer_handle, backend_state) do
    case open_temp_file(System.tmp_dir!()) do
      {:ok, _temp_path, _temp_fd} = ok ->
        ok

      {:error, reason} ->
        _ = backend.abort_write(writer_handle, backend_state)
        {:error, reason}
    end
  end

  defp open_temp_file(tmp_dir) do
    temp_path = Path.join(tmp_dir, "sftpd-#{random_temp_suffix()}.tmp")

    case :file.open(String.to_charlist(temp_path), [:binary, :raw, :read, :write, :exclusive]) do
      {:ok, fd} ->
        case :file.change_mode(String.to_charlist(temp_path), 0o600) do
          :ok ->
            {:ok, temp_path, fd}

          {:error, reason} ->
            close_fd(fd)
            File.rm(temp_path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp random_temp_suffix do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp persist_to_tempfile(temp_fd, position, data) do
    case :file.pwrite(temp_fd, position, data) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_temp_chunk(temp_fd, offset, length) do
    case :file.pread(temp_fd, offset, length) do
      {:ok, data} -> {:ok, data}
      :eof -> {:error, :eof}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_tempfile(state) do
    close_fd(state.temp_fd)
    remove_temp_file(state.temp_path)
  end

  defp remove_temp_file(temp_path) do
    _ = File.rm(temp_path)
    :ok
  end

  defp close_fd(fd) do
    _ = :file.close(fd)
    :ok
  end
end
