defmodule Sftpd.SSH.PacketTest do
  use ExUnit.Case, async: true

  alias Sftpd.SSH.Packet

  test "clear packet framing round-trips payloads" do
    encoded = IO.iodata_to_binary(Packet.encode_clear(["abc", "def"]))

    assert {:ok, "abcdef", ""} = Packet.decode_clear(encoded)
    assert rem(byte_size(encoded), 8) == 0
  end

  test "clear packet decoder preserves incomplete packets" do
    encoded = IO.iodata_to_binary(Packet.encode_clear("payload"))
    short = binary_part(encoded, 0, byte_size(encoded) - 1)

    assert :more = Packet.decode_clear(short)
  end

  test "clear packet decoder returns trailing bytes" do
    encoded = IO.iodata_to_binary([Packet.encode_clear("one"), Packet.encode_clear("two")])

    assert {:ok, "one", rest} = Packet.decode_clear(encoded)
    assert {:ok, "two", ""} = Packet.decode_clear(rest)
  end
end
