defmodule Sftpd.SSH.CipherTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.SSH.{Cipher, Packet}

  @algorithm "aes256-gcm@openssh.com"

  test "derives distinct aes states for each direction" do
    shared_secret = :crypto.strong_rand_bytes(32)
    exchange_hash = :crypto.strong_rand_bytes(32)
    session_id = exchange_hash

    c2s = Cipher.new(@algorithm, :client_to_server, shared_secret, exchange_hash, session_id)
    s2c = Cipher.new(@algorithm, :server_to_client, shared_secret, exchange_hash, session_id)

    assert byte_size(c2s.key) == 32
    assert byte_size(c2s.iv) == 12
    assert c2s.key != s2c.key
    assert c2s.iv != s2c.iv
  end

  property "encrypts and decrypts one clear SSH packet" do
    check all(payload <- binary(max_length: 512)) do
      state = state(:server_to_client)
      clear = Packet.encode_aead_packet(payload)

      {encrypted, decrypt_state} = Cipher.encrypt_packet(state, clear)
      assert decrypt_state.sequence == 1

      assert {:ok, decrypted, "", next_state} =
               Cipher.decrypt_packet(state, IO.iodata_to_binary(encrypted))

      assert {:ok, ^payload, ""} = Packet.decode_clear(decrypted)
      assert next_state.sequence == 1
    end
  end

  property "encrypts packet plaintext from iodata" do
    check all(
            head <- binary(max_length: 256),
            tail <- binary(max_length: 256)
          ) do
      state = state(:server_to_client)
      payload = [head, [tail]]
      expected = IO.iodata_to_binary(payload)
      clear = Packet.encode_aead_packet(payload)

      {encrypted, _decrypt_state} = Cipher.encrypt_packet(state, clear)

      assert {:ok, decrypted, "", _next_state} =
               Cipher.decrypt_packet(state, IO.iodata_to_binary(encrypted))

      assert {:ok, ^expected, ""} = Packet.decode_clear(decrypted)
    end
  end

  property "decrypts packet payload from split length and encrypted body" do
    check all(payload <- binary(max_length: 512)) do
      state = state(:server_to_client)
      clear = Packet.encode_aead_packet(payload)

      {encrypted, _decrypt_state} = Cipher.encrypt_packet(state, clear)
      <<packet_length::32, encrypted_body::binary>> = IO.iodata_to_binary(encrypted)

      assert {:ok, ^payload, next_state} =
               Cipher.decrypt_packet_payload(state, packet_length, encrypted_body)

      assert next_state.sequence == 1
    end
  end

  property "decrypts packet payload from buffered encrypted packets" do
    check all(payload <- binary(max_length: 512)) do
      state = state(:server_to_client)

      {encrypted, _decrypt_state} =
        Cipher.encrypt_packet(state, Packet.encode_aead_packet(payload))

      assert {:ok, ^payload, "", next_state} =
               Cipher.decrypt_packet_payload(state, IO.iodata_to_binary(encrypted))

      assert next_state.sequence == 1

      assert :more =
               Cipher.decrypt_packet_payload(
                 state,
                 binary_part(IO.iodata_to_binary(encrypted), 0, 8)
               )
    end
  end

  test "rejects tampered ciphertext" do
    state = state(:server_to_client)
    {encrypted, _state} = Cipher.encrypt_packet(state, Packet.encode_aead_packet("payload"))
    encrypted = IO.iodata_to_binary(encrypted)
    last = byte_size(encrypted) - 1
    {prefix, <<byte>>} = :erlang.split_binary(encrypted, last)
    tampered = <<prefix::binary, Bitwise.bxor(byte, 1)>>

    assert {:error, :bad_packet} = Cipher.decrypt_packet(state, tampered)
  end

  test "rejects tampered payload ciphertext and malformed split bodies" do
    state = state(:server_to_client)
    {encrypted, _state} = Cipher.encrypt_packet(state, Packet.encode_aead_packet("payload"))
    <<packet_length::32, encrypted_body::binary>> = IO.iodata_to_binary(encrypted)
    last = byte_size(encrypted_body) - 1
    {prefix, <<byte>>} = :erlang.split_binary(encrypted_body, last)

    assert {:error, :bad_packet} =
             Cipher.decrypt_packet_payload(
               state,
               packet_length,
               <<prefix::binary, Bitwise.bxor(byte, 1)>>
             )

    assert {:error, :bad_packet} = Cipher.decrypt_packet_payload(state, packet_length, "short")
  end

  test "rejects unreasonable encrypted packet lengths" do
    state = state(:server_to_client)
    oversized = <<2_097_153::32>>

    assert {:error, :invalid_packet_length} = Cipher.decrypt_packet(state, oversized)
    assert {:error, :invalid_packet_length} = Cipher.decrypt_packet_payload(state, oversized)

    assert {:error, :invalid_packet_length} =
             Cipher.decrypt_packet_payload(state, 2_097_153, "")
  end

  test "does not wrap sequence numbers at the SSH uint32 boundary" do
    state = state(:server_to_client) |> Cipher.set_sequence(0xFFFF_FFFF)
    {_encrypted, state} = Cipher.encrypt_packet(state, Packet.encode_aead_packet("payload"))

    assert state.sequence == 0x1_0000_0000
  end

  property "decrypts multiple encrypted packets with sequence increments" do
    check all(
            first_payload <- binary(max_length: 128),
            second_payload <- binary(max_length: 128)
          ) do
      state = state(:server_to_client)
      {first, state} = Cipher.encrypt_packet(state, Packet.encode_aead_packet(first_payload))
      {second, _state} = Cipher.encrypt_packet(state, Packet.encode_aead_packet(second_payload))

      decrypt_state0 = state(:server_to_client)

      assert {:ok, first_clear, rest, decrypt_state1} =
               Cipher.decrypt_packet(decrypt_state0, IO.iodata_to_binary([first, second]))

      assert {:ok, ^first_payload, ""} = Packet.decode_clear(first_clear)
      assert {:ok, second_clear, "", _decrypt_state} = Cipher.decrypt_packet(decrypt_state1, rest)
      assert {:ok, ^second_payload, ""} = Packet.decode_clear(second_clear)
    end
  end

  defp state(direction) do
    Cipher.new(
      @algorithm,
      direction,
      :binary.copy(<<1>>, 32),
      :binary.copy(<<2>>, 32),
      :binary.copy(<<3>>, 32)
    )
  end
end
