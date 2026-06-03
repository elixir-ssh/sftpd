defmodule Sftpd.SSH.Kex do
  @moduledoc false

  alias Sftpd.SSH.{Keys, Wire}

  @type context :: %{
          client_version: binary(),
          server_version: binary(),
          client_kexinit: binary(),
          server_kexinit: binary(),
          host_key_blob: binary(),
          client_public: binary(),
          server_public: binary(),
          shared_secret: binary()
        }

  @spec generate_keypair() :: {binary(), binary()}
  def generate_keypair do
    :crypto.generate_key(:eddh, :x25519)
  end

  @spec shared_secret(binary(), binary()) :: binary()
  def shared_secret(client_public, server_private) do
    :crypto.compute_key(:eddh, client_public, server_private, :x25519)
  end

  @spec exchange_hash(context()) :: binary()
  def exchange_hash(context) do
    :crypto.hash(:sha256, exchange_payload(context))
  end

  @spec exchange_payload(context()) :: binary()
  def exchange_payload(context) do
    IO.iodata_to_binary([
      Wire.string(context.client_version),
      Wire.string(context.server_version),
      Wire.string(context.client_kexinit),
      Wire.string(context.server_kexinit),
      Wire.string(context.host_key_blob),
      Wire.string(context.client_public),
      Wire.string(context.server_public),
      Wire.mpint(context.shared_secret)
    ])
  end

  @spec ecdh_reply(Keys.ed25519_host_key(), binary(), binary()) :: binary()
  def ecdh_reply(host_key, server_public, exchange_hash) do
    signature = Keys.signature(host_key, exchange_hash)

    IO.iodata_to_binary([
      <<31>>,
      Wire.string(host_key.blob),
      Wire.string(server_public),
      Wire.string(signature)
    ])
  end

  @spec derive_key(binary(), binary(), binary(), byte(), non_neg_integer()) :: binary()
  def derive_key(shared_secret, exchange_hash, session_id, letter, length) do
    key =
      :crypto.hash(:sha256, [Wire.mpint(shared_secret), exchange_hash, <<letter>>, session_id])

    expand_key(shared_secret, exchange_hash, key, length)
  end

  defp expand_key(_shared_secret, _exchange_hash, key, length) when byte_size(key) >= length do
    binary_part(key, 0, length)
  end

  defp expand_key(shared_secret, exchange_hash, key, length) do
    next = :crypto.hash(:sha256, [Wire.mpint(shared_secret), exchange_hash, key])
    expand_key(shared_secret, exchange_hash, key <> next, length)
  end
end
