defmodule Sftpd.SFTP.CodecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  import StreamData, except: [string: 1, string: 2]

  alias Sftpd.SFTP.{Codec, SerializedPacket}

  @attr_size 0x0000_0001
  @attr_uidgid 0x0000_0002
  @attr_permissions 0x0000_0004
  @attr_acmodtime 0x0000_0008

  property "splits complete packets and preserves incomplete trailing data" do
    check all(
            first_payload <- binary(min_length: 1, max_length: 64),
            second_payload <- binary(min_length: 1, max_length: 64),
            incomplete_payload <- binary(max_length: 64)
          ) do
      first = framed(first_payload)
      second = framed(second_payload)
      incomplete = <<byte_size(incomplete_payload) + 1::32, incomplete_payload::binary>>

      assert {[^first_payload, ^second_payload], ^incomplete} =
               Codec.split_packets(first <> second <> incomplete)
    end

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

  test "decodes fragmented write packets without flattening write data" do
    prefix = <<6, 3::32, string("h")::binary, 7::64, 7::32>>
    packet = {:iodata, [prefix, "pay", ["load"]], IO.iodata_length([prefix, "pay", ["load"]])}

    assert {:ok, %{type: :write, id: 3, handle: "h", offset: 7, data: data}} =
             Codec.decode(packet)

    assert IO.iodata_to_binary(data) == "payload"
    refute is_binary(data)

    split_inside_data = [
      <<6, 4::32, string("h")::binary, 8::64, 7::32, "pay">>,
      ["load"]
    ]

    assert {:ok, %{type: :write, id: 4, handle: "h", offset: 8, data: data}} =
             Codec.decode({:iodata, split_inside_data, IO.iodata_length(split_inside_data)})

    assert IO.iodata_to_binary(data) == "payload"
    assert ["pay", ["load"]] = data
  end

  test "rejects malformed fragmented write packets" do
    truncated = {:iodata, [<<6, 3::32, 1::32>>, "h", <<7::64, 8::32>>, "payload"], 25}
    trailing = {:iodata, [<<6, 3::32, 1::32>>, "h", <<7::64, 7::32>>, "payload", "x"], 26}

    assert {:error, :bad_message} = Codec.decode(truncated)
    assert {:error, :bad_message} = Codec.decode(trailing)
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

  property "encodes data payloads as split serialized packets" do
    check all(
            id <- integer(0..0xFFFF_FFFF),
            head <- binary(max_length: 256),
            tail <- binary(max_length: 256)
          ) do
      data = [head, tail]
      data_size = IO.iodata_length(data)
      packet_size = 13 + data_size

      packet = Codec.data(id, data)

      assert %SerializedPacket{kind: :data, header: header, data: ^data, size: ^packet_size} =
               packet

      assert <<payload_size::32, 103, ^id::32, ^data_size::32>> = header
      assert payload_size == 9 + data_size
    end
  end

  property "maps status atoms to sftp status codes" do
    check all(
            {status, code} <-
              member_of([
                {:ok, 0},
                {:eof, 1},
                {:enoent, 2},
                {:no_such_file, 2},
                {:eacces, 3},
                {:bad_message, 5},
                {:enotsup, 8},
                {:op_unsupported, 8},
                {:unsupported, 8},
                {:anything_else, 4}
              ])
          ) do
      assert ^code = Codec.status_code(status)
    end

    check all(code <- integer(0..255)) do
      assert ^code = Codec.status_code(code)
    end
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
