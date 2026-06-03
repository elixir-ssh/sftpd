defmodule Sftpd.SSH.Algorithms do
  @moduledoc false

  alias Sftpd.SSH.Wire

  @kex_algorithms ["curve25519-sha256", "curve25519-sha256@libssh.org"]
  @server_host_key_algorithms ["ssh-ed25519"]
  @ciphers ["aes256-gcm@openssh.com"]
  @macs ["hmac-sha2-256", "hmac-sha2-512", "none"]
  @compression ["none"]
  @languages []

  @type kexinit :: %{
          cookie: binary(),
          kex_algorithms: [binary()],
          server_host_key_algorithms: [binary()],
          encryption_algorithms_client_to_server: [binary()],
          encryption_algorithms_server_to_client: [binary()],
          mac_algorithms_client_to_server: [binary()],
          mac_algorithms_server_to_client: [binary()],
          compression_algorithms_client_to_server: [binary()],
          compression_algorithms_server_to_client: [binary()],
          languages_client_to_server: [binary()],
          languages_server_to_client: [binary()],
          first_kex_packet_follows: boolean()
        }

  @spec server_kexinit() :: {binary(), kexinit()}
  def server_kexinit do
    cookie = :crypto.strong_rand_bytes(16)

    payload =
      IO.iodata_to_binary([
        <<20>>,
        cookie,
        Wire.name_list(@kex_algorithms),
        Wire.name_list(@server_host_key_algorithms),
        Wire.name_list(@ciphers),
        Wire.name_list(@ciphers),
        Wire.name_list(@macs),
        Wire.name_list(@macs),
        Wire.name_list(@compression),
        Wire.name_list(@compression),
        Wire.name_list(@languages),
        Wire.name_list(@languages),
        Wire.boolean(false),
        <<0::32>>
      ])

    {:ok, parsed} = decode_kexinit(payload)
    {payload, parsed}
  end

  @spec decode_kexinit(binary()) :: {:ok, kexinit()} | {:error, :bad_message}
  def decode_kexinit(<<20, cookie::binary-size(16), rest::binary>>) do
    with {:ok, kex, rest} <- Wire.take_name_list(rest),
         {:ok, host_keys, rest} <- Wire.take_name_list(rest),
         {:ok, enc_c2s, rest} <- Wire.take_name_list(rest),
         {:ok, enc_s2c, rest} <- Wire.take_name_list(rest),
         {:ok, mac_c2s, rest} <- Wire.take_name_list(rest),
         {:ok, mac_s2c, rest} <- Wire.take_name_list(rest),
         {:ok, comp_c2s, rest} <- Wire.take_name_list(rest),
         {:ok, comp_s2c, rest} <- Wire.take_name_list(rest),
         {:ok, lang_c2s, rest} <- Wire.take_name_list(rest),
         {:ok, lang_s2c, rest} <- Wire.take_name_list(rest),
         {:ok, follows?, <<_reserved::32>>} <- Wire.take_boolean(rest) do
      {:ok,
       %{
         cookie: cookie,
         kex_algorithms: kex,
         server_host_key_algorithms: host_keys,
         encryption_algorithms_client_to_server: enc_c2s,
         encryption_algorithms_server_to_client: enc_s2c,
         mac_algorithms_client_to_server: mac_c2s,
         mac_algorithms_server_to_client: mac_s2c,
         compression_algorithms_client_to_server: comp_c2s,
         compression_algorithms_server_to_client: comp_s2c,
         languages_client_to_server: lang_c2s,
         languages_server_to_client: lang_s2c,
         first_kex_packet_follows: follows?
       }}
    else
      _ -> {:error, :bad_message}
    end
  end

  def decode_kexinit(_), do: {:error, :bad_message}

  @spec negotiate(kexinit(), kexinit()) ::
          {:ok, map()} | {:error, {:no_matching_algorithm, atom()}}
  def negotiate(client, server) do
    with {:ok, kex} <- choose(:kex, client.kex_algorithms, server.kex_algorithms),
         {:ok, host_key} <-
           choose(
             :server_host_key,
             client.server_host_key_algorithms,
             server.server_host_key_algorithms
           ),
         {:ok, cipher_c2s} <-
           choose(
             :cipher_c2s,
             client.encryption_algorithms_client_to_server,
             server.encryption_algorithms_client_to_server
           ),
         {:ok, cipher_s2c} <-
           choose(
             :cipher_s2c,
             client.encryption_algorithms_server_to_client,
             server.encryption_algorithms_server_to_client
           ),
         {:ok, compression_c2s} <-
           choose(
             :compression_c2s,
             client.compression_algorithms_client_to_server,
             server.compression_algorithms_client_to_server
           ),
         {:ok, compression_s2c} <-
           choose(
             :compression_s2c,
             client.compression_algorithms_server_to_client,
             server.compression_algorithms_server_to_client
           ) do
      {:ok,
       %{
         kex: kex,
         server_host_key: host_key,
         cipher_c2s: cipher_c2s,
         cipher_s2c: cipher_s2c,
         mac_c2s: "none",
         mac_s2c: "none",
         compression_c2s: compression_c2s,
         compression_s2c: compression_s2c
       }}
    end
  end

  defp choose(kind, client, server) do
    case Enum.find(client, &(&1 in server)) do
      nil -> {:error, {:no_matching_algorithm, kind}}
      algorithm -> {:ok, algorithm}
    end
  end
end
