defmodule Sftpd.SFTP.Session do
  @moduledoc false

  import Bitwise

  alias Sftpd.SFTP.Codec

  @open_read 0x0000_0001
  @open_write 0x0000_0002
  @open_create 0x0000_0008
  @open_truncate 0x0000_0010

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

  @spec handle_packet(binary(), state()) :: {iodata(), state()}
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
      write_open?(pflags) ->
        case state.backend.open_write(path, attrs, state.session, state.backend_state) do
          {:ok, backend_handle} -> put_handle(id, {:file, :write, backend_handle}, state)
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      read_open?(pflags) ->
        case state.backend.open_read(path, state.session, state.backend_state) do
          {:ok, backend_handle} -> put_handle(id, {:file, :read, backend_handle}, state)
          {:error, reason} -> {Codec.status(id, reason), state}
        end

      true ->
        {Codec.status(id, :unsupported), state}
    end
  end

  defp handle_request(%{type: :close, id: id, handle: handle}, state) do
    case Map.pop(state.handles, handle) do
      {{:file, :write, backend_handle}, handles} ->
        response =
          case state.backend.finish_write(backend_handle, state.backend_state) do
            :ok -> Codec.status(id, :ok)
            {:error, reason} -> Codec.status(id, reason)
          end

        {response, %{state | handles: handles}}

      {{:file, :read, _backend_handle}, handles} ->
        {Codec.status(id, :ok), %{state | handles: handles}}

      {{:dir, backend_handle}, handles} ->
        :ok = state.backend.close_dir(backend_handle, state.backend_state)
        {Codec.status(id, :ok), %{state | handles: handles}}

      {nil, _handles} ->
        {Codec.status(id, :failure), state}
    end
  end

  defp handle_request(%{type: :read, id: id, handle: handle, offset: offset, len: len}, state) do
    case Map.get(state.handles, handle) do
      {:file, :read, backend_handle} ->
        case state.backend.read_at(backend_handle, offset, len, state.backend_state) do
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
      {:file, :write, backend_handle} ->
        case state.backend.write_at(backend_handle, offset, data, state.backend_state) do
          {:ok, backend_handle} ->
            handles = Map.put(state.handles, handle, {:file, :write, backend_handle})
            {Codec.status(id, :ok), %{state | handles: handles}}

          {:error, reason} ->
            {Codec.status(id, reason), state}
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
      {:file, _mode, %{path: path}} ->
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

  defp put_handle(id, value, state) do
    handle = new_handle(value)
    {Codec.handle(id, handle), %{state | handles: Map.put(state.handles, handle, value)}}
  end

  defp new_handle({:file, :read, _}), do: <<"F", :crypto.strong_rand_bytes(16)::binary>>
  defp new_handle({:file, :write, _}), do: <<"W", :crypto.strong_rand_bytes(16)::binary>>
  defp new_handle({:dir, _}), do: <<"D", :crypto.strong_rand_bytes(16)::binary>>

  defp write_open?(pflags),
    do: (pflags &&& (@open_write ||| @open_create ||| @open_truncate)) != 0

  defp read_open?(pflags), do: (pflags &&& @open_read) != 0

  defp normalize_realpath(path) do
    path =
      path
      |> to_string()
      |> String.trim_leading("/")

    if path == "", do: "/", else: "/" <> path
  end
end
