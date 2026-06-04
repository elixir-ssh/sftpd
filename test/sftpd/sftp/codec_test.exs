defmodule Sftpd.SFTP.CodecTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Sftpd.SFTP.{Codec, SerializedPacket}

  @attr_size 0x0000_0001
  @attr_uidgid 0x0000_0002
  @attr_permissions 0x0000_0004
  @attr_acmodtime 0x0000_0008

  test "splits complete packets and preserves incomplete trailing data" do
    init = <<1, 3::32>>
    close = <<4, 9::32, string("handle")::binary>>
    first = framed(init)
    second = framed(close)
    incomplete = <<9::32, "short">>

    assert {[^init, ^close], ^incomplete} = Codec.split_packets(first <> second <> incomplete)

    assert {[], <<1, 2, 3>>} = Codec.split_packets(<<1, 2, 3>>)
  end

  test "decodes init with extensions" do
    assert {:ok, %{type: :init, version: 3, extensions: %{"a" => "b"}}} =
             Codec.decode(<<1, 3::32, string("a")::binary, string("b")::binary>>)

    assert {:error, :bad_message} = Codec.decode(<<1, 3::32, 0, 0, 0, 9, "bad">>)
  end

  test "decodes file open, read, write, and close requests" do
    attrs =
      <<@attr_size ||| @attr_uidgid ||| @attr_permissions ||| @attr_acmodtime::32, 123::64,
        10::32, 20::32, 0o100644::32, 30::32, 40::32>>

    assert {:ok,
            %{
              type: :open,
              id: 1,
              filename: "/file",
              pflags: 0x0B,
              attrs: %{size: 123, uid: 10, gid: 20, permissions: 0o100644, atime: 30, mtime: 40}
            }} = Codec.decode(<<3, 1::32, string("/file")::binary, 0x0B::32, attrs::binary>>)

    assert {:ok, %{type: :read, id: 2, handle: "h", offset: 42, len: 8192}} =
             Codec.decode(<<5, 2::32, string("h")::binary, 42::64, 8192::32>>)

    assert {:ok, %{type: :write, id: 3, handle: "h", offset: 7, data: "payload"}} =
             Codec.decode(<<6, 3::32, string("h")::binary, 7::64, string("payload")::binary>>)

    assert {:ok, %{type: :close, id: 4, handle: "h"}} =
             Codec.decode(<<4, 4::32, string("h")::binary>>)
  end

  test "decodes path, handle, pair, and attrs requests" do
    for {wire_type, type} <- [
          {7, :lstat},
          {17, :stat},
          {11, :opendir},
          {13, :remove},
          {15, :rmdir},
          {16, :realpath},
          {19, :readlink}
        ] do
      assert {:ok, %{type: ^type, id: 10, path: "/path"}} =
               Codec.decode(<<wire_type, 10::32, string("/path")::binary>>)
    end

    assert {:ok, %{type: :fstat, id: 11, handle: "h"}} =
             Codec.decode(<<8, 11::32, string("h")::binary>>)

    assert {:ok, %{type: :readdir, id: 12, handle: "d"}} =
             Codec.decode(<<12, 12::32, string("d")::binary>>)

    assert {:ok, %{type: :mkdir, id: 13, path: "/dir", attrs: %{permissions: 0o40755}}} =
             Codec.decode(
               <<14, 13::32, string("/dir")::binary, @attr_permissions::32, 0o40755::32>>
             )

    assert {:ok, %{type: :rename, id: 14, oldpath: "/a", newpath: "/b"}} =
             Codec.decode(<<18, 14::32, string("/a")::binary, string("/b")::binary>>)

    assert {:ok, %{type: :symlink, id: 15, oldpath: "/target", newpath: "/link"}} =
             Codec.decode(<<20, 15::32, string("/target")::binary, string("/link")::binary>>)

    assert {:ok, %{type: :setstat, id: 16, target: "/file", attrs: %{size: 9}}} =
             Codec.decode(<<9, 16::32, string("/file")::binary, @attr_size::32, 9::64>>)

    assert {:ok, %{type: :fsetstat, id: 17, target: "h", attrs: %{mtime: 2}}} =
             Codec.decode(<<10, 17::32, string("h")::binary, @attr_acmodtime::32, 1::32, 2::32>>)
  end

  test "rejects malformed request packets" do
    assert {:error, :bad_message} = Codec.decode(<<3, 1::32, 0, 0, 0, 10, "short">>)
    assert {:error, :bad_message} = Codec.decode(<<5, 1::32, string("h")::binary, 0::64>>)
    assert {:error, :bad_message} = Codec.decode(<<14, 1::32, string("/dir")::binary, 1::32>>)
    assert {:error, :bad_message} = Codec.decode(<<255, 1::32>>)
  end

  test "encodes response packets" do
    assert <<2, 3::32, rest::binary>> = unwrap(Codec.version(3, %{"x" => "y"}))
    assert {:ok, "x", rest2} = take_string(rest)
    assert {:ok, "y", ""} = take_string(rest2)

    assert <<101, 1::32, 0::32, rest::binary>> = unwrap(Codec.status(1, :ok))
    assert {:ok, "Ok", rest2} = take_string(rest)
    assert {:ok, "en-US", ""} = take_string(rest2)

    assert <<101, 2::32, 3::32, rest::binary>> =
             unwrap(Codec.status(2, :permission_denied, "no"))

    assert {:ok, "no", rest2} = take_string(rest)
    assert {:ok, "en-US", ""} = take_string(rest2)

    assert <<102, 3::32, rest::binary>> = unwrap(Codec.handle(3, "handle"))
    assert {:ok, "handle", ""} = take_string(rest)
    assert <<105, 4::32, @attr_size::32, 55::64>> = unwrap(Codec.attrs(4, %{size: 55}))

    assert <<104, 5::32, 1::32, rest::binary>> =
             unwrap(
               Codec.name(5, [
                 %{name: "dir", attrs: %{type: :directory, permissions: 0o755, mtime: 9}}
               ])
             )

    assert {:ok, "dir", rest2} = take_string(rest)
    assert {:ok, "dir", <<flags::32, attrs::binary>>} = take_string(rest2)
    assert (flags &&& @attr_permissions) != 0
    assert (flags &&& @attr_acmodtime) != 0
    assert <<0o40755::32, 9::32, 9::32>> = attrs
  end

  test "encodes large data payloads as split serialized packets" do
    packet = Codec.data(9, ["abc", "def"])

    assert %SerializedPacket{kind: :data, header: header, data: ["abc", "def"], size: 19} =
             packet

    assert <<15::32, 103, 9::32, 6::32>> = header
  end

  test "maps status atoms to sftp status codes" do
    assert 0 = Codec.status_code(:ok)
    assert 1 = Codec.status_code(:eof)
    assert 2 = Codec.status_code(:enoent)
    assert 2 = Codec.status_code(:no_such_file)
    assert 3 = Codec.status_code(:eacces)
    assert 5 = Codec.status_code(:bad_message)
    assert 8 = Codec.status_code(:enotsup)
    assert 8 = Codec.status_code(:op_unsupported)
    assert 8 = Codec.status_code(:unsupported)
    assert 99 = Codec.status_code(99)
    assert 4 = Codec.status_code(:anything_else)
  end

  defp framed(packet), do: <<byte_size(packet)::32, packet::binary>>
  defp string(data), do: <<byte_size(data)::32, data::binary>>

  defp unwrap(%SerializedPacket{kind: :iodata, iodata: iodata}),
    do: IO.iodata_to_binary(iodata) |> unwrap()

  defp unwrap(%SerializedPacket{kind: :data, header: header, data: data}),
    do: IO.iodata_to_binary([header, data]) |> unwrap()

  defp unwrap(<<len::32, packet::binary-size(len)>>), do: packet

  defp take_string(<<len::32, value::binary-size(len), rest::binary>>),
    do: {:ok, value, rest}
end
