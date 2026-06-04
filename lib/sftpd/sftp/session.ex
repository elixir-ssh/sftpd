defmodule Sftpd.SFTP.Session do
  @moduledoc false

  import Bitwise

  alias Sftpd.SFTP.{Codec, SerializedPacket}

  @open_read 0x0000_0001
  @open_write 0x0000_0002
  @open_append 0x0000_0004
  @open_create 0x0000_0008
  @open_truncate 0x0000_0010
  @open_exclusive 0x0000_0020
  @max_read_len 1_048_576
  @seed_chunk_size 1_048_576

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

  @spec abort_open_writes(state()) :: state()
  def abort_open_writes(state) do
    Enum.each(state.handles, fn
      {_handle, {:file, :write, _path, backend_handle, _append_offset}} ->
        _ = state.backend.abort_write(backend_handle, state.backend_state)

      {_handle,
       {:file, :read_write, _path, _read_handle, write_handle, _append_offset, _dirty?,
        _pending_chunks, _size}} ->
        _ = state.backend.abort_write(write_handle, state.backend_state)

      _entry ->
        :ok
    end)

    %{state | handles: %{}}
  end

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
      read_open?(pflags) and write_open?(pflags) ->
        with :ok <- validate_write_open(path, pflags, state),
             {:ok, write_handle} <-
               state.backend.open_write(path, attrs, state.session, state.backend_state) do
          read_handle =
            case state.backend.open_read(path, state.session, state.backend_state) do
              {:ok, read_handle} -> read_handle
              {:error, _reason} -> nil
            end

          case prepare_read_write_handle(path, pflags, read_handle, write_handle, state) do
            {:ok, write_handle, append_offset, size} ->
              dirty? = truncate_open?(pflags)

              put_handle(
                id,
                {:file, :read_write, path, read_handle, write_handle, append_offset, dirty?, [],
                 size},
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

      write_open?(pflags) ->
        with :ok <- validate_write_open(path, pflags, state),
             {:ok, backend_handle} <-
               state.backend.open_write(path, attrs, state.session, state.backend_state) do
          case prepare_write_handle(path, pflags, backend_handle, state) do
            {:ok, backend_handle, append_offset} ->
              put_handle(id, {:file, :write, path, backend_handle, append_offset}, state)

            {:error, reason} ->
              _ = state.backend.abort_write(backend_handle, state.backend_state)
              {Codec.status(id, reason), state}
          end
        else
          {:error, reason} ->
            {Codec.status(id, reason), state}
        end

      read_open?(pflags) ->
        case state.backend.open_read(path, state.session, state.backend_state) do
          {:ok, backend_handle} -> put_handle(id, {:file, :read, path, backend_handle}, state)
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      true ->
        {Codec.status(id, :unsupported), state}
    end
  end

  defp handle_request(%{type: :close, id: id, handle: handle}, state) do
    case Map.pop(state.handles, handle) do
      {{:file, :write, _path, backend_handle, _append_offset}, handles} ->
        response =
          case state.backend.finish_write(backend_handle, state.backend_state) do
            :ok -> Codec.status(id, :ok)
            {:error, reason} -> Codec.status(id, reason)
          end

        {response, %{state | handles: handles}}

      {{:file, :read_write, _path, _read_handle, write_handle, _append_offset, true,
        _pending_chunks, _size}, handles} ->
        response =
          case state.backend.finish_write(write_handle, state.backend_state) do
            :ok -> Codec.status(id, :ok)
            {:error, reason} -> Codec.status(id, reason)
          end

        {response, %{state | handles: handles}}

      {{:file, :read_write, _path, _read_handle, write_handle, _append_offset, false,
        _pending_chunks, _size}, handles} ->
        _ = state.backend.abort_write(write_handle, state.backend_state)
        {Codec.status(id, :ok), %{state | handles: handles}}

      {{:file, :read, _path, _backend_handle}, handles} ->
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
          {:ok, ""} -> {Codec.status(id, :eof), state}
          {:ok, data} -> {Codec.data(id, data), state}
          :eof -> {Codec.status(id, :eof), state}
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      {:file, :read_write, _path, read_handle, _write_handle, _append_offset, _dirty?,
       pending_chunks, size} ->
        case read_read_write_data(read_handle, pending_chunks, offset, len, size, state) do
          {:ok, ""} -> {Codec.status(id, :eof), state}
          {:ok, data} -> {Codec.data(id, data), state}
          :eof -> {Codec.status(id, :eof), state}
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      _ ->
        {Codec.status(id, :failure), state}
    end
  end

  defp handle_request(%{type: :write, id: id, handle: handle, offset: offset, data: data}, state) do
    case Map.get(state.handles, handle) do
      {:file, :write, path, backend_handle, append_offset} ->
        write_offset = append_offset || offset

        case state.backend.write_at(backend_handle, write_offset, data, state.backend_state) do
          {:ok, backend_handle} ->
            append_offset = if append_offset, do: append_offset + IO.iodata_length(data)

            handles =
              Map.put(state.handles, handle, {:file, :write, path, backend_handle, append_offset})

            {Codec.status(id, :ok), %{state | handles: handles}}

          {:error, reason} ->
            _ = state.backend.abort_write(backend_handle, state.backend_state)
            handles = Map.delete(state.handles, handle)

            {Codec.status(id, reason), %{state | handles: handles}}
        end

      {:file, :read_write, path, read_handle, write_handle, append_offset, _dirty?,
       pending_chunks, size} ->
        write_offset = append_offset || offset
        data = IO.iodata_to_binary(data)
        data_size = byte_size(data)

        case state.backend.write_at(write_handle, write_offset, data, state.backend_state) do
          {:ok, write_handle} ->
            append_offset = if append_offset, do: append_offset + data_size
            size = max(size, write_offset + data_size)

            handles =
              Map.put(
                state.handles,
                handle,
                {:file, :read_write, path, read_handle, write_handle, append_offset, true,
                 [{write_offset, data} | pending_chunks], size}
              )

            {Codec.status(id, :ok), %{state | handles: handles}}

          {:error, reason} ->
            _ = state.backend.abort_write(write_handle, state.backend_state)
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
        path = file_handle_path(file_handle)

        case state.backend.file_attrs(path, state.session, state.backend_state) do
          {:ok, attrs} -> {Codec.attrs(id, attrs), state}
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      _ ->
        {Codec.status(id, :failure), state}
    end
  end

  defp handle_request(%{type: :opendir, id: id, path: path}, state) do
    case state.backend.open_dir(path, state.session, state.backend_state) do
      {:ok, backend_handle} -> put_handle(id, {:dir, backend_handle}, state)
      {:error, reason} -> {Codec.status(id, reason), state}
    end
  end

  defp handle_request(%{type: :readdir, id: id, handle: handle}, state) do
    case Map.get(state.handles, handle) do
      {:dir, backend_handle} ->
        case state.backend.read_dir(backend_handle, state.backend_state) do
          {:ok, entries, backend_handle} ->
            handles = Map.put(state.handles, handle, {:dir, backend_handle})
            {Codec.name(id, entries), %{state | handles: handles}}

          :eof ->
            {Codec.status(id, :eof), state}

          {:error, reason} ->
            {Codec.status(id, reason), state}
        end

      _ ->
        {Codec.status(id, :failure), state}
    end
  end

  defp handle_request(%{type: :realpath, id: id, path: path}, state) do
    path = normalize_realpath(path)

    {Codec.name(id, [%{name: path, attrs: %{type: :directory, size: 0, permissions: 0o040755}}]),
     state}
  end

  defp handle_request(%{type: :mkdir, id: id, path: path, attrs: attrs}, state) do
    case state.backend.make_dir(path, attrs, state.session, state.backend_state) do
      :ok -> {Codec.status(id, :ok), state}
      {:error, reason} -> {Codec.status(id, reason), state}
    end
  end

  defp handle_request(%{type: :rmdir, id: id, path: path}, state) do
    case state.backend.del_dir(path, state.session, state.backend_state) do
      :ok -> {Codec.status(id, :ok), state}
      {:error, reason} -> {Codec.status(id, reason), state}
    end
  end

  defp handle_request(%{type: :remove, id: id, path: path}, state) do
    case state.backend.delete(path, state.session, state.backend_state) do
      :ok -> {Codec.status(id, :ok), state}
      {:error, reason} -> {Codec.status(id, reason), state}
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
      append_open?(pflags) ->
        seed_append_handle(path, backend_handle, state)

      truncate_open?(pflags) ->
        {:ok, backend_handle, nil}

      true ->
        seed_write_update_handle(path, backend_handle, state)
    end
  end

  defp validate_write_open(path, pflags, state) do
    if create_open?(pflags) and exclusive_open?(pflags) do
      case state.backend.file_attrs(path, state.session, state.backend_state) do
        {:ok, _attrs} -> {:error, :eexist}
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  defp put_handle(id, value, state) do
    handle = new_handle(value)
    {Codec.handle(id, handle), %{state | handles: Map.put(state.handles, handle, value)}}
  end

  defp new_handle({:file, :read, _path, _backend_handle}),
    do: <<"F", :crypto.strong_rand_bytes(16)::binary>>

  defp new_handle({:file, :write, _path, _backend_handle, _append_offset}),
    do: <<"W", :crypto.strong_rand_bytes(16)::binary>>

  defp new_handle(
         {:file, :read_write, _path, _read_handle, _write_handle, _append_offset, _dirty?,
          _pending_chunks, _size}
       ),
       do: <<"B", :crypto.strong_rand_bytes(16)::binary>>

  defp new_handle({:dir, _}), do: <<"D", :crypto.strong_rand_bytes(16)::binary>>

  defp file_handle_path({:file, :read, path, _backend_handle}), do: path
  defp file_handle_path({:file, :write, path, _backend_handle, _append_offset}), do: path

  defp file_handle_path(
         {:file, :read_write, path, _read_handle, _write_handle, _append_offset, _dirty?,
          _pending_chunks, _size}
       ),
       do: path

  defp write_open?(pflags),
    do: (pflags &&& (@open_write ||| @open_create ||| @open_truncate)) != 0

  defp read_open?(pflags), do: (pflags &&& @open_read) != 0
  defp append_open?(pflags), do: (pflags &&& @open_append) != 0
  defp create_open?(pflags), do: (pflags &&& @open_create) != 0
  defp truncate_open?(pflags), do: (pflags &&& @open_truncate) != 0
  defp exclusive_open?(pflags), do: (pflags &&& @open_exclusive) != 0

  defp clamp_read_len(len), do: min(len, @max_read_len)

  defp append_offset(path, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, attrs} -> Map.get(attrs, :size, 0)
      {:error, _reason} -> 0
    end
  end

  defp prepare_read_write_handle(path, pflags, read_handle, write_handle, state) do
    cond do
      append_open?(pflags) ->
        with {:ok, write_handle, append_offset} <- seed_append_handle(path, write_handle, state) do
          {:ok, write_handle, append_offset, append_offset}
        end

      truncate_open?(pflags) ->
        {:ok, write_handle, nil, 0}

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
      {:ok, backend_handle, nil}
    else
      false -> {:ok, backend_handle, nil}
      {:error, reason} -> {:error, reason}
      :eof -> {:error, :eof}
    end
  end

  defp seed_update_handle(path, nil, backend_handle, state) do
    case append_offset(path, state) do
      0 -> {:ok, backend_handle, nil, 0}
      _size -> {:error, :eio}
    end
  end

  defp seed_update_handle(path, read_handle, backend_handle, state) do
    size = append_offset(path, state)

    with true <- size > 0 do
      case seed_handle_chunks(read_handle, backend_handle, state, size, 0) do
        {:ok, backend_handle} -> {:ok, backend_handle, nil, size}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:ok, backend_handle, nil, 0}
    end
  end

  defp seed_handle_chunks(_read_handle, backend_handle, _state, size, offset)
       when offset >= size do
    {:ok, backend_handle}
  end

  defp seed_handle_chunks(read_handle, backend_handle, state, size, offset) do
    len = min(@seed_chunk_size, size - offset)

    with {:ok, data} <- state.backend.read_at(read_handle, offset, len, state.backend_state),
         data <- IO.iodata_to_binary(data),
         true <- byte_size(data) > 0,
         {:ok, backend_handle} <-
           state.backend.write_at(backend_handle, offset, data, state.backend_state) do
      seed_handle_chunks(
        read_handle,
        backend_handle,
        state,
        size,
        offset + byte_size(data)
      )
    else
      false -> {:error, :eof}
      :eof -> {:error, :eof}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_read_write_data(_read_handle, _pending_chunks, offset, _len, size, _state)
       when offset >= size,
       do: :eof

  defp read_read_write_data(read_handle, pending_chunks, offset, len, size, state) do
    len = min(len, size - offset)

    with {:ok, base} <- read_base_data(read_handle, offset, len, state) do
      {:ok, overlay_pending_chunks(base, offset, len, pending_chunks)}
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

  defp overlay_pending_chunks(base, offset, len, pending_chunks) do
    Enum.reduce(Enum.reverse(pending_chunks), base, fn {chunk_offset, chunk}, acc ->
      overlay_chunk(acc, offset, len, chunk_offset, chunk)
    end)
  end

  defp overlay_chunk(base, read_offset, read_len, chunk_offset, chunk) do
    chunk_size = byte_size(chunk)
    read_end = read_offset + read_len
    chunk_end = chunk_offset + chunk_size
    overlap_start = max(read_offset, chunk_offset)
    overlap_end = min(read_end, chunk_end)

    if overlap_start < overlap_end do
      prefix_len = overlap_start - read_offset
      overlap_len = overlap_end - overlap_start
      suffix_offset = prefix_len + overlap_len
      suffix_len = read_len - suffix_offset
      chunk_part_offset = overlap_start - chunk_offset

      prefix = binary_part(base, 0, prefix_len)
      replacement = binary_part(chunk, chunk_part_offset, overlap_len)
      suffix = binary_part(base, suffix_offset, suffix_len)

      IO.iodata_to_binary([prefix, replacement, suffix])
    else
      base
    end
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

  defp normalize_realpath(path) do
    path =
      path
      |> to_string()
      |> String.trim_leading("/")

    if path == "", do: "/", else: "/" <> path
  end
end
