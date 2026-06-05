defmodule Sftpd.SFTP.Paths do
  @moduledoc false

  import Bitwise

  @open_read 0x0000_0001
  @open_write 0x0000_0002
  @open_append 0x0000_0004
  @open_create 0x0000_0008
  @open_truncate 0x0000_0010
  @open_exclusive 0x0000_0020

  def read_open?(pflags), do: (pflags &&& @open_read) != 0
  def write_open?(pflags), do: (pflags &&& @open_write) != 0
  def append_open?(pflags), do: (pflags &&& @open_append) != 0
  def create_open?(pflags), do: (pflags &&& @open_create) != 0
  def truncate_open?(pflags), do: (pflags &&& @open_truncate) != 0
  def exclusive_open?(pflags), do: (pflags &&& @open_exclusive) != 0

  def normalize_realpath(path) do
    path =
      path
      |> to_string()
      |> String.trim_leading("/")

    if path == "", do: "/", else: "/" <> path
  end

  def validate_write_open(path, pflags, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, %{type: :directory}} ->
        {:error, :eisdir}

      {:ok, _attrs} ->
        if create_open?(pflags) and exclusive_open?(pflags) do
          {:error, :eexist}
        else
          :ok
        end

      {:error, reason} ->
        if create_open?(pflags) do
          :ok
        else
          {:error, reason}
        end
    end
  end

  def path_exists?(path, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, _attrs} -> true
      {:error, :enoent} -> false
      {:error, :no_such_file} -> false
      {:error, reason} -> {:error, reason}
    end
  end

  def require_directory(path, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _attrs} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  def require_regular(path, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, %{type: :directory}} -> {:error, :eisdir}
      {:ok, _attrs} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
