defmodule Sftpd.SFTP.Paths do
  @moduledoc false

  import Bitwise

  alias Sftpd.Backend

  @open_read 0x0000_0001
  @open_write 0x0000_0002
  @open_append 0x0000_0004
  @open_create 0x0000_0008
  @open_truncate 0x0000_0010
  @open_exclusive 0x0000_0020

  @type state :: Sftpd.SFTP.Session.state()
  @type path_check :: :ok | {:error, atom()}
  @type path_exists :: boolean() | {:error, atom()}

  @spec read_open?(non_neg_integer()) :: boolean()
  def read_open?(pflags), do: (pflags &&& @open_read) != 0

  @spec write_open?(non_neg_integer()) :: boolean()
  def write_open?(pflags), do: (pflags &&& @open_write) != 0

  @spec append_open?(non_neg_integer()) :: boolean()
  def append_open?(pflags), do: (pflags &&& @open_append) != 0

  @spec create_open?(non_neg_integer()) :: boolean()
  def create_open?(pflags), do: (pflags &&& @open_create) != 0

  @spec truncate_open?(non_neg_integer()) :: boolean()
  def truncate_open?(pflags), do: (pflags &&& @open_truncate) != 0

  @spec exclusive_open?(non_neg_integer()) :: boolean()
  def exclusive_open?(pflags), do: (pflags &&& @open_exclusive) != 0

  @spec normalize_realpath(Backend.path() | charlist()) :: Backend.path()
  def normalize_realpath(path) do
    path =
      path
      |> to_string()
      |> String.trim_leading("/")

    if path == "", do: "/", else: "/" <> path
  end

  @spec validate_write_open(Backend.path(), non_neg_integer(), state()) :: path_check()
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

  @spec path_exists?(Backend.path(), state()) :: path_exists()
  def path_exists?(path, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, _attrs} -> true
      {:error, :enoent} -> false
      {:error, :no_such_file} -> false
      {:error, reason} -> {:error, reason}
    end
  end

  @spec require_directory(Backend.path(), state()) :: path_check()
  def require_directory(path, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _attrs} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec require_regular(Backend.path(), state()) :: path_check()
  def require_regular(path, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, %{type: :directory}} -> {:error, :eisdir}
      {:ok, _attrs} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reject_directory(Backend.path(), state()) :: path_check()
  def reject_directory(path, state) do
    case state.backend.file_attrs(path, state.session, state.backend_state) do
      {:ok, %{type: :directory}} -> {:error, :eisdir}
      _ -> :ok
    end
  end
end
