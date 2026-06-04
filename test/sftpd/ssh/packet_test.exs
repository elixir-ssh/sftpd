defmodule Sftpd.SSH.PacketTest do
  use ExUnit.Case, async: true

  alias Sftpd.SSH.Packet

  test "clear packet framing round-trips payloads" do
    encoded = IO.iodata_to_binary(Packet.encode_clear(["abc", "def"]))

    assert {:ok, "abcdef", ""} = Packet.decode_clear(encoded)
    assert rem(byte_size(encoded), 8) == 0
  end

  test "clear packet framing handles very small payloads" do
    encoded = IO.iodata_to_binary(Packet.encode_clear("", 4))

    assert {:ok, "", ""} = Packet.decode_clear(encoded)
    assert rem(byte_size(encoded), 4) == 0
    assert byte_size(encoded) >= 16
  end

  test "aead packet framing exposes length-prefixed plaintext" do
    encoded = IO.iodata_to_binary(Packet.encode_aead(["abc", "def"]))
    <<packet_len::32, plaintext::binary-size(packet_len)>> = encoded

    assert {:ok, "abcdef"} = Packet.decode_decrypted(packet_len, plaintext)
  end

  test "clear packet decoder preserves incomplete packets" do
    encoded = IO.iodata_to_binary(Packet.encode_clear("payload"))
    short = binary_part(encoded, 0, byte_size(encoded) - 1)

    assert :more = Packet.decode_clear(short)
  end

  test "clear packet decoder rejects invalid lengths and padding" do
    assert {:error, :bad_packet} = Packet.decode_clear(<<4::32, 0, 0, 0, 0>>)
    assert {:error, :bad_packet} = Packet.decode_clear(<<5::32, 6, 0, 0, 0, 0>>)
    assert :more = Packet.decode_clear(<<0, 0, 0>>)
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
    assert {:error, :bad_packet} = Packet.decode_decrypted(0, "")
    assert {:error, :bad_packet} = Packet.decode_decrypted(3, <<4, 1, 2>>)
    assert {:error, :bad_packet} = Packet.decode_decrypted(4, <<4, 1, 2>>)
  end

  test "returns message ids when payloads are available" do
    assert 94 = Packet.message_id(<<94, 0, 0, 0, 1>>)
    assert nil == Packet.message_id("")
  end
end
