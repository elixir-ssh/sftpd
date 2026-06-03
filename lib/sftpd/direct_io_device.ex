defmodule Sftpd.DirectIODevice do
  @moduledoc false

  alias Sftpd.Backend

  @type handle :: {:sftpd_direct_io, reference()}

  @spec start(map()) :: {:ok, handle()} | {:error, atom()}
  def start(%{path: path, mode: :read, backend: backend, backend_state: backend_state} = opts) do
    session = Map.get(opts, :session, %{})

    with {:ok, info} <- Backend.call(backend, :file_info, [path, backend_state], session) do
      handle = new_handle()

      put_state(handle, %{
        mode: :read,
        path: path,
        backend: backend,
        backend_state: backend_state,
        session: session,
        position: 0,
        size: extract_file_size(info)
      })

      {:ok, handle}
    end
  end

  def start(%{path: path, mode: :write, backend: backend, backend_state: backend_state} = opts) do
    session = Map.get(opts, :session, %{})

    with {:ok, writer_handle} <-
           Backend.call(backend, :begin_write, [path, backend_state], session) do
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
      %{mode: :read, position: position, size: size} = state when position >= size ->
        {:eof, state}

      %{mode: :read} = state ->
        result =
          Backend.call(
            state.backend,
            :read_file_range,
            [state.path, state.position, len, state.backend_state],
            state.session
          )

        case result do
          {:ok, data} when byte_size(data) > 0 ->
            {{:ok, data}, %{state | position: state.position + byte_size(data)}}

          {:ok, <<>>} ->
            {:eof, state}

          :eof ->
            {:eof, state}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      state ->
        {{:error, :einval}, state}
    end)
  end

  @spec write(handle(), iodata(), non_neg_integer()) :: :ok | {:error, atom()}
  def write(handle, data, bytes) do
    update_state(handle, fn
      %{mode: :write} = state ->
        result =
          Backend.call(
            state.backend,
            :write_chunk,
            [state.writer_handle, state.position, data, state.backend_state],
            state.session
          )

        case result do
          {:ok, writer_handle} ->
            position = state.position + bytes

            {:ok,
             %{
               state
               | writer_handle: writer_handle,
                 position: position,
                 size: max(state.size, position)
             }}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      state ->
        {{:error, :einval}, state}
    end)
  end

  @spec close(handle()) :: :ok | {:error, atom()}
  def close(handle) do
    case pop_state(handle) do
      nil ->
        :ok

      %{mode: :write} = state ->
        Backend.call(
          state.backend,
          :finish_write,
          [state.writer_handle, state.backend_state],
          state.session
        )

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

  defp extract_file_size(
         {:file_info, size, _type, _access, _atime, _mtime, _ctime, _mode, _links, _major, _minor,
          _inode, _uid, _gid}
       ),
       do: size
end
