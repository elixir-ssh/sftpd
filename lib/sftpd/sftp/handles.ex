defmodule Sftpd.SFTP.Handles do
  @moduledoc false

  alias Sftpd.SFTP.Codec

  def cleanup_open_handles(state, cleanup_overlay_fun) do
    Enum.each(state.handles, fn
      {_handle, {:file, :write, _path, backend_handle, _append_offset, _size}} ->
        _ = state.backend.abort_write(backend_handle, state.backend_state)

      {_handle,
       {:file, :read_write, _path, _read_handle, write_handle, _append_offset, _dirty?, overlay,
        _size}} ->
        _ = state.backend.abort_write(write_handle, state.backend_state)
        cleanup_overlay_fun.(overlay)

      {_handle, {:dir, :closed}} ->
        :ok

      {_handle, {:dir, backend_handle}} ->
        _ = state.backend.close_dir(backend_handle, state.backend_state)

      _entry ->
        :ok
    end)

    %{state | handles: %{}}
  end

  def put(id, value, state) do
    handle = new(value)
    {Codec.handle(id, handle), %{state | handles: Map.put(state.handles, handle, value)}}
  end

  def file_attrs({:file, :write, path, _backend_handle, _append_offset, size}, state) do
    pending_file_attrs(path, size, state)
  end

  def file_attrs(
        {:file, :read_write, path, _read_handle, _write_handle, _append_offset, _dirty?, _overlay,
         size},
        state
      ) do
    pending_file_attrs(path, size, state)
  end

  def file_attrs(file_handle, state) do
    path = path(file_handle)
    state.backend.file_attrs(path, state.session, state.backend_state)
  end

  defp new({:file, :read, _path, _backend_handle}),
    do: <<"F", :crypto.strong_rand_bytes(16)::binary>>

  defp new({:file, :write, _path, _backend_handle, _append_offset, _size}),
    do: <<"W", :crypto.strong_rand_bytes(16)::binary>>

  defp new(
         {:file, :read_write, _path, _read_handle, _write_handle, _append_offset, _dirty?,
          _overlay, _size}
       ),
       do: <<"B", :crypto.strong_rand_bytes(16)::binary>>

  defp new({:dir, _}), do: <<"D", :crypto.strong_rand_bytes(16)::binary>>

  defp path({:file, :read, path, _backend_handle}), do: path

  defp pending_file_attrs(path, size, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, attrs} -> {:ok, Map.put(attrs, :size, size)}
      {:error, _reason} -> {:ok, %{type: :regular, size: size, permissions: 0o100644}}
    end
  end
end
