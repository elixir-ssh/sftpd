defmodule Sftpd.SSH.CipherTest do
  use ExUnit.Case, async: true

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

  test "encrypts and decrypts one clear SSH packet" do
    state = state(:server_to_client)
    clear = Packet.encode_aead_packet("payload")

    {encrypted, decrypt_state} = Cipher.encrypt_packet(state, clear)
    assert decrypt_state.sequence == 1

    assert {:ok, decrypted, "", next_state} =
             Cipher.decrypt_packet(state, IO.iodata_to_binary(encrypted))

    assert {:ok, "payload", ""} = Packet.decode_clear(decrypted)
    assert next_state.sequence == 1
  end

  test "encrypts packet plaintext from iodata" do
    state = state(:server_to_client)
    clear = Packet.encode_aead_packet(["pay", ["load"]])

    {encrypted, _decrypt_state} = Cipher.encrypt_packet(state, clear)

    assert {:ok, decrypted, "", _next_state} =
             Cipher.decrypt_packet(state, IO.iodata_to_binary(encrypted))

    assert {:ok, "payload", ""} = Packet.decode_clear(decrypted)
  end

  test "decrypts packet payload from split length and encrypted body" do
    state = state(:server_to_client)
    clear = Packet.encode_aead_packet("payload")

    {encrypted, _decrypt_state} = Cipher.encrypt_packet(state, clear)
    <<packet_length::32, encrypted_body::binary>> = IO.iodata_to_binary(encrypted)

    assert {:ok, "payload", next_state} =
             Cipher.decrypt_packet_payload(state, packet_length, encrypted_body)

    assert next_state.sequence == 1
  end

  test "decrypts packet payload from buffered encrypted packets" do
    state = state(:server_to_client)

    {encrypted, _decrypt_state} =
      Cipher.encrypt_packet(state, Packet.encode_aead_packet("payload"))

    assert {:ok, "payload", "", next_state} =
             Cipher.decrypt_packet_payload(state, IO.iodata_to_binary(encrypted))

    assert next_state.sequence == 1

    assert :more =
             Cipher.decrypt_packet_payload(
               state,
               binary_part(IO.iodata_to_binary(encrypted), 0, 8)
             )
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

  test "wraps sequence numbers at the SSH uint32 boundary" do
    state = state(:server_to_client) |> Cipher.set_sequence(0xFFFF_FFFF)
    {_encrypted, state} = Cipher.encrypt_packet(state, Packet.encode_aead_packet("payload"))

    assert state.sequence == 0
  end

  test "decrypts multiple encrypted packets with sequence increments" do
    state = state(:server_to_client)
    {first, state} = Cipher.encrypt_packet(state, Packet.encode_aead_packet("one"))
    {second, _state} = Cipher.encrypt_packet(state, Packet.encode_aead_packet("two"))

    decrypt_state = state(:server_to_client)

    assert {:ok, first_clear, rest, decrypt_state} =
             Cipher.decrypt_packet(decrypt_state, IO.iodata_to_binary([first, second]))

    assert {:ok, "one", ""} = Packet.decode_clear(first_clear)
    assert {:ok, second_clear, "", _decrypt_state} = Cipher.decrypt_packet(decrypt_state, rest)
    assert {:ok, "two", ""} = Packet.decode_clear(second_clear)
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
