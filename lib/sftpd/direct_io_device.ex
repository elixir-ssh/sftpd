defmodule Sftpd.DirectIODevice do
  @moduledoc false

  @type handle :: {:sftpd_direct_io, reference()}

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

    with {:ok, writer_handle} <- backend.open_write(to_string(path), %{}, session, backend_state) do
      handle = new_handle()

      put_state(handle, %{
        mode: :write,
        path: path,
        backend: backend,
        backend_state: backend_state,
        session: session,
        position: 0,
        size: 0,
        writer_handle: writer_handle
      })

      {:ok, handle}
    end
  end

  def start(
        %{path: path, mode: :read_write, backend: backend, backend_state: backend_state} = opts
      ) do
    session = Map.get(opts, :session, %{})
    path = to_string(path)

    with {:ok, writer_handle} <- backend.open_write(path, %{}, session, backend_state) do
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
        writer_handle: writer_handle
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
        result =
          state.backend.write_at(state.writer_handle, state.position, data, state.backend_state)

        case result do
          {:ok, writer_handle} ->
            position = state.position + bytes

            put_state(handle, %{
              state
              | writer_handle: writer_handle,
                position: position,
                size: max(state.size, position)
            })

            :ok

          {:error, reason} ->
            _ = state.backend.abort_write(state.writer_handle, state.backend_state)
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
        state.backend.finish_write(state.writer_handle, state.backend_state)

      %{mode: :read_write} = state ->
        state.backend.finish_write(state.writer_handle, state.backend_state)

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
end
