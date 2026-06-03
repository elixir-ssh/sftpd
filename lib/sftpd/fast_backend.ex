defmodule Sftpd.FastBackend do
  @moduledoc """
  Handle-first backend contract for the pure-Elixir SFTP transport.

  This API is intentionally separate from `Sftpd.Backend`, which exists to
  satisfy OTP's `:ssh_sftpd_file_api` callback shape. Fast backends keep open
  file state in backend-managed handles and operate on explicit offsets from
  SFTP requests.
  """

  @type state :: term()
  @type session :: map()
  @type path :: binary()
  @type attrs :: map()
  @type read_handle :: term()
  @type write_handle :: term()
  @type dir_handle :: term()
  @type entry :: %{name: binary(), attrs: attrs()}

  @callback open_read(path(), session(), state()) ::
              {:ok, read_handle()} | {:error, atom()}
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

  @doc false
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
end
