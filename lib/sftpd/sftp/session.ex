defmodule Sftpd.SFTP.Session do
  @moduledoc false

  alias Sftpd.SFTP.{Codec, Handles, Paths, SerializedPacket}

  @max_read_len 1_048_576
  @seed_chunk_size 1_048_576
  @replay_chunk_size 1_048_576

  @type state :: %{
          backend: module(),
          backend_state: term(),
          session: map(),
          handles: %{binary() => term()},
          initialized?: boolean()
        }

  @spec new(module(), term(), map()) :: state()
  def new(backend, backend_state, session \\ %{}) do
    %{
      backend: backend,
      backend_state: backend_state,
      session: session,
      handles: %{},
      initialized?: false
    }
  end

  @spec cleanup_open_handles(state()) :: state()
  def cleanup_open_handles(state) do
    Handles.cleanup_open_handles(state, &cleanup_overlay/1)
  end

  @spec abort_open_writes(state()) :: state()
  def abort_open_writes(state), do: cleanup_open_handles(state)

  @spec handle_packet(binary(), state()) :: {SerializedPacket.t(), state()}
  def handle_packet(packet, %{initialized?: false} = state) do
    case Codec.decode(packet) do
      {:ok, %{type: :init} = request} -> handle_request(request, state)
      {:ok, %{id: id}} -> {Codec.status(id, :bad_message), state}
      {:error, reason} -> {Codec.status(0, reason), state}
    end
  end

  def handle_packet(packet, state) do
    case Codec.decode(packet) do
      {:ok, request} -> handle_request(request, state)
      {:error, reason} -> {Codec.status(0, reason), state}
    end
  end

  defp handle_request(%{type: :init}, state) do
    {Codec.version(3), %{state | initialized?: true}}
  end

  defp handle_request(%{type: :open, id: id, filename: path, pflags: pflags, attrs: attrs}, state) do
    cond do
      Paths.read_open?(pflags) and Paths.write_open?(pflags) ->
        with :ok <- Paths.validate_write_open(path, pflags, state),
             {:ok, write_handle} <-
               state.backend.open_write(path, attrs, state.session, state.backend_state) do
          read_handle =
            case state.backend.open_read(path, state.session, state.backend_state) do
              {:ok, read_handle} -> read_handle
              {:error, _reason} -> nil
            end

          case prepare_read_write_handle(path, pflags, read_handle, write_handle, state) do
            {:ok, write_handle, append_offset, size, overlay} ->
              dirty? = Paths.truncate_open?(pflags)

              Handles.put(
                id,
                {:file, :read_write, path, read_handle, write_handle, append_offset, dirty?,
                 overlay, size},
                state
              )

            {:error, reason} ->
              _ = state.backend.abort_write(write_handle, state.backend_state)
              {Codec.status(id, reason), state}
          end
        else
          {:error, reason} ->
            {Codec.status(id, reason), state}
        end

      Paths.write_open?(pflags) ->
        with :ok <- Paths.validate_write_open(path, pflags, state),
             {:ok, backend_handle} <-
               state.backend.open_write(path, attrs, state.session, state.backend_state) do
          case prepare_write_handle(path, pflags, backend_handle, state) do
            {:ok, backend_handle, append_offset, size} ->
              Handles.put(id, {:file, :write, path, backend_handle, append_offset, size}, state)

            {:error, reason} ->
              _ = state.backend.abort_write(backend_handle, state.backend_state)
              {Codec.status(id, reason), state}
          end
        else
          {:error, reason} ->
            {Codec.status(id, reason), state}
        end

      Paths.read_open?(pflags) ->
        case state.backend.open_read(path, state.session, state.backend_state) do
          {:ok, backend_handle} -> Handles.put(id, {:file, :read, path, backend_handle}, state)
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      true ->
        {Codec.status(id, :unsupported), state}
    end
  end

  defp handle_request(%{type: :close, id: id, handle: handle}, state) do
    case Map.pop(state.handles, handle) do
      {{:file, :write, _path, backend_handle, _append_offset, _size}, handles} ->
        response =
          case state.backend.finish_write(backend_handle, state.backend_state) do
            :ok ->
              Codec.status(id, :ok)

            {:error, reason} ->
              _ = state.backend.abort_write(backend_handle, state.backend_state)
              Codec.status(id, reason)
          end

        {response, %{state | handles: handles}}

      {{:file, :read_write, _path, _read_handle, write_handle, _append_offset, true, overlay,
        _size} = file_handle, handles} ->
        response =
          case finish_read_write_handle(file_handle, state) do
            :ok ->
              Codec.status(id, :ok)

            {:error, reason} ->
              _ = state.backend.abort_write(write_handle, state.backend_state)
              Codec.status(id, reason)
          end

        cleanup_overlay(overlay)
        {response, %{state | handles: handles}}

      {{:file, :read_write, _path, _read_handle, write_handle, _append_offset, false, overlay,
        _size}, handles} ->
        cleanup_overlay(overlay)
        _ = state.backend.abort_write(write_handle, state.backend_state)
        {Codec.status(id, :ok), %{state | handles: handles}}

      {{:file, :read, _path, _backend_handle}, handles} ->
        {Codec.status(id, :ok), %{state | handles: handles}}

      {{:dir, :closed}, handles} ->
        {Codec.status(id, :ok), %{state | handles: handles}}

      {{:dir, backend_handle}, handles} ->
        :ok = state.backend.close_dir(backend_handle, state.backend_state)
        {Codec.status(id, :ok), %{state | handles: handles}}

      {nil, _handles} ->
        {Codec.status(id, :failure), state}
    end
  end

  defp handle_request(%{type: :read, id: id, handle: handle, offset: offset, len: len}, state) do
    len = clamp_read_len(len)

    case Map.get(state.handles, handle) do
      {:file, :read, _path, backend_handle} ->
        case state.backend.read_at(backend_handle, offset, len, state.backend_state) do
          {:ok, data} -> data_response(id, data, state)
          :eof -> {Codec.status(id, :eof), state}
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      {:file, :read_write, _path, read_handle, _write_handle, _append_offset, _dirty?, overlay,
       size} ->
        case read_read_write_data(read_handle, overlay, offset, len, size, state) do
          {:ok, data} -> data_response(id, data, state)
          :eof -> {Codec.status(id, :eof), state}
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      _ ->
        {Codec.status(id, :failure), state}
    end
  end

  defp handle_request(%{type: :write, id: id, handle: handle, offset: offset, data: data}, state) do
    case Map.get(state.handles, handle) do
      {:file, :write, path, backend_handle, append_offset, size} ->
        write_offset = append_offset || offset
        data_size = IO.iodata_length(data)

        case state.backend.write_at(backend_handle, write_offset, data, state.backend_state) do
          {:ok, backend_handle} ->
            append_offset = if append_offset, do: append_offset + data_size
            size = max(size, write_offset + data_size)

            handles =
              Map.put(
                state.handles,
                handle,
                {:file, :write, path, backend_handle, append_offset, size}
              )

            {Codec.status(id, :ok), %{state | handles: handles}}

          {:error, reason} ->
            _ = state.backend.abort_write(backend_handle, state.backend_state)
            handles = Map.delete(state.handles, handle)

            {Codec.status(id, reason), %{state | handles: handles}}
        end

      {:file, :read_write, path, read_handle, write_handle, append_offset, _dirty?, overlay, size} ->
        write_offset = append_offset || offset
        data_size = IO.iodata_length(data)

        case write_overlay(overlay, write_offset, data, data_size) do
          :ok ->
            append_offset = if append_offset, do: append_offset + data_size
            size = max(size, write_offset + data_size)
            overlay = put_overlay_range(overlay, write_offset, data_size)

            handles =
              Map.put(
                state.handles,
                handle,
                {:file, :read_write, path, read_handle, write_handle, append_offset, true,
                 overlay, size}
              )

            {Codec.status(id, :ok), %{state | handles: handles}}

          {:error, reason} ->
            _ = state.backend.abort_write(write_handle, state.backend_state)
            cleanup_overlay(overlay)
            handles = Map.delete(state.handles, handle)

            {Codec.status(id, reason), %{state | handles: handles}}
        end

      _ ->
        {Codec.status(id, :failure), state}
    end
  end

  defp handle_request(%{type: type, id: id, path: path}, state) when type in [:stat, :lstat] do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, attrs} -> {Codec.attrs(id, attrs), state}
      {:error, reason} -> {Codec.status(id, reason), state}
    end
  end

  defp handle_request(%{type: :fstat, id: id, handle: handle}, state) do
    case Map.get(state.handles, handle) do
      file_handle when elem(file_handle, 0) == :file ->
        case Handles.file_attrs(file_handle, state) do
          {:ok, attrs} -> {Codec.attrs(id, attrs), state}
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      _ ->
        {Codec.status(id, :failure), state}
    end
  end

  defp handle_request(%{type: :opendir, id: id, path: path}, state) do
    with :ok <- Paths.require_directory(path, state),
         {:ok, backend_handle} <- state.backend.open_dir(path, state.session, state.backend_state) do
      Handles.put(id, {:dir, backend_handle}, state)
    else
      {:error, reason} -> {Codec.status(id, reason), state}
    end
  end

  defp handle_request(%{type: :readdir, id: id, handle: handle}, state) do
    case Map.get(state.handles, handle) do
      {:dir, :closed} ->
        {Codec.status(id, :eof), state}

      {:dir, backend_handle} ->
        case state.backend.read_dir(backend_handle, state.backend_state) do
          {:ok, entries, backend_handle} ->
            handles = Map.put(state.handles, handle, {:dir, backend_handle})
            {Codec.name(id, entries), %{state | handles: handles}}

          :eof ->
            :ok = state.backend.close_dir(backend_handle, state.backend_state)
            handles = Map.put(state.handles, handle, {:dir, :closed})
            {Codec.status(id, :eof), %{state | handles: handles}}

          {:error, reason} ->
            :ok = state.backend.close_dir(backend_handle, state.backend_state)
            handles = Map.delete(state.handles, handle)
            {Codec.status(id, reason), %{state | handles: handles}}
        end

      _ ->
        {Codec.status(id, :failure), state}
    end
  end

  defp handle_request(%{type: :realpath, id: id, path: path}, state) do
    path = Paths.normalize_realpath(path)

    {Codec.name(id, [%{name: path, attrs: %{type: :directory, size: 0, permissions: 0o040755}}]),
     state}
  end

  defp handle_request(%{type: :mkdir, id: id, path: path, attrs: attrs}, state) do
    case Paths.path_exists?(path, state) do
      false ->
        case state.backend.make_dir(path, attrs, state.session, state.backend_state) do
          :ok -> {Codec.status(id, :ok), state}
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      true ->
        {Codec.status(id, :eexist), state}

      {:error, reason} ->
        {Codec.status(id, reason), state}
    end
  end

  defp handle_request(%{type: :rmdir, id: id, path: path}, state) do
    case Paths.require_directory(path, state) do
      :ok ->
        case state.backend.del_dir(path, state.session, state.backend_state) do
          :ok -> {Codec.status(id, :ok), state}
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      {:error, reason} ->
        {Codec.status(id, reason), state}
    end
  end

  defp handle_request(%{type: :remove, id: id, path: path}, state) do
    case Paths.require_regular(path, state) do
      :ok ->
        case state.backend.delete(path, state.session, state.backend_state) do
          :ok -> {Codec.status(id, :ok), state}
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      {:error, reason} ->
        {Codec.status(id, reason), state}
    end
  end

  defp handle_request(%{type: :rename, id: id, oldpath: oldpath, newpath: newpath}, state) do
    case state.backend.rename(oldpath, newpath, state.session, state.backend_state) do
      :ok -> {Codec.status(id, :ok), state}
      {:error, reason} -> {Codec.status(id, reason), state}
    end
  end

  defp handle_request(%{type: type, id: id}, state)
       when type in [:setstat, :fsetstat, :readlink, :symlink] do
    {Codec.status(id, :unsupported), state}
  end

  defp handle_request(%{id: id}, state), do: {Codec.status(id, :unsupported), state}

  defp prepare_write_handle(path, pflags, backend_handle, state) do
    cond do
      Paths.truncate_open?(pflags) ->
        append_offset = if Paths.append_open?(pflags), do: 0
        {:ok, backend_handle, append_offset, 0}

      Paths.append_open?(pflags) ->
        with {:ok, backend_handle, append_offset} <-
               seed_append_handle(path, backend_handle, state) do
          {:ok, backend_handle, append_offset, append_offset}
        end

      true ->
        seed_write_update_handle(path, backend_handle, state)
    end
  end

  defp clamp_read_len(len), do: min(len, @max_read_len)

  defp append_offset(path, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, attrs} -> Map.get(attrs, :size, 0)
      {:error, _reason} -> 0
    end
  end

  defp prepare_read_write_handle(path, pflags, read_handle, write_handle, state) do
    cond do
      Paths.truncate_open?(pflags) ->
        append_offset = if Paths.append_open?(pflags), do: 0
        with {:ok, overlay} <- new_overlay(), do: {:ok, write_handle, append_offset, 0, overlay}

      Paths.append_open?(pflags) ->
        append_offset = append_offset(path, state)

        with {:ok, overlay} <- new_overlay() do
          {:ok, write_handle, append_offset, append_offset, overlay}
        end

      true ->
        seed_update_handle(path, read_handle, write_handle, state)
    end
  end

  defp seed_append_handle(path, backend_handle, state) do
    size = append_offset(path, state)

    with true <- size > 0,
         {:ok, read_handle} <- state.backend.open_read(path, state.session, state.backend_state),
         {:ok, backend_handle} <- seed_handle_chunks(read_handle, backend_handle, state, size, 0) do
      {:ok, backend_handle, size}
    else
      false -> {:ok, backend_handle, size}
      {:error, reason} -> {:error, reason}
      :eof -> {:error, :eof}
    end
  end

  defp seed_write_update_handle(path, backend_handle, state) do
    size = append_offset(path, state)

    with true <- size > 0,
         {:ok, read_handle} <- state.backend.open_read(path, state.session, state.backend_state),
         {:ok, backend_handle} <- seed_handle_chunks(read_handle, backend_handle, state, size, 0) do
      {:ok, backend_handle, nil, size}
    else
      false -> {:ok, backend_handle, nil, size}
      {:error, reason} -> {:error, reason}
      :eof -> {:error, :eof}
    end
  end

  defp seed_update_handle(path, nil, backend_handle, state) do
    case append_offset(path, state) do
      0 ->
        with {:ok, overlay} <- new_overlay(), do: {:ok, backend_handle, nil, 0, overlay}

      _size ->
        {:error, :eio}
    end
  end

  defp seed_update_handle(path, _read_handle, backend_handle, state) do
    size = append_offset(path, state)

    with {:ok, overlay} <- new_overlay() do
      {:ok, backend_handle, nil, size, overlay}
    end
  end

  defp seed_handle_chunks(_read_handle, backend_handle, _state, size, offset)
       when offset >= size do
    {:ok, backend_handle}
  end

  defp seed_handle_chunks(read_handle, backend_handle, state, size, offset) do
    len = min(@seed_chunk_size, size - offset)

    with {:ok, data} <- state.backend.read_at(read_handle, offset, len, state.backend_state),
         data_size <- IO.iodata_length(data),
         true <- data_size > 0,
         {:ok, backend_handle} <-
           state.backend.write_at(backend_handle, offset, data, state.backend_state) do
      seed_handle_chunks(
        read_handle,
        backend_handle,
        state,
        size,
        offset + data_size
      )
    else
      false -> {:error, :eof}
      :eof -> {:error, :eof}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_read_write_handle(
         {:file, :read_write, _path, read_handle, write_handle, _append_offset, _dirty?, overlay,
          size},
         state
       ) do
    with {:ok, write_handle} <-
           replay_read_write_data(read_handle, write_handle, overlay, size, state, 0) do
      state.backend.finish_write(write_handle, state.backend_state)
    end
  end

  defp replay_read_write_data(_read_handle, write_handle, _overlay, size, _state, offset)
       when offset >= size,
       do: {:ok, write_handle}

  defp replay_read_write_data(read_handle, write_handle, overlay, size, state, offset) do
    len = min(@replay_chunk_size, size - offset)

    with {:ok, data} <- read_read_write_data(read_handle, overlay, offset, len, size, state),
         data_size <- IO.iodata_length(data),
         true <- data_size > 0,
         {:ok, write_handle} <-
           state.backend.write_at(write_handle, offset, data, state.backend_state) do
      replay_read_write_data(read_handle, write_handle, overlay, size, state, offset + data_size)
    else
      false -> {:error, :eof}
      :eof -> {:error, :eof}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_read_write_data(_read_handle, _overlay, offset, _len, size, _state)
       when offset >= size,
       do: :eof

  defp read_read_write_data(read_handle, overlay, offset, len, size, state) do
    len = min(len, size - offset)

    with {:ok, base} <- read_base_data(read_handle, offset, len, state) do
      overlay_ranges(base, offset, len, overlay)
    end
  end

  defp read_base_data(nil, _offset, len, _state), do: {:ok, zeroes(len)}

  defp read_base_data(read_handle, offset, len, state) do
    case state.backend.read_at(read_handle, offset, len, state.backend_state) do
      {:ok, data} -> {:ok, pad_binary(data, len)}
      :eof -> {:ok, zeroes(len)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp overlay_ranges(base, offset, len, overlay) do
    Enum.reduce_while(overlay.ranges, {:ok, base}, fn {chunk_offset, chunk_size}, {:ok, acc} ->
      read_end = offset + len
      chunk_end = chunk_offset + chunk_size
      overlap_start = max(offset, chunk_offset)
      overlap_end = min(read_end, chunk_end)

      if overlap_start < overlap_end do
        overlap_len = overlap_end - overlap_start

        case read_overlay(overlay, overlap_start, overlap_len) do
          {:ok, chunk} ->
            {:cont, {:ok, overlay_chunk(acc, offset, len, overlap_start, chunk)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp overlay_chunk(base, read_offset, read_len, overlap_start, chunk) do
    chunk_size = byte_size(chunk)
    prefix_len = overlap_start - read_offset
    suffix_offset = prefix_len + chunk_size
    suffix_len = read_len - suffix_offset

    prefix = binary_part(base, 0, prefix_len)
    suffix = binary_part(base, suffix_offset, suffix_len)

    IO.iodata_to_binary([prefix, chunk, suffix])
  end

  defp pad_binary(data, len) do
    data = IO.iodata_to_binary(data)
    data_size = byte_size(data)

    if data_size < len do
      IO.iodata_to_binary([data, zeroes(len - data_size)])
    else
      binary_part(data, 0, len)
    end
  end

  defp zeroes(0), do: ""
  defp zeroes(len), do: :binary.copy(<<0>>, len)

  defp new_overlay do
    path =
      Path.join(System.tmp_dir!(), "sftpd-sftp-overlay-#{random_temp_suffix()}.tmp")

    case :file.open(String.to_charlist(path), [:read, :write, :binary, :raw, :exclusive]) do
      {:ok, fd} ->
        case :file.change_mode(String.to_charlist(path), 0o600) do
          :ok ->
            {:ok, %{path: path, fd: fd, ranges: []}}

          {:error, reason} ->
            _ = :file.close(fd)
            _ = File.rm(path)
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

  defp write_overlay(_overlay, _offset, _data, 0), do: :ok

  defp write_overlay(%{fd: fd}, offset, data, _data_size) do
    case :file.pwrite(fd, offset, data) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_overlay(%{fd: fd}, offset, len) do
    case :file.pread(fd, offset, len) do
      {:ok, data} -> {:ok, data}
      :eof -> {:error, :eof}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_overlay_range(%{ranges: ranges} = overlay, offset, size) do
    %{overlay | ranges: merge_ranges([{offset, size} | ranges])}
  end

  defp merge_ranges(ranges) do
    ranges
    |> Enum.sort_by(fn {offset, _size} -> offset end)
    |> Enum.reduce([], fn
      {offset, size}, [] ->
        [{offset, size}]

      {offset, size}, [{prev_offset, prev_size} | rest] ->
        prev_end = prev_offset + prev_size
        current_end = offset + size

        if offset <= prev_end do
          [{prev_offset, max(prev_end, current_end) - prev_offset} | rest]
        else
          [{offset, size}, {prev_offset, prev_size} | rest]
        end
    end)
    |> Enum.reverse()
  end

  defp cleanup_overlay(%{fd: fd, path: path}) do
    _ = :file.close(fd)
    _ = File.rm(path)
    :ok
  end

  defp cleanup_overlay(_overlay), do: :ok

  defp data_response(id, data, state) do
    if IO.iodata_length(data) == 0 do
      {Codec.status(id, :eof), state}
    else
      {Codec.data(id, data), state}
    end
  end
end
