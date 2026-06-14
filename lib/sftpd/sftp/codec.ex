defmodule Sftpd.SFTP.Codec do
  @moduledoc false

  import Bitwise

  alias Sftpd.SFTP.SerializedPacket

  @ssh_fxp_init 1
  @ssh_fxp_version 2
  @ssh_fxp_open 3
  @ssh_fxp_close 4
  @ssh_fxp_read 5
  @ssh_fxp_write 6
  @ssh_fxp_lstat 7
  @ssh_fxp_fstat 8
  @ssh_fxp_setstat 9
  @ssh_fxp_fsetstat 10
  @ssh_fxp_opendir 11
  @ssh_fxp_readdir 12
  @ssh_fxp_remove 13
  @ssh_fxp_mkdir 14
  @ssh_fxp_rmdir 15
  @ssh_fxp_realpath 16
  @ssh_fxp_stat 17
  @ssh_fxp_rename 18
  @ssh_fxp_readlink 19
  @ssh_fxp_symlink 20

  @ssh_fxp_status 101
  @ssh_fxp_handle 102
  @ssh_fxp_data 103
  @ssh_fxp_name 104
  @ssh_fxp_attrs 105

  @ssh_fx_ok 0
  @ssh_fx_eof 1
  @ssh_fx_no_such_file 2
  @ssh_fx_permission_denied 3
  @ssh_fx_failure 4
  @ssh_fx_bad_message 5
  @ssh_fx_op_unsupported 8

  @ssh_filexfer_attr_size 0x0000_0001
  @ssh_filexfer_attr_uidgid 0x0000_0002
  @ssh_filexfer_attr_permissions 0x0000_0004
  @ssh_filexfer_attr_acmodtime 0x0000_0008

  @type request :: map()
  @type packet :: binary() | {:iodata, iodata(), non_neg_integer()}

  @spec split_packets(binary()) :: {[binary()], binary()}
  def split_packets(buffer), do: split_packets(buffer, [])

  defp split_packets(<<len::32, packet::binary-size(len), tail::binary>>, packets) do
    split_packets(tail, [packet | packets])
  end

  defp split_packets(<<_len::32, _rest::binary>> = buffer, packets),
    do: {Enum.reverse(packets), buffer}

  defp split_packets(buffer, packets), do: {Enum.reverse(packets), buffer}

  @spec decode(packet()) :: {:ok, request()} | {:error, :bad_message}
  def decode({:iodata, iodata, size}) when is_integer(size) and size >= 0 do
    case decode_iodata_write(iodata, size) do
      {:ok, request} -> {:ok, request}
      :not_write -> decode(IO.iodata_to_binary(iodata))
      :error -> {:error, :bad_message}
    end
  end

  def decode(<<@ssh_fxp_init, version::32, extensions::binary>>) do
    with {:ok, extensions} <- decode_extensions(extensions) do
      {:ok, %{type: :init, version: version, extensions: extensions}}
    end
  end

  def decode(<<@ssh_fxp_open, id::32, rest::binary>>) do
    with {:ok, filename, rest} <- take_string(rest),
         <<pflags::32, rest::binary>> <- rest,
         {:ok, attrs, <<>>} <- decode_attrs(rest) do
      {:ok, %{type: :open, id: id, filename: filename, pflags: pflags, attrs: attrs}}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode(<<@ssh_fxp_close, id::32, rest::binary>>) do
    with {:ok, handle, <<>>} <- take_string(rest) do
      {:ok, %{type: :close, id: id, handle: handle}}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode(<<@ssh_fxp_read, id::32, rest::binary>>) do
    with {:ok, handle, <<offset::64, len::32>>} <- take_string(rest) do
      {:ok, %{type: :read, id: id, handle: handle, offset: offset, len: len}}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode(<<@ssh_fxp_write, id::32, rest::binary>>) do
    with {:ok, handle, <<offset::64, rest::binary>>} <- take_string(rest),
         {:ok, data, <<>>} <- take_string(rest) do
      {:ok, %{type: :write, id: id, handle: handle, offset: offset, data: data}}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode(<<type, id::32, rest::binary>>)
      when type in [
             @ssh_fxp_lstat,
             @ssh_fxp_stat,
             @ssh_fxp_opendir,
             @ssh_fxp_remove,
             @ssh_fxp_rmdir,
             @ssh_fxp_realpath,
             @ssh_fxp_readlink
           ] do
    with {:ok, path, <<>>} <- take_string(rest) do
      {:ok, %{type: request_type(type), id: id, path: path}}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode(<<@ssh_fxp_fstat, id::32, rest::binary>>) do
    with {:ok, handle, <<>>} <- take_string(rest) do
      {:ok, %{type: :fstat, id: id, handle: handle}}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode(<<@ssh_fxp_readdir, id::32, rest::binary>>) do
    with {:ok, handle, <<>>} <- take_string(rest) do
      {:ok, %{type: :readdir, id: id, handle: handle}}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode(<<@ssh_fxp_mkdir, id::32, rest::binary>>) do
    with {:ok, path, rest} <- take_string(rest),
         {:ok, attrs, <<>>} <- decode_attrs(rest) do
      {:ok, %{type: :mkdir, id: id, path: path, attrs: attrs}}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode(<<type, id::32, rest::binary>>) when type in [@ssh_fxp_rename, @ssh_fxp_symlink] do
    with {:ok, oldpath, rest} <- take_string(rest),
         {:ok, newpath, <<>>} <- take_string(rest) do
      {:ok, %{type: request_type(type), id: id, oldpath: oldpath, newpath: newpath}}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode(<<type, id::32, rest::binary>>) when type in [@ssh_fxp_setstat, @ssh_fxp_fsetstat] do
    with {:ok, target, rest} <- take_string(rest),
         {:ok, attrs, <<>>} <- decode_attrs(rest) do
      {:ok, %{type: request_type(type), id: id, target: target, attrs: attrs}}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode(_), do: {:error, :bad_message}

  @spec version(non_neg_integer(), map()) :: SerializedPacket.t()
  def version(version \\ 3, extensions \\ %{}) do
    payload =
      [
        <<@ssh_fxp_version, version::32>>,
        Enum.map(extensions, fn {name, data} -> [string(name), string(data)] end)
      ]

    packet(payload)
  end

  @spec status(non_neg_integer(), atom() | non_neg_integer()) :: SerializedPacket.t()
  def status(id, status), do: status(id, status, status_message(status_code(status)))

  @spec status(non_neg_integer(), atom() | non_neg_integer(), iodata()) :: SerializedPacket.t()
  def status(id, status, message) do
    code = status_code(status)
    packet([<<@ssh_fxp_status, id::32, code::32>>, string(message), string("en-US")])
  end

  @spec handle(non_neg_integer(), binary()) :: SerializedPacket.t()
  def handle(id, handle), do: packet([<<@ssh_fxp_handle, id::32>>, string(handle)])

  @spec data(non_neg_integer(), iodata()) :: SerializedPacket.t()
  def data(id, data) do
    size = IO.iodata_length(data)
    header = <<size + 9::32, @ssh_fxp_data, id::32, size::32>>
    SerializedPacket.data(header, data, byte_size(header) + size)
  end

  @spec name(non_neg_integer(), [map()]) :: SerializedPacket.t()
  def name(id, entries) do
    packet([
      <<@ssh_fxp_name, id::32, length(entries)::32>>,
      Enum.map(entries, fn entry ->
        longname = Map.get(entry, :longname, Map.fetch!(entry, :name))

        [
          string(Map.fetch!(entry, :name)),
          string(longname),
          encode_attrs(Map.get(entry, :attrs, %{}))
        ]
      end)
    ])
  end

  @spec attrs(non_neg_integer(), map()) :: SerializedPacket.t()
  def attrs(id, attrs), do: packet([<<@ssh_fxp_attrs, id::32>>, encode_attrs(attrs)])

  @spec status_code(atom() | non_neg_integer()) :: non_neg_integer()
  def status_code(:ok), do: @ssh_fx_ok
  def status_code(:eof), do: @ssh_fx_eof
  def status_code(:enoent), do: @ssh_fx_no_such_file
  def status_code(:no_such_file), do: @ssh_fx_no_such_file
  def status_code(:eexist), do: @ssh_fx_failure
  def status_code(:eisdir), do: @ssh_fx_failure
  def status_code(:enotdir), do: @ssh_fx_failure
  def status_code(:eacces), do: @ssh_fx_permission_denied
  def status_code(:permission_denied), do: @ssh_fx_permission_denied
  def status_code(:bad_message), do: @ssh_fx_bad_message
  def status_code(:enotsup), do: @ssh_fx_op_unsupported
  def status_code(:op_unsupported), do: @ssh_fx_op_unsupported
  def status_code(:unsupported), do: @ssh_fx_op_unsupported
  def status_code(code) when is_integer(code), do: code
  def status_code(_), do: @ssh_fx_failure

  defp request_type(@ssh_fxp_lstat), do: :lstat
  defp request_type(@ssh_fxp_stat), do: :stat
  defp request_type(@ssh_fxp_opendir), do: :opendir
  defp request_type(@ssh_fxp_remove), do: :remove
  defp request_type(@ssh_fxp_rmdir), do: :rmdir
  defp request_type(@ssh_fxp_realpath), do: :realpath
  defp request_type(@ssh_fxp_readlink), do: :readlink
  defp request_type(@ssh_fxp_rename), do: :rename
  defp request_type(@ssh_fxp_symlink), do: :symlink
  defp request_type(@ssh_fxp_setstat), do: :setstat
  defp request_type(@ssh_fxp_fsetstat), do: :fsetstat

  defp packet(payload) do
    len = IO.iodata_length(payload)
    SerializedPacket.iodata([<<len::32>>, payload], len + 4)
  end

  defp string(data) when is_list(data), do: data |> to_string() |> string()
  defp string(data) when is_binary(data), do: [<<byte_size(data)::32>>, data]

  defp take_string(<<len::32, value::binary-size(len), tail::binary>>) do
    {:ok, value, tail}
  end

  defp take_string(_), do: {:error, :bad_message}

  defp decode_iodata_write(iodata, size) do
    with true <- size >= 21,
         {:ok, <<@ssh_fxp_write, id::32, handle_len::32>>, rest} <- take_iodata_binary(iodata, 9),
         {:ok, handle, rest} <- take_iodata_binary(rest, handle_len),
         {:ok, <<offset::64, data_len::32>>, rest} <- take_iodata_binary(rest, 12),
         {:ok, data, rest} <- take_iodata(rest, data_len),
         true <- iodata_empty?(rest) do
      {:ok, %{type: :write, id: id, handle: handle, offset: offset, data: data}}
    else
      {:ok, <<_other_type, _rest::binary>>, _rest_iodata} -> :not_write
      false -> :error
      :error -> :error
    end
  end

  defp take_iodata_binary(iodata, size) do
    with {:ok, value, rest} <- take_iodata(iodata, size) do
      {:ok, IO.iodata_to_binary(value), rest}
    end
  end

  defp take_iodata(iodata, size) when size >= 0 do
    case split_iodata(iodata, size, []) do
      {:ok, prefix, rest} -> {:ok, prefix, rest}
      :error -> :error
    end
  end

  defp split_iodata(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}
  defp split_iodata([], _size, _acc), do: :error

  defp split_iodata([part | rest], size, acc) when is_binary(part) do
    split_iodata_binary(part, rest, size, acc)
  end

  defp split_iodata([part | rest], size, acc) when is_list(part) do
    split_iodata(part ++ rest, size, acc)
  end

  defp split_iodata(part, size, acc) when is_binary(part) do
    split_iodata_binary(part, [], size, acc)
  end

  defp split_iodata(_iodata, _size, _acc), do: :error

  defp split_iodata_binary(part, rest, size, acc) do
    part_size = byte_size(part)

    cond do
      part_size == 0 ->
        split_iodata(rest, size, acc)

      part_size < size ->
        split_iodata(rest, size - part_size, [part | acc])

      part_size == size ->
        {:ok, Enum.reverse([part | acc]), rest}

      true ->
        <<prefix::binary-size(^size), suffix::binary>> = part
        {:ok, Enum.reverse([prefix | acc]), [suffix | rest]}
    end
  end

  defp iodata_empty?([]), do: true
  defp iodata_empty?(<<>>), do: true
  defp iodata_empty?([part | rest]), do: iodata_empty?(part) and iodata_empty?(rest)
  defp iodata_empty?(_), do: false

  defp decode_extensions(data), do: decode_extensions(data, %{})

  defp decode_extensions(<<>>, extensions), do: {:ok, extensions}

  defp decode_extensions(data, extensions) do
    with {:ok, name, rest} <- take_string(data),
         {:ok, value, rest} <- take_string(rest) do
      decode_extensions(rest, Map.put(extensions, name, value))
    else
      _ -> {:error, :bad_message}
    end
  end

  defp decode_attrs(<<flags::32, rest::binary>>), do: decode_attrs(flags, rest, %{})
  defp decode_attrs(_), do: {:error, :bad_message}

  defp decode_attrs(flags, rest, attrs) when (flags &&& @ssh_filexfer_attr_size) != 0 do
    case rest do
      <<size::64, rest::binary>> ->
        decode_attrs(flags &&& bnot(@ssh_filexfer_attr_size), rest, Map.put(attrs, :size, size))

      _ ->
        {:error, :bad_message}
    end
  end

  defp decode_attrs(flags, rest, attrs) when (flags &&& @ssh_filexfer_attr_uidgid) != 0 do
    case rest do
      <<uid::32, gid::32, rest::binary>> ->
        attrs = attrs |> Map.put(:uid, uid) |> Map.put(:gid, gid)
        decode_attrs(flags &&& bnot(@ssh_filexfer_attr_uidgid), rest, attrs)

      _ ->
        {:error, :bad_message}
    end
  end

  defp decode_attrs(flags, rest, attrs) when (flags &&& @ssh_filexfer_attr_permissions) != 0 do
    case rest do
      <<permissions::32, rest::binary>> ->
        decode_attrs(
          flags &&& bnot(@ssh_filexfer_attr_permissions),
          rest,
          Map.put(attrs, :permissions, permissions)
        )

      _ ->
        {:error, :bad_message}
    end
  end

  defp decode_attrs(flags, rest, attrs) when (flags &&& @ssh_filexfer_attr_acmodtime) != 0 do
    case rest do
      <<atime::32, mtime::32, rest::binary>> ->
        attrs = attrs |> Map.put(:atime, atime) |> Map.put(:mtime, mtime)
        decode_attrs(flags &&& bnot(@ssh_filexfer_attr_acmodtime), rest, attrs)

      _ ->
        {:error, :bad_message}
    end
  end

  defp decode_attrs(_flags, rest, attrs), do: {:ok, attrs, rest}

  defp encode_attrs(attrs) do
    flags =
      0
      |> maybe_flag(attrs, :size, @ssh_filexfer_attr_size)
      |> maybe_flag(attrs, :uid, @ssh_filexfer_attr_uidgid)
      |> maybe_flag(attrs, :permissions, @ssh_filexfer_attr_permissions)
      |> maybe_flag(attrs, :mtime, @ssh_filexfer_attr_acmodtime)

    [
      <<flags::32>>,
      if(Map.has_key?(attrs, :size), do: <<Map.fetch!(attrs, :size)::64>>, else: []),
      if(Map.has_key?(attrs, :uid),
        do: <<Map.get(attrs, :uid, 0)::32, Map.get(attrs, :gid, 0)::32>>,
        else: []
      ),
      if(Map.has_key?(attrs, :permissions),
        do: <<permissions(attrs)::32>>,
        else: []
      ),
      if(Map.has_key?(attrs, :mtime),
        do:
          <<Map.get(attrs, :atime, Map.fetch!(attrs, :mtime))::32, Map.fetch!(attrs, :mtime)::32>>,
        else: []
      )
    ]
  end

  defp maybe_flag(flags, attrs, field, flag) do
    if Map.has_key?(attrs, field), do: flags ||| flag, else: flags
  end

  defp permissions(%{permissions: permissions, type: :directory}),
    do: (permissions &&& 0o7777) ||| 0o040000

  defp permissions(%{permissions: permissions}), do: (permissions &&& 0o7777) ||| 0o100000

  defp status_message(@ssh_fx_ok), do: "Ok"
  defp status_message(@ssh_fx_eof), do: "End of file"
  defp status_message(@ssh_fx_no_such_file), do: "No such file"
  defp status_message(@ssh_fx_permission_denied), do: "Permission denied"
  defp status_message(@ssh_fx_bad_message), do: "Bad message"
  defp status_message(@ssh_fx_op_unsupported), do: "Operation unsupported"
  defp status_message(_), do: "Failure"
end
