defmodule Sftpd.SSH.KexTest do
  use ExUnit.Case, async: true

  alias Sftpd.SSH.{Kex, Keys, Wire}

  test "curve25519 shared secrets match on both sides" do
    {server_public, server_private} = Kex.generate_keypair()
    {client_public, client_private} = Kex.generate_keypair()

    assert {:ok, shared_secret} = Kex.shared_secret(client_public, server_private)
    assert {:ok, ^shared_secret} = Kex.shared_secret(server_public, client_private)
  end

  test "curve25519 shared secret rejects invalid peer keys" do
    {_server_public, server_private} = Kex.generate_keypair()

    assert {:error, :key_exchange_failed} = Kex.shared_secret(<<1, 2, 3>>, server_private)
    assert {:error, :key_exchange_failed} = Kex.shared_secret(<<0::256>>, server_private)
  end

  test "exchange hash is deterministic for identical transcript" do
    context = %{
      client_version: "SSH-2.0-client",
      server_version: "SSH-2.0-sftpd-elixir",
      client_kexinit: <<20, 0::128, 0::32>>,
      server_kexinit: <<20, 1::128, 0::32>>,
      host_key_blob: "host-key",
      client_public: :binary.copy(<<1>>, 32),
      server_public: :binary.copy(<<2>>, 32),
      shared_secret: :binary.copy(<<3>>, 32)
    }

    assert Kex.exchange_hash(context) == Kex.exchange_hash(context)
    assert byte_size(Kex.exchange_hash(context)) == 32
  end

  test "ecdh reply contains host key, server public key, and ed25519 signature" do
    system_dir = Sftpd.Test.SSHKeys.generate_system_dir()
    {:ok, host_key} = Keys.load_host_key(system_dir)
    exchange_hash = :crypto.strong_rand_bytes(32)
    server_public = :crypto.strong_rand_bytes(32)

    reply = Kex.ecdh_reply(host_key, server_public, exchange_hash)

    assert <<31, rest::binary>> = reply
    assert {:ok, host_key_blob, rest} = Wire.take_string(rest)
    assert {:ok, ^server_public, rest} = Wire.take_string(rest)
    assert {:ok, signature_blob, ""} = Wire.take_string(rest)
    assert host_key_blob == host_key.blob
    assert {:ok, "ssh-ed25519", rest} = Wire.take_string(signature_blob)
    assert {:ok, signature, ""} = Wire.take_string(rest)
    assert Keys.verify_signature(host_key, exchange_hash, signature)
  end
end
