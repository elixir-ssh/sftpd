defmodule Sftpd.SSH.PacketTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.SSH.Packet

  property "clear packet framing round-trips payloads" do
    check all(
            head <- binary(max_length: 128),
            tail <- binary(max_length: 128),
            block_size <- member_of([4, 8, 16])
          ) do
      payload = [head, tail]
      expected = IO.iodata_to_binary(payload)

      encoded = IO.iodata_to_binary(Packet.encode_clear(payload, block_size))

      assert {:ok, ^expected, ""} = Packet.decode_clear(encoded)
      assert rem(byte_size(encoded), block_size) == 0
      assert byte_size(encoded) >= 16
    end
  end

  property "aead packet framing exposes length-prefixed plaintext" do
    check all(payload <- binary(max_length: 256)) do
      encoded = IO.iodata_to_binary(Packet.encode_aead(payload))
      <<packet_len::32, plaintext::binary-size(packet_len)>> = encoded

      assert {:ok, ^payload} = Packet.decode_decrypted(packet_len, plaintext)
    end
  end

  test "clear packet decoder preserves incomplete packets" do
    encoded = IO.iodata_to_binary(Packet.encode_clear("payload"))
    short = binary_part(encoded, 0, byte_size(encoded) - 1)

    assert :more = Packet.decode_clear(short)
  end

  test "clear packet decoder rejects invalid lengths and padding" do
    assert {:error, :bad_packet} = Packet.decode_clear(<<4::32, 0, 0, 0, 0>>)
    assert {:error, :bad_packet} = Packet.decode_clear(<<5::32, 0, "abcd">>)
    assert {:error, :bad_packet} = Packet.decode_clear(<<5::32, 3, "ab", "cd">>)
    assert {:error, :bad_packet} = Packet.decode_clear(<<5::32, 6, 0, 0, 0, 0>>)
    assert {:error, :bad_packet} = Packet.decode_clear(<<1_048_577::32>>)
    assert :more = Packet.decode_clear(<<0, 0, 0>>)
  end

  test "clear packet decoder returns trailing bytes" do
    encoded = IO.iodata_to_binary([Packet.encode_clear("one"), Packet.encode_clear("two")])

    assert {:ok, "one", rest} = Packet.decode_clear(encoded)
    assert {:ok, "two", ""} = Packet.decode_clear(rest)
  end

  property "decrypted packet decoder returns payload without a length-prefixed copy" do
    check all(payload <- binary(max_length: 256)) do
      <<packet_len::32, plaintext::binary>> = IO.iodata_to_binary(Packet.encode_clear(payload))

      assert {:ok, ^payload} = Packet.decode_decrypted(packet_len, plaintext)
    end
  end

  test "decrypted packet decoder rejects malformed plaintext" do
    assert {:error, :bad_packet} = Packet.decode_decrypted(0, "")
    assert {:error, :bad_packet} = Packet.decode_decrypted(5, <<0, "abcd">>)
    assert {:error, :bad_packet} = Packet.decode_decrypted(5, <<3, "abcd">>)
    assert {:error, :bad_packet} = Packet.decode_decrypted(3, <<4, 1, 2>>)
    assert {:error, :bad_packet} = Packet.decode_decrypted(4, <<4, 1, 2>>)
  end

  test "returns message ids when payloads are available" do
    assert 94 = Packet.message_id(<<94, 0, 0, 0, 1>>)
    assert nil == Packet.message_id("")
  end
end
