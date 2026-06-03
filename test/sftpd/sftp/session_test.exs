defmodule Sftpd.SFTP.SessionTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Sftpd.Backends.Memory
  alias Sftpd.SFTP.Session

  @ssh_fxp_open 3
  @ssh_fxp_close 4
  @ssh_fxp_read 5
  @ssh_fxp_write 6
  @ssh_fxp_opendir 11
  @ssh_fxp_readdir 12
  @ssh_fxp_mkdir 14
  @ssh_fxp_realpath 16
  @ssh_fxp_status 101
  @ssh_fxp_handle 102
  @ssh_fxp_data 103
  @ssh_fxp_name 104

  setup do
    {:ok, backend_state} = Memory.init([])
    %{session: Session.new(Memory, backend_state, %{username: "test"})}
  end

  test "writes and reads a file through opaque session handles", %{session: session} do
    {response, session} = handle(open(1, "/hello.txt", 0x0000_000A), session)
    assert {:handle, 1, write_handle} = decode_response(response)

    {response, session} = handle(write(2, write_handle, 0, "hello"), session)
    assert {:status, 2, 0} = decode_response(response)

    {response, session} = handle(close(3, write_handle), session)
    assert {:status, 3, 0} = decode_response(response)

    {response, session} = handle(open(4, "/hello.txt", 0x0000_0001), session)
    assert {:handle, 4, read_handle} = decode_response(response)

    {response, session} = handle(read(5, read_handle, 0, 64), session)
    assert {:data, 5, "hello"} = decode_response(response)

    {response, session} = handle(read(6, read_handle, 5, 64), session)
    assert {:status, 6, 1} = decode_response(response)

    {response, _session} = handle(close(7, read_handle), session)
    assert {:status, 7, 0} = decode_response(response)
  end

  test "writes sparse offsets without discarding earlier chunks", %{session: session} do
    {response, session} = handle(open(1, "/sparse.bin", 0x0000_000A), session)
    {:handle, 1, handle} = decode_response(response)

    {_response, session} = handle(write(2, handle, 4, "tail"), session)
    {_response, session} = handle(write(3, handle, 0, "head"), session)
    {_response, session} = handle(close(4, handle), session)

    {response, session} = handle(open(5, "/sparse.bin", 0x0000_0001), session)
    {:handle, 5, read_handle} = decode_response(response)

    {response, _session} = handle(read(6, read_handle, 0, 8), session)
    assert {:data, 6, "headtail"} = decode_response(response)
  end

  test "directory handles return one listing and then eof", %{session: session} do
    {_response, session} = handle(mkdir(1, "/dir"), session)

    {response, session} = handle(open(2, "/dir/file.txt", 0x0000_000A), session)
    {:handle, 2, file_handle} = decode_response(response)
    {_response, session} = handle(write(3, file_handle, 0, "data"), session)
    {_response, session} = handle(close(4, file_handle), session)

    {response, session} = handle(opendir(5, "/dir"), session)
    assert {:handle, 5, dir_handle} = decode_response(response)

    {response, session} = handle(readdir(6, dir_handle), session)
    assert {:name, 6, names} = decode_response(response)
    assert "." in names
    assert ".." in names
    assert "file.txt" in names

    {response, _session} = handle(readdir(7, dir_handle), session)
    assert {:status, 7, 1} = decode_response(response)
  end

  test "realpath returns an absolute path", %{session: session} do
    {response, _session} = handle(realpath(1, "dir/file.txt"), session)
    assert {:name, 1, ["/dir/file.txt"]} = decode_response(response)
  end

  defp handle(packet, session) do
    {:ok, request} = unwrap(packet)
    Session.handle_packet(request, session)
  end

  defp unwrap(iodata) do
    case IO.iodata_to_binary(iodata) do
      <<len::32, packet::binary-size(len)>> -> {:ok, packet}
    end
  end

  defp open(id, path, pflags),
    do: packet([<<@ssh_fxp_open, id::32>>, string(path), <<pflags::32, 0::32>>])

  defp close(id, handle), do: packet([<<@ssh_fxp_close, id::32>>, string(handle)])

  defp read(id, handle, offset, len),
    do: packet([<<@ssh_fxp_read, id::32>>, string(handle), <<offset::64, len::32>>])

  defp write(id, handle, offset, data),
    do: packet([<<@ssh_fxp_write, id::32>>, string(handle), <<offset::64>>, string(data)])

  defp opendir(id, path), do: packet([<<@ssh_fxp_opendir, id::32>>, string(path)])
  defp readdir(id, handle), do: packet([<<@ssh_fxp_readdir, id::32>>, string(handle)])
  defp mkdir(id, path), do: packet([<<@ssh_fxp_mkdir, id::32>>, string(path), <<0::32>>])
  defp realpath(id, path), do: packet([<<@ssh_fxp_realpath, id::32>>, string(path)])

  defp packet(payload) do
    len = IO.iodata_length(payload)
    [<<len::32>>, payload]
  end

  defp string(data) when is_binary(data), do: [<<byte_size(data)::32>>, data]

  defp decode_response(response) do
    {:ok, response} = unwrap(response)

    case response do
      <<@ssh_fxp_status, id::32, code::32, _rest::binary>> ->
        {:status, id, code}

      <<@ssh_fxp_handle, id::32, rest::binary>> ->
        {:ok, handle, <<>>} = take_string(rest)
        {:handle, id, handle}

      <<@ssh_fxp_data, id::32, rest::binary>> ->
        {:ok, data, <<>>} = take_string(rest)
        {:data, id, data}

      <<@ssh_fxp_name, id::32, count::32, rest::binary>> ->
        {names, <<>>} =
          Enum.map_reduce(1..count, rest, fn _index, acc ->
            {:ok, name, acc} = take_string(acc)
            {:ok, _longname, acc} = take_string(acc)
            {:ok, _attrs, acc} = take_attrs(acc)
            {name, acc}
          end)

        {:name, id, names}
    end
  end

  defp take_string(<<len::32, rest::binary>>) do
    <<value::binary-size(^len), rest::binary>> = rest
    {:ok, value, rest}
  end

  defp take_attrs(<<flags::32, rest::binary>>) do
    with {:ok, attrs, rest} <- maybe_take_size(flags, rest, %{}),
         {:ok, attrs, rest} <- maybe_take_uidgid(flags, rest, attrs),
         {:ok, attrs, rest} <- maybe_take_permissions(flags, rest, attrs),
         {:ok, attrs, rest} <- maybe_take_acmodtime(flags, rest, attrs) do
      {:ok, attrs, rest}
    end
  end

  defp maybe_take_size(flags, <<size::64, rest::binary>>, attrs) when (flags &&& 1) != 0,
    do: {:ok, Map.put(attrs, :size, size), rest}

  defp maybe_take_size(_flags, rest, attrs), do: {:ok, attrs, rest}

  defp maybe_take_uidgid(flags, <<uid::32, gid::32, rest::binary>>, attrs)
       when (flags &&& 2) != 0,
       do: {:ok, attrs |> Map.put(:uid, uid) |> Map.put(:gid, gid), rest}

  defp maybe_take_uidgid(_flags, rest, attrs), do: {:ok, attrs, rest}

  defp maybe_take_permissions(flags, <<permissions::32, rest::binary>>, attrs)
       when (flags &&& 4) != 0,
       do: {:ok, Map.put(attrs, :permissions, permissions), rest}

  defp maybe_take_permissions(_flags, rest, attrs), do: {:ok, attrs, rest}

  defp maybe_take_acmodtime(flags, <<atime::32, mtime::32, rest::binary>>, attrs)
       when (flags &&& 8) != 0,
       do: {:ok, attrs |> Map.put(:atime, atime) |> Map.put(:mtime, mtime), rest}

  defp maybe_take_acmodtime(_flags, rest, attrs), do: {:ok, attrs, rest}
end
