defmodule Sftpd.SSH.KexTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  property "exchange hash is deterministic for identical transcript" do
    check all(
            client_kexinit <- binary(min_length: 1, max_length: 128),
            server_kexinit <- binary(min_length: 1, max_length: 128),
            host_key_blob <- binary(min_length: 1, max_length: 128),
            client_public <- binary(min_length: 32, max_length: 32),
            server_public <- binary(min_length: 32, max_length: 32),
            shared_secret <- binary(min_length: 32, max_length: 32)
          ) do
      context = %{
        client_version: "SSH-2.0-client",
        server_version: "SSH-2.0-sftpd-elixir",
        client_kexinit: client_kexinit,
        server_kexinit: server_kexinit,
        host_key_blob: host_key_blob,
        client_public: client_public,
        server_public: server_public,
        shared_secret: shared_secret
      }

      assert Kex.exchange_hash(context) == Kex.exchange_hash(context)
      assert byte_size(Kex.exchange_hash(context)) == 32
    end
  end

  property "ecdh reply contains host key, server public key, and ed25519 signature" do
    check all(
            exchange_hash <- binary(min_length: 32, max_length: 32),
            server_public <- binary(min_length: 32, max_length: 32)
          ) do
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()
      {:ok, host_key} = Keys.load_host_key(system_dir)

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
end
