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

  test "decrypted packet decoder returns payload without a length-prefixed copy" do
    <<packet_len::32, plaintext::binary>> = IO.iodata_to_binary(Packet.encode_clear("payload"))

    assert {:ok, "payload"} = Packet.decode_decrypted(packet_len, plaintext)
  end

  test "decrypted packet decoder rejects malformed plaintext" do
    assert {:error, :bad_packet} = Packet.decode_decrypted(3, <<4, 1, 2>>)
    assert {:error, :bad_packet} = Packet.decode_decrypted(4, <<4, 1, 2>>)
  end
end
