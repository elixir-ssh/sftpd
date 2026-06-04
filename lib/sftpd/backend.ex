defmodule Sftpd.Backend do
  @moduledoc """
  Handle-first storage backend contract for SFTP transports.

  Backends keep open file and directory state in backend-managed handles. SFTP
  transports call the callbacks with binary SFTP paths and explicit offsets.
  Backends should normalize paths for their own storage model with
  `normalize_path/1` when they need slash-free keys.
  """

  @type state :: term()
  @type session :: map()
  @type path :: binary()
  @type attrs :: map()
  @type read_handle :: term()
  @type write_handle :: term()
  @type dir_handle :: term()
  @type entry :: %{name: binary(), attrs: attrs()}

  @typedoc "Erlang file_info tuple used by OTP ssh_sftpd adapters"
  @type file_info ::
          {:file_info, non_neg_integer(), :regular | :directory, :read | :write | :read_write,
           tuple(), tuple(), tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback open_read(path(), session(), state()) :: {:ok, read_handle()} | {:error, atom()}
  @callback read_at(read_handle(), non_neg_integer(), pos_integer(), state()) ::
              {:ok, iodata()} | :eof | {:error, atom()}
  @callback open_write(path(), attrs(), session(), state()) ::
              {:ok, write_handle()} | {:error, atom()}
  @callback write_at(write_handle(), non_neg_integer(), iodata(), state()) ::
              {:ok, write_handle()} | {:error, atom()}
  @callback finish_write(write_handle(), state()) :: :ok | {:error, atom()}
  @callback abort_write(write_handle(), state()) :: :ok
  @callback open_dir(path(), session(), state()) :: {:ok, dir_handle()} | {:error, atom()}
  @callback read_dir(dir_handle(), state()) ::
              {:ok, [entry()], dir_handle()} | :eof | {:error, atom()}
  @callback close_dir(dir_handle(), state()) :: :ok
  @callback file_attrs(path(), session(), state()) :: {:ok, attrs()} | {:error, atom()}
  @callback make_dir(path(), attrs(), session(), state()) :: :ok | {:error, atom()}
  @callback del_dir(path(), session(), state()) :: :ok | {:error, atom()}
  @callback delete(path(), session(), state()) :: :ok | {:error, atom()}
  @callback rename(path(), path(), session(), state()) :: :ok | {:error, atom()}

  @doc """
  Normalize an SFTP path to a binary without leading slashes.
  """
  @spec normalize_path(path() | charlist()) :: String.t()
  def normalize_path(path) do
    path |> to_string() |> String.trim_leading("/")
  end

  @doc """
  Return true if the path refers to the root directory.
  """
  @spec root_path?(path() | charlist()) :: boolean()
  def root_path?(path), do: to_string(path) in ["/", "/.", "/..", "..", ".", ""]

  @doc """
  Build a file_info tuple for a regular file.
  """
  @spec file_info(non_neg_integer(), :calendar.datetime(), :read | :write | :read_write) ::
          file_info()
  def file_info(size, mtime, access \\ :read_write) do
    {:file_info, size, :regular, access, mtime, mtime, mtime, 33188, 1, 0, 0,
     :rand.uniform(32767), 1, 1}
  end

  @doc """
  Build a file_info tuple for a directory.
  """
  @spec directory_info() :: file_info()
  def directory_info do
    timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()

    {:file_info, 4096, :directory, :read, timestamp, timestamp, timestamp, 16877, 2, 0, 0, 0, 1,
     1}
  end

  @doc false
  def unix_time({{year, month, day}, {hour, minute, second}}) do
    {{year, month, day}, {hour, minute, second}}
    |> NaiveDateTime.from_erl!()
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix()
  end

  def unix_time(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix()
  end

  def unix_time(_), do: System.os_time(:second)

  @doc """
  Convert an Erlang `:file_info` tuple to backend attribute maps.
  """
  def attrs_from_file_info(
        {:file_info, size, type, _access, _atime, mtime, _ctime, mode, _links, uid, gid, _major,
         _minor, _inode}
      ) do
    file_type =
      case type do
        :directory -> :directory
        :regular -> :regular
        _ -> :regular
      end

    %{
      size: size,
      type: file_type,
      permissions: mode,
      uid: uid,
      gid: gid,
      atime: unix_time(mtime),
      mtime: unix_time(mtime)
    }
  end

  @doc false
  def file_info_from_attrs(attrs) do
    type = Map.get(attrs, :type, :regular)
    size = Map.get(attrs, :size, 0)
    permissions = Map.get(attrs, :permissions, if(type == :directory, do: 16877, else: 33188))
    uid = Map.get(attrs, :uid, 1)
    gid = Map.get(attrs, :gid, 1)
    mtime = attrs |> Map.get(:mtime, System.os_time(:second)) |> erl_time_from_unix()

    {:file_info, size, type, :read_write, mtime, mtime, mtime, permissions, 1, 0, 0,
     :rand.uniform(32767), uid, gid}
  end

  defp erl_time_from_unix(seconds) when is_integer(seconds) do
    seconds
    |> DateTime.from_unix!()
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
  end

  defp erl_time_from_unix(%NaiveDateTime{} = naive), do: NaiveDateTime.to_erl(naive)
  defp erl_time_from_unix({{_, _, _}, {_, _, _}} = erl), do: erl
  defp erl_time_from_unix(_), do: erl_time_from_unix(System.os_time(:second))
end
