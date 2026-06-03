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
    clear = Packet.encode_clear("payload")

    {encrypted, decrypt_state} = Cipher.encrypt_packet(state, clear)
    assert IO.iodata_to_binary(encrypted) != IO.iodata_to_binary(clear)
    assert decrypt_state.sequence == 1

    assert {:ok, decrypted, "", next_state} =
             Cipher.decrypt_packet(state, IO.iodata_to_binary(encrypted))

    assert {:ok, "payload", ""} = Packet.decode_clear(decrypted)
    assert next_state.sequence == 1
  end

  test "rejects tampered ciphertext" do
    state = state(:server_to_client)
    {encrypted, _state} = Cipher.encrypt_packet(state, Packet.encode_clear("payload"))
    encrypted = IO.iodata_to_binary(encrypted)
    last = byte_size(encrypted) - 1
    <<prefix::binary-size(^last), byte>> = encrypted
    tampered = <<prefix::binary, Bitwise.bxor(byte, 1)>>

    assert {:error, :bad_packet} = Cipher.decrypt_packet(state, tampered)
  end

  test "decrypts multiple encrypted packets with sequence increments" do
    state = state(:server_to_client)
    {first, state} = Cipher.encrypt_packet(state, Packet.encode_clear("one"))
    {second, _state} = Cipher.encrypt_packet(state, Packet.encode_clear("two"))

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
