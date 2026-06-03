defmodule Sftpd.ElixirServer do
  @moduledoc false

  use GenServer

  require Logger

  alias Sftpd.SFTP
  alias Sftpd.SSH.{Algorithms, Cipher, Kex, Keys, Packet, Wire}

  @banner "SSH-2.0-sftpd-elixir\r\n"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    backend = Keyword.fetch!(opts, :backend)
    backend_state = Keyword.fetch!(opts, :backend_state)
    system_dir = Keyword.fetch!(opts, :system_dir)

    with :ok <- validate_backend(backend),
         {:ok, host_key} <- Keys.load_host_key(system_dir),
         {:ok, socket} <-
           :gen_tcp.listen(port, [
             :binary,
             packet: :raw,
             active: false,
             reuseaddr: true,
             nodelay: true
           ]) do
      state = %{
        socket: socket,
        backend: backend,
        backend_state: backend_state,
        host_key: host_key,
        auth: Keyword.fetch!(opts, :auth),
        acceptor: nil
      }

      {:ok, state, {:continue, :accept}}
    end
  end

  @impl true
  def handle_continue(:accept, state) do
    {:noreply, %{state | acceptor: start_acceptor(state)}}
  end

  @impl true
  def handle_info({:accepted, acceptor, client}, %{acceptor: acceptor} = state) do
    start_connection(client, state)
    {:noreply, %{state | acceptor: start_acceptor(state)}}
  end

  def handle_info({:accept_failed, acceptor, _reason}, %{acceptor: acceptor} = state) do
    {:noreply, %{state | acceptor: start_acceptor(state)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end

  defp validate_backend(Sftpd.Backends.Memory), do: :ok
  defp validate_backend(backend), do: {:error, {:unsupported_elixir_transport_backend, backend}}

  defp start_acceptor(%{socket: socket}) do
    owner = self()

    spawn_link(fn ->
      case :gen_tcp.accept(socket) do
        {:ok, client} ->
          :ok = :gen_tcp.controlling_process(client, owner)
          send(owner, {:accepted, self(), client})

        {:error, reason} ->
          send(owner, {:accept_failed, self(), reason})
      end
    end)
  end

  defp start_connection(socket, state) do
    connection_state = %{
      backend: state.backend,
      backend_state: state.backend_state,
      host_key: state.host_key,
      auth: state.auth
    }

    pid =
      spawn(fn ->
        receive do
          {:serve, socket, connection_state} -> serve_connection(socket, connection_state)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, {:serve, socket, connection_state})
  end

  defp serve_connection(socket, state) do
    with :ok <- :gen_tcp.send(socket, @banner),
         {:ok, client_version} <- recv_identification(socket),
         true <- String.starts_with?(client_version, "SSH-") do
      {kexinit, _parsed} = Algorithms.server_kexinit()
      _ = :gen_tcp.send(socket, Packet.encode_clear(kexinit))

      _ =
        with {:ok, transport} <-
               handle_kex(socket, state, client_version, trim_banner(@banner), kexinit) do
          serve_encrypted(socket, Map.merge(state, transport))
        end
    end

    :gen_tcp.close(socket)
  end

  defp handle_kex(socket, state, client_version, server_version, server_kexinit) do
    with {:ok, client_kexinit, buffer} <- recv_clear_packet(socket, ""),
         {:ok, client_algorithms} <- Algorithms.decode_kexinit(client_kexinit),
         {:ok, server_algorithms} <- Algorithms.decode_kexinit(server_kexinit),
         {:ok, negotiated} <- Algorithms.negotiate(client_algorithms, server_algorithms),
         {:ok, <<30, rest::binary>>, buffer} <- recv_clear_packet(socket, buffer),
         {:ok, client_public, ""} <- Wire.take_string(rest) do
      {server_public, server_private} = Kex.generate_keypair()
      shared_secret = Kex.shared_secret(client_public, server_private)

      exchange_hash =
        Kex.exchange_hash(%{
          client_version: client_version,
          server_version: server_version,
          client_kexinit: client_kexinit,
          server_kexinit: server_kexinit,
          host_key_blob: state.host_key.blob,
          client_public: client_public,
          server_public: server_public,
          shared_secret: shared_secret
        })

      :ok =
        :gen_tcp.send(
          socket,
          Packet.encode_clear(Kex.ecdh_reply(state.host_key, server_public, exchange_hash))
        )

      :ok = :gen_tcp.send(socket, Packet.encode_clear(<<21>>))

      {:ok,
       %{
         negotiated: negotiated,
         exchange_hash: exchange_hash,
         session_id: exchange_hash,
         buffer: buffer,
         c2s_cipher:
           Cipher.new(
             negotiated.cipher_c2s,
             :client_to_server,
             shared_secret,
             exchange_hash,
             exchange_hash
           ),
         s2c_cipher:
           Cipher.new(
             negotiated.cipher_s2c,
             :server_to_client,
             shared_secret,
             exchange_hash,
             exchange_hash
           )
       }}
    end
  end

  defp serve_encrypted(socket, state) do
    with {:ok, <<21>>, state} <- recv_clear_transport_packet(socket, state) do
      state
      |> Map.put(:auth_session, nil)
      |> Map.put(:channels, %{})
      |> Map.put(:next_channel_id, 0)
      |> encrypted_loop(socket)
    end
  end

  defp encrypted_loop(state, socket) do
    case recv_encrypted_payload(socket, state) do
      {:ok, payload, state} ->
        case handle_encrypted_payload(payload, state, socket) do
          {:continue, state} -> encrypted_loop(state, socket)
          {:stop, state} -> state
        end

      {:error, _reason} ->
        state
    end
  end

  defp handle_encrypted_payload(<<5, rest::binary>>, state, socket) do
    Logger.debug("elixir ssh received service request")

    with {:ok, "ssh-userauth", ""} <- Wire.take_string(rest),
         {:ok, state} <-
           send_encrypted_payload(socket, state, [<<6>>, Wire.string("ssh-userauth")]) do
      {:continue, state}
    else
      _ -> {:stop, state}
    end
  end

  defp handle_encrypted_payload(<<50, rest::binary>>, state, socket) do
    Logger.debug("elixir ssh received userauth request")

    with {:ok, username, rest} <- Wire.take_string(rest),
         {:ok, "ssh-connection", rest} <- Wire.take_string(rest),
         {:ok, "password", rest} <- Wire.take_string(rest),
         {:ok, false, rest} <- Wire.take_boolean(rest),
         {:ok, password, ""} <- Wire.take_string(rest),
         {:ok, session} <- authenticate_password(state.auth, username, password, socket),
         {:ok, state} <- send_encrypted_payload(socket, state, <<52>>) do
      {:continue, %{state | auth_session: session}}
    else
      _ ->
        handle_public_key_userauth(rest, state, socket)
    end
  end

  defp handle_encrypted_payload(
         <<90, rest::binary>>,
         %{auth_session: auth_session} = state,
         socket
       )
       when is_map(auth_session) do
    Logger.debug("elixir ssh received channel open")

    with {:ok, "session", rest} <- Wire.take_string(rest),
         <<client_channel::32, client_window::32, client_max_packet::32, ""::binary>> <- rest do
      server_channel = state.next_channel_id

      sftp_session =
        SFTP.Session.new(state.backend, state.backend_state, auth_session)

      channel = %{
        client_channel: client_channel,
        server_channel: server_channel,
        client_window: client_window,
        client_max_packet: client_max_packet,
        sftp?: false,
        sftp_session: sftp_session,
        sftp_buffer: ""
      }

      state = %{
        state
        | channels: Map.put(state.channels, server_channel, channel),
          next_channel_id: server_channel + 1
      }

      payload = [
        <<91, client_channel::32, server_channel::32, 2_097_152::32, 262_144::32>>
      ]

      {:ok, state} = send_encrypted_payload(socket, state, payload)
      {:continue, state}
    else
      _ -> {:stop, state}
    end
  end

  defp handle_encrypted_payload(<<98, recipient::32, rest::binary>>, state, socket) do
    Logger.debug("elixir ssh received channel request")

    with {:ok, "subsystem", rest} <- Wire.take_string(rest),
         {:ok, want_reply?, rest} <- Wire.take_boolean(rest),
         {:ok, "sftp", ""} <- Wire.take_string(rest),
         {:ok, channel} <- fetch_channel(state, recipient) do
      state = put_channel(state, %{channel | sftp?: true})

      state =
        if want_reply? do
          {:ok, state} = send_encrypted_payload(socket, state, <<99, channel.client_channel::32>>)
          state
        else
          state
        end

      {:continue, state}
    else
      _ ->
        state =
          case {Map.get(state.channels, recipient), parse_want_reply(rest)} do
            {%{client_channel: client_channel}, true} ->
              {:ok, state} = send_encrypted_payload(socket, state, <<100, client_channel::32>>)
              state

            _ ->
              state
          end

        {:continue, state}
    end
  end

  defp handle_encrypted_payload(<<94, recipient::32, rest::binary>>, state, socket) do
    Logger.debug("elixir ssh received channel data")

    with {:ok, data, ""} <- Wire.take_string(rest),
         {:ok, %{sftp?: true} = channel} <- fetch_channel(state, recipient) do
      {responses, channel} = handle_sftp_data(data, channel)
      state = put_channel(state, channel)

      {:ok, state} =
        send_encrypted_payload(
          socket,
          state,
          <<93, channel.client_channel::32, byte_size(data)::32>>
        )

      state =
        Enum.reduce(responses, state, fn response, state ->
          send_channel_data(socket, state, channel, response)
        end)

      {:continue, state}
    else
      _ -> {:continue, state}
    end
  end

  defp handle_encrypted_payload(<<96, recipient::32, _rest::binary>>, state, socket) do
    with {:ok, channel} <- fetch_channel(state, recipient),
         {:ok, state} <- send_encrypted_payload(socket, state, <<97, channel.client_channel::32>>) do
      {:continue, %{state | channels: Map.delete(state.channels, recipient)}}
    else
      _ -> {:stop, state}
    end
  end

  defp handle_encrypted_payload(<<97, _recipient::32, _rest::binary>>, state, _socket) do
    {:stop, state}
  end

  defp handle_encrypted_payload(payload, state, _socket) do
    Logger.debug("elixir ssh ignored encrypted message #{inspect(Packet.message_id(payload))}")
    {:continue, state}
  end

  defp handle_public_key_userauth(rest, state, socket) do
    with {:ok, username, rest} <- Wire.take_string(rest),
         {:ok, "ssh-connection", rest} <- Wire.take_string(rest),
         {:ok, "publickey", rest} <- Wire.take_string(rest),
         {:ok, signed?, rest} <- Wire.take_boolean(rest),
         {:ok, "ssh-ed25519" = algorithm, rest} <- Wire.take_string(rest),
         {:ok, key_blob, rest} <- Wire.take_string(rest),
         {:ok, public_key} <- decode_public_key(key_blob),
         {:ok, session} <-
           Sftpd.Auth.Adapter.authorize_public_key(state.auth, username, public_key) do
      if signed? do
        verify_public_key_userauth(rest, state, socket, session, username, algorithm, key_blob)
      else
        {:ok, state} =
          send_encrypted_payload(socket, state, [
            <<60>>,
            Wire.string(algorithm),
            Wire.string(key_blob)
          ])

        {:continue, state}
      end
    else
      _ -> userauth_failure(state, socket)
    end
  end

  defp verify_public_key_userauth(
         rest,
         state,
         socket,
         session,
         username,
         algorithm,
         key_blob
       ) do
    signed_payload = [
      Wire.string(state.session_id),
      <<50>>,
      Wire.string(username),
      Wire.string("ssh-connection"),
      Wire.string("publickey"),
      Wire.boolean(true),
      Wire.string(algorithm),
      Wire.string(key_blob)
    ]

    with {:ok, signature_blob, ""} <- Wire.take_string(rest),
         {:ok, ^algorithm, signature_rest} <- Wire.take_string(signature_blob),
         {:ok, signature, ""} <- Wire.take_string(signature_rest),
         true <-
           verify_ed25519_signature(key_blob, IO.iodata_to_binary(signed_payload), signature),
         {:ok, state} <- send_encrypted_payload(socket, state, <<52>>) do
      {:continue, %{state | auth_session: session}}
    else
      _ -> userauth_failure(state, socket)
    end
  end

  defp userauth_failure(state, socket) do
    {:ok, state} =
      send_encrypted_payload(socket, state, [
        <<51>>,
        Wire.name_list(["publickey", "password"]),
        Wire.boolean(false)
      ])

    {:continue, state}
  end

  defp recv_identification(socket), do: recv_identification(socket, "")

  defp recv_identification(socket, acc) when byte_size(acc) <= 255 do
    case :gen_tcp.recv(socket, 1, 5_000) do
      {:ok, "\n"} -> {:ok, String.trim_trailing(acc, "\r")}
      {:ok, byte} -> recv_identification(socket, acc <> byte)
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_identification(_socket, _acc), do: {:error, :identification_too_long}

  defp trim_banner(banner), do: banner |> String.trim_trailing("\n") |> String.trim_trailing("\r")

  defp recv_clear_packet(socket, buffer) do
    case Packet.decode_clear(buffer) do
      {:ok, payload, rest} ->
        {:ok, payload, rest}

      :more ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> recv_clear_packet(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.debug("elixir ssh decrypt failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp recv_clear_transport_packet(socket, state) do
    case recv_clear_packet(socket, Map.get(state, :buffer, "")) do
      {:ok, payload, rest} -> {:ok, payload, Map.put(state, :buffer, rest)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_encrypted_payload(socket, %{buffer: buffer, c2s_cipher: cipher} = state) do
    case Cipher.decrypt_packet(cipher, buffer || "") do
      {:ok, clear_packet, rest, cipher} ->
        case Packet.decode_clear(clear_packet) do
          {:ok, payload, ""} -> {:ok, payload, %{state | buffer: rest, c2s_cipher: cipher}}
          _ -> {:error, :bad_packet}
        end

      :more ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> recv_encrypted_payload(socket, %{state | buffer: (buffer || "") <> data})
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_encrypted_payload(socket, %{s2c_cipher: cipher} = state, payload) do
    {encrypted, cipher} =
      Cipher.encrypt_packet(cipher, Packet.encode_aead(payload, Cipher.block_size(cipher)))

    case :gen_tcp.send(socket, encrypted) do
      :ok -> {:ok, %{state | s2c_cipher: cipher}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_channel_data(socket, state, channel, data) do
    max_packet = max(1, channel.client_max_packet)
    send_channel_data(socket, state, channel.client_channel, data, max_packet)
  end

  defp send_channel_data(_socket, state, _client_channel, "", _max_packet), do: state

  defp send_channel_data(socket, state, client_channel, data, max_packet) do
    bytes = min(byte_size(data), max_packet)
    <<chunk::binary-size(^bytes), rest::binary>> = data
    payload = [<<94, client_channel::32>>, Wire.string(chunk)]
    {:ok, state} = send_encrypted_payload(socket, state, payload)
    send_channel_data(socket, state, client_channel, rest, max_packet)
  end

  defp authenticate_password(auth, username, password, socket) do
    peer =
      case :inet.peername(socket) do
        {:ok, peer} -> peer
        {:error, _reason} -> nil
      end

    case Sftpd.Auth.Adapter.authenticate_password(auth, username, password, peer) do
      {:ok, session} when is_map(session) -> {:ok, session}
      _ -> :error
    end
  end

  defp decode_public_key(key_blob) do
    {:ok, :ssh_message.ssh2_pubkey_decode(key_blob)}
  rescue
    _ -> {:error, :invalid_public_key}
  end

  defp verify_ed25519_signature(key_blob, data, signature) do
    with {:ok, "ssh-ed25519", rest} <- Wire.take_string(key_blob),
         {:ok, public_key, ""} <- Wire.take_string(rest) do
      key = {{:ECPoint, public_key}, {:namedCurve, {1, 3, 101, 112}}}
      :public_key.verify(data, :none, signature, key)
    else
      _ -> false
    end
  end

  defp fetch_channel(state, server_channel) do
    case Map.fetch(state.channels, server_channel) do
      {:ok, channel} -> {:ok, channel}
      :error -> :error
    end
  end

  defp put_channel(state, %{server_channel: server_channel} = channel) do
    %{state | channels: Map.put(state.channels, server_channel, channel)}
  end

  defp handle_sftp_data(data, channel) do
    buffer = channel.sftp_buffer <> data
    {packets, rest} = SFTP.Codec.split_packets(buffer)

    {responses, sftp_session} =
      Enum.map_reduce(packets, channel.sftp_session, fn packet, session ->
        {response, session} = SFTP.Session.handle_packet(packet, session)
        {IO.iodata_to_binary(response), session}
      end)

    {responses, %{channel | sftp_buffer: rest, sftp_session: sftp_session}}
  end

  defp parse_want_reply(rest) do
    with {:ok, _request, rest} <- Wire.take_string(rest),
         {:ok, want_reply?, _rest} <- Wire.take_boolean(rest) do
      want_reply?
    else
      _ -> false
    end
  end
end
