defmodule Sftpd.SSH.Server do
  @moduledoc false

  use GenServer

  require Logger

  alias Sftpd.SFTP
  alias Sftpd.SSH.{Algorithms, Cipher, Kex, Keys, Packet, SFTPBridge, Wire}

  @banner "SSH-2.0-sftpd-elixir\r\n"
  @handshake_timeout 30_000
  @encrypted_idle_timeout :infinity
  @max_auth_failures 6
  @default_max_channels 4
  @default_max_handles 256
  @channel_window_size 64 * 1024 * 1024
  @channel_max_packet_size 1_048_576
  @aead_tag_size 16
  @max_encrypted_packet_length 2 * 1024 * 1024
  @max_sftp_packet_length @channel_window_size
  @window_adjust_batch_size @channel_max_packet_size

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start(__MODULE__, opts)
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
        max_sessions: Keyword.fetch!(opts, :max_sessions),
        max_channels: positive_integer_option(opts, :max_channels, @default_max_channels),
        max_handles: positive_integer_option(opts, :max_handles, @default_max_handles),
        acceptor: nil,
        connections: %{}
      }

      {:ok, state, {:continue, :accept}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:accept, state) do
    {:noreply, %{state | acceptor: start_acceptor(state)}}
  end

  @impl true
  def handle_info({:accepted, acceptor, client}, %{acceptor: acceptor} = state) do
    state =
      if map_size(state.connections) >= state.max_sessions do
        :gen_tcp.close(client)
        state
      else
        pid = start_connection(client, state)
        ref = Process.monitor(pid)
        %{state | connections: Map.put(state.connections, ref, {pid, client})}
      end

    {:noreply, %{state | acceptor: start_acceptor(state)}}
  end

  def handle_info({:accept_failed, acceptor, _reason}, %{acceptor: acceptor} = state) do
    {:noreply, %{state | acceptor: start_acceptor(state)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | connections: Map.delete(state.connections, ref)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket, connections: connections}) do
    :gen_tcp.close(socket)
    Enum.each(connections, fn {_ref, {_pid, socket}} -> :gen_tcp.close(socket) end)
    :ok
  end

  defp validate_backend(backend) when is_atom(backend) do
    callbacks = [
      init: 1,
      open_read: 3,
      read_at: 4,
      open_write: 4,
      write_at: 4,
      finish_write: 2,
      abort_write: 2,
      open_dir: 3,
      read_dir: 2,
      close_dir: 2,
      file_attrs: 3,
      make_dir: 4,
      del_dir: 3,
      delete: 3,
      rename: 4
    ]

    with {:module, ^backend} <- Code.ensure_loaded(backend),
         true <-
           Enum.all?(callbacks, fn {function, arity} ->
             function_exported?(backend, function, arity)
           end) do
      :ok
    else
      _ -> {:error, {:unsupported_backend, backend}}
    end
  end

  defp validate_backend(backend), do: {:error, {:unsupported_backend, backend}}

  defp positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

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
      auth: state.auth,
      max_channels: state.max_channels,
      max_handles: state.max_handles
    }

    pid =
      spawn(fn ->
        receive do
          {:serve, socket, connection_state} -> serve_connection(socket, connection_state)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    notify_profile_owner(pid)
    send(pid, {:serve, socket, connection_state})
    pid
  end

  defp notify_profile_owner(pid) do
    case Process.whereis(:sftpd_profile_owner) do
      nil -> :ok
      owner -> send(owner, {:sftpd_connection, pid})
    end
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
         {:ok, buffer} <-
           maybe_skip_wrong_kex_guess(socket, buffer, client_algorithms, negotiated),
         {:ok, <<30, rest::binary>>, buffer} <- recv_clear_packet(socket, buffer),
         {:ok, client_public, ""} <- Wire.take_string(rest),
         :ok <- validate_curve25519_public_key(client_public),
         {:ok, server_public, shared_secret} <- curve25519_shared_secret(client_public) do
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
         client_version: client_version,
         server_version: server_version,
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

  defp maybe_skip_wrong_kex_guess(
         socket,
         buffer,
         %{first_kex_packet_follows: true} = client_algorithms,
         negotiated
       ) do
    if kex_guess_matches?(client_algorithms, negotiated) do
      {:ok, buffer}
    else
      case recv_clear_packet(socket, buffer) do
        {:ok, _ignored_payload, buffer} -> {:ok, buffer}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_skip_wrong_kex_guess(_socket, buffer, _client_algorithms, _negotiated),
    do: {:ok, buffer}

  defp handle_rekey(socket, client_kexinit, state) do
    {server_kexinit, _parsed} = Algorithms.server_kexinit()

    with {:ok, client_algorithms} <- Algorithms.decode_kexinit(client_kexinit),
         {:ok, server_algorithms} <- Algorithms.decode_kexinit(server_kexinit),
         {:ok, negotiated} <- Algorithms.negotiate(client_algorithms, server_algorithms),
         {:ok, state} <- send_encrypted_payload(socket, state, server_kexinit),
         {:ok, state} <-
           maybe_skip_wrong_encrypted_kex_guess(socket, state, client_algorithms, negotiated),
         {:ok, <<30, rest::binary>>, state} <- recv_encrypted_payload(socket, state),
         {:ok, client_public, ""} <- Wire.take_string(rest),
         :ok <- validate_curve25519_public_key(client_public),
         {:ok, server_public, shared_secret} <- curve25519_shared_secret(client_public) do
      exchange_hash =
        Kex.exchange_hash(%{
          client_version: state.client_version,
          server_version: state.server_version,
          client_kexinit: client_kexinit,
          server_kexinit: server_kexinit,
          host_key_blob: state.host_key.blob,
          client_public: client_public,
          server_public: server_public,
          shared_secret: shared_secret
        })

      reply = Kex.ecdh_reply(state.host_key, server_public, exchange_hash)

      with {:ok, state} <- send_encrypted_payload(socket, state, reply),
           {:ok, state} <- send_encrypted_payload(socket, state, <<21>>),
           state <- install_rekey_s2c(state, negotiated, shared_secret, exchange_hash),
           {:ok, <<21>>, state} <- recv_encrypted_payload(socket, state) do
        {:ok, install_rekey_c2s(state, negotiated, shared_secret, exchange_hash)}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :bad_message}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :bad_message}
    end
  end

  defp maybe_skip_wrong_encrypted_kex_guess(
         socket,
         state,
         %{first_kex_packet_follows: true} = client_algorithms,
         negotiated
       ) do
    if kex_guess_matches?(client_algorithms, negotiated) do
      {:ok, state}
    else
      case recv_encrypted_payload(socket, state) do
        {:ok, _ignored_payload, state} -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_skip_wrong_encrypted_kex_guess(_socket, state, _client_algorithms, _negotiated),
    do: {:ok, state}

  defp install_rekey_s2c(state, negotiated, shared_secret, exchange_hash) do
    %{
      state
      | negotiated: negotiated,
        exchange_hash: exchange_hash,
        s2c_cipher:
          Cipher.new(
            negotiated.cipher_s2c,
            :server_to_client,
            shared_secret,
            exchange_hash,
            state.session_id
          )
    }
  end

  defp install_rekey_c2s(state, negotiated, shared_secret, exchange_hash) do
    %{
      state
      | negotiated: negotiated,
        exchange_hash: exchange_hash,
        c2s_cipher:
          Cipher.new(
            negotiated.cipher_c2s,
            :client_to_server,
            shared_secret,
            exchange_hash,
            state.session_id
          )
    }
  end

  defp kex_guess_matches?(client_algorithms, negotiated) do
    first(client_algorithms.kex_algorithms) == negotiated.kex and
      first(client_algorithms.server_host_key_algorithms) == negotiated.server_host_key and
      first(client_algorithms.encryption_algorithms_client_to_server) == negotiated.cipher_c2s and
      first(client_algorithms.encryption_algorithms_server_to_client) == negotiated.cipher_s2c and
      first(client_algorithms.compression_algorithms_client_to_server) ==
        negotiated.compression_c2s and
      first(client_algorithms.compression_algorithms_server_to_client) ==
        negotiated.compression_s2c
  end

  defp first([value | _rest]), do: value
  defp first([]), do: nil

  defp validate_curve25519_public_key(public_key) when byte_size(public_key) == 32, do: :ok
  defp validate_curve25519_public_key(_public_key), do: {:error, :bad_message}

  defp curve25519_shared_secret(client_public) do
    {server_public, server_private} = Kex.generate_keypair()

    with {:ok, shared_secret} <- Kex.shared_secret(client_public, server_private) do
      {:ok, server_public, shared_secret}
    end
  end

  defp serve_encrypted(socket, state) do
    with {:ok, <<21>>, state} <- recv_clear_transport_packet(socket, state) do
      state
      |> Map.put(:auth_session, nil)
      |> Map.put(:auth_failures, 0)
      |> Map.put(:channels, %{})
      |> Map.put(:active_channel_id, nil)
      |> Map.put(:active_channel, nil)
      |> Map.put(:next_channel_id, 0)
      |> encrypted_loop(socket)
    end
  end

  defp encrypted_loop(state, socket) do
    case recv_encrypted_payload(socket, state) do
      {:ok, <<94, recipient::32, rest::binary>>,
       %{
         active_channel_id: active_channel_id,
         active_channel: %{sftp?: true} = channel
       } = state}
      when active_channel_id == recipient ->
        Logger.debug("pure ssh received channel data")

        result =
          with <<data_len::32, data::binary-size(data_len)>> <- rest do
            {responses, channel} = handle_sftp_data(data, channel)

            drain_result =
              drain_buffered_sftp_data(
                socket,
                recipient,
                state,
                channel,
                Enum.reverse(responses),
                byte_size(data)
              )

            finish_channel_data_drain(socket, drain_result)
          else
            _ -> {:continue, state}
          end

        case result do
          {:continue, state} -> encrypted_loop(state, socket)
          {:stop, state} -> cleanup_open_handles(state)
        end

      {:ok, <<93, recipient::32, bytes::32>>,
       %{active_channel_id: active_channel_id, active_channel: channel} = state}
      when active_channel_id == recipient and not is_nil(channel) ->
        channel = %{channel | client_window: channel.client_window + bytes}

        result =
          if channel.pending_responses == [] do
            state = cache_channel(state, channel)
            {:continue, state}
          else
            drain_result = drain_buffered_sftp_data(socket, recipient, state, channel, [], 0)
            finish_channel_data_drain(socket, drain_result)
          end

        case result do
          {:continue, state} -> encrypted_loop(state, socket)
          {:stop, state} -> cleanup_open_handles(state)
        end

      {:ok, payload, state} ->
        case handle_encrypted_payload(payload, state, socket) do
          {:continue, state} -> encrypted_loop(state, socket)
          {:stop, state} -> cleanup_open_handles(state)
        end

      {:error, reason} ->
        Logger.debug("pure ssh encrypted receive failed: #{inspect(reason)}")
        cleanup_open_handles(state)
    end
  end

  defp handle_encrypted_payload(<<5, rest::binary>>, state, socket) do
    Logger.debug("pure ssh received service request")

    with {:ok, "ssh-userauth", ""} <- Wire.take_string(rest),
         {:ok, state} <-
           send_encrypted_payload(socket, state, [<<6>>, Wire.string("ssh-userauth")]) do
      {:continue, state}
    else
      _ -> {:stop, state}
    end
  end

  defp handle_encrypted_payload(<<80, rest::binary>>, state, socket) do
    case global_request_reply(rest) do
      {:reply, payload} ->
        case send_encrypted_payload(socket, state, payload) do
          {:ok, state} -> {:continue, state}
          {:error, _reason} -> {:stop, state}
        end

      :noreply ->
        {:continue, state}
    end
  end

  defp handle_encrypted_payload(<<1, code::32, rest::binary>>, state, _socket) do
    {description, language} =
      with {:ok, description, rest} <- Wire.take_string(rest),
           {:ok, language, ""} <- Wire.take_string(rest) do
        {description, language}
      else
        _ -> {"", ""}
      end

    Logger.debug(
      "pure ssh received disconnect code=#{code} description=#{inspect(description)} language=#{inspect(language)}"
    )

    {:stop, state}
  end

  defp handle_encrypted_payload(<<20, _rest::binary>> = client_kexinit, state, socket) do
    Logger.debug("pure ssh received encrypted rekey request")

    case handle_rekey(socket, client_kexinit, state) do
      {:ok, state} ->
        {:continue, state}

      {:error, reason} ->
        Logger.debug("pure ssh rekey failed: #{inspect(reason)}")
        {:stop, state}
    end
  end

  defp handle_encrypted_payload(<<50, rest::binary>>, state, socket) do
    Logger.debug("pure ssh received userauth request")
    userauth_payload = rest

    with {:ok, username, rest} <- Wire.take_string(rest),
         {:ok, "ssh-connection", rest} <- Wire.take_string(rest),
         {:ok, "password", rest} <- Wire.take_string(rest),
         {:ok, false, rest} <- Wire.take_boolean(rest),
         {:ok, password, ""} <- Wire.take_string(rest),
         {:ok, session} <- authenticate_password(state.auth, username, password, socket),
         {:ok, state} <- send_encrypted_payload(socket, state, <<52>>) do
      {:continue, %{state | auth_session: session, auth_failures: 0}}
    else
      :disconnect ->
        {:stop, state}

      _ ->
        handle_public_key_userauth(userauth_payload, state, socket)
    end
  end

  defp handle_encrypted_payload(
         <<90, rest::binary>>,
         %{auth_session: auth_session} = state,
         socket
       )
       when is_map(auth_session) do
    Logger.debug("pure ssh received channel open")

    with false <- max_channels_reached?(state),
         {:ok, "session", rest} <- Wire.take_string(rest),
         <<client_channel::32, client_window::32, client_max_packet::32, ""::binary>> <- rest do
      server_channel = state.next_channel_id

      sftp_session =
        SFTP.Session.new(state.backend, state.backend_state, auth_session,
          max_handles: state.max_handles
        )

      channel = %{
        client_channel: client_channel,
        server_channel: server_channel,
        client_window: client_window,
        client_max_packet: client_max_packet,
        recv_window_adjust: 0,
        sftp?: false,
        sftp_session: sftp_session,
        sftp_buffer: "",
        eof_received?: false,
        pending_responses: []
      }

      state = %{
        state
        | channels: Map.put(state.channels, server_channel, channel),
          next_channel_id: server_channel + 1
      }

      payload = [
        <<91, client_channel::32, server_channel::32, @channel_window_size::32,
          @channel_max_packet_size::32>>
      ]

      {:ok, state} = send_encrypted_payload(socket, state, payload)
      {:continue, state}
    else
      true ->
        with {:ok, client_channel} <- parse_channel_open_sender(rest),
             {:ok, state} <-
               send_encrypted_payload(socket, state, [
                 <<92, client_channel::32, 4::32>>,
                 Wire.string("too many open channels"),
                 Wire.string("")
               ]) do
          {:continue, state}
        else
          _ -> {:stop, state}
        end

      _ ->
        {:stop, state}
    end
  end

  defp handle_encrypted_payload(<<98, recipient::32, rest::binary>>, state, socket) do
    Logger.debug("pure ssh received channel request")

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

  defp handle_encrypted_payload(
         <<94, recipient::32, rest::binary>>,
         %{
           active_channel_id: active_channel_id,
           active_channel: %{sftp?: true} = channel
         } = state,
         socket
       )
       when active_channel_id == recipient do
    Logger.debug("pure ssh received channel data")

    with <<data_len::32, data::binary-size(data_len)>> <- rest do
      {responses, channel} = handle_sftp_data(data, channel)

      drain_result =
        drain_buffered_sftp_data(
          socket,
          recipient,
          state,
          channel,
          Enum.reverse(responses),
          byte_size(data)
        )

      finish_channel_data_drain(socket, drain_result)
    else
      _ -> {:continue, state}
    end
  end

  defp handle_encrypted_payload(<<94, recipient::32, rest::binary>>, state, socket) do
    Logger.debug("pure ssh received channel data")

    with <<data_len::32, data::binary-size(data_len)>> <- rest,
         {:ok, %{sftp?: true} = channel} <- fetch_active_channel(state, recipient) do
      {responses, channel} = handle_sftp_data(data, channel)

      drain_result =
        drain_buffered_sftp_data(
          socket,
          recipient,
          state,
          channel,
          Enum.reverse(responses),
          byte_size(data)
        )

      finish_channel_data_drain(socket, drain_result)
    else
      _ -> {:continue, state}
    end
  end

  defp handle_encrypted_payload(
         <<93, recipient::32, bytes::32>>,
         %{active_channel_id: active_channel_id, active_channel: channel} = state,
         socket
       )
       when active_channel_id == recipient and not is_nil(channel) do
    channel = %{channel | client_window: channel.client_window + bytes}

    if channel.pending_responses == [] do
      state = cache_channel(state, channel)
      {:continue, state}
    else
      case flush_sftp_responses_with_channel(socket, state, channel, 0) do
        {:ok, state, _channel} -> {:continue, state}
        {:closed, state} -> {:continue, state}
        {:error, _reason, state} -> {:stop, state}
      end
    end
  end

  defp handle_encrypted_payload(<<93, recipient::32, bytes::32>>, state, socket) do
    with {:ok, channel} <- fetch_active_channel(state, recipient) do
      channel = %{channel | client_window: channel.client_window + bytes}

      if channel.pending_responses == [] do
        state = cache_channel(state, channel)
        {:continue, state}
      else
        case flush_sftp_responses_with_channel(socket, state, channel, 0) do
          {:ok, state, _channel} -> {:continue, state}
          {:closed, state} -> {:continue, state}
          {:error, _reason, state} -> {:stop, state}
        end
      end
    else
      _ -> {:continue, state}
    end
  end

  defp handle_encrypted_payload(<<96, recipient::32, _rest::binary>>, state, socket) do
    with {:ok, channel} <- fetch_active_channel(state, recipient),
         {:ok, state, channel} <- flush_sftp_responses_with_channel(socket, state, channel, 0) do
      channel = %{channel | eof_received?: true}

      if channel.pending_responses == [] and sftp_buffer_empty?(channel.sftp_buffer) do
        _ = SFTP.Session.cleanup_open_handles(channel.sftp_session)
        {:ok, state} = send_encrypted_payload(socket, state, <<97, channel.client_channel::32>>)
        {:continue, delete_channel(state, recipient)}
      else
        {:continue, cache_channel(state, channel)}
      end
    else
      :error -> {:continue, state}
      {:error, _reason, state} -> {:stop, state}
      _ -> {:stop, state}
    end
  end

  defp handle_encrypted_payload(<<97, recipient::32, _rest::binary>>, state, socket) do
    with {:ok, channel} <- fetch_active_channel(state, recipient),
         {:ok, state} <- send_encrypted_payload(socket, state, <<97, channel.client_channel::32>>) do
      _ = SFTP.Session.cleanup_open_handles(channel.sftp_session)
      {:continue, delete_channel(state, recipient)}
    else
      _ -> {:continue, state}
    end
  end

  defp handle_encrypted_payload(payload, state, _socket) do
    Logger.debug("pure ssh ignored encrypted message #{inspect(Packet.message_id(payload))}")
    {:continue, state}
  end

  defp global_request_reply(rest) do
    with {:ok, _request_name, rest} <- Wire.take_string(rest),
         {:ok, want_reply?, _rest} <- Wire.take_boolean(rest) do
      if want_reply?, do: {:reply, <<82>>}, else: :noreply
    else
      _ -> :noreply
    end
  end

  defp drain_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read) do
    if SFTPBridge.responses_near_window?(channel, responses) do
      {:open, responses, state, channel, bytes_read}
    else
      drain_more_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read)
    end
  end

  defp drain_more_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read) do
    case recv_buffered_or_available_encrypted_payload(socket, state) do
      {:ok, <<94, ^recipient::32, rest::binary>>, state} ->
        with <<data_len::32, data::binary-size(data_len)>> <- rest do
          {new_responses, channel} = handle_sftp_data(data, channel)
          responses = prepend_reversed(new_responses, responses)

          drain_buffered_sftp_data(
            socket,
            recipient,
            state,
            channel,
            responses,
            bytes_read + byte_size(data)
          )
        else
          _ -> {:open, responses, state, channel, bytes_read}
        end

      {:ok, <<93, ^recipient::32, bytes::32>>, state} ->
        channel = %{channel | client_window: channel.client_window + bytes}
        state = cache_channel(state, channel)
        drain_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read)

      {:ok, payload, state} ->
        case handle_encrypted_payload(payload, state, socket) do
          {:continue, state} ->
            case fetch_channel(state, recipient) do
              {:ok, %{sftp?: true} = channel} ->
                drain_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read)

              _ ->
                {:closed, state}
            end

          {:stop, state} ->
            {:error, state}
        end

      {:none, state} ->
        {:open, responses, state, channel, bytes_read}

      {:error, _reason} ->
        {:error, state}
    end
  end

  defp finish_channel_data_drain(socket, {:open, [], state, channel, bytes_read}) do
    finish_open_channel_data_drain(socket, [], state, channel, bytes_read)
  end

  defp finish_channel_data_drain(socket, {:open, responses_acc, state, channel, bytes_read}) do
    responses = Enum.reverse(responses_acc)
    channel = append_pending_responses(channel, responses)
    finish_open_channel_data_drain(socket, responses, state, channel, bytes_read)
  end

  defp finish_channel_data_drain(_socket, {:closed, state}), do: {:continue, state}
  defp finish_channel_data_drain(_socket, {:error, state}), do: {:stop, state}

  defp finish_open_channel_data_drain(socket, responses, state, channel, bytes_read) do
    channel = %{channel | recv_window_adjust: channel.recv_window_adjust + bytes_read}

    if responses == [] and channel.pending_responses == [] and
         channel.recv_window_adjust < @window_adjust_batch_size do
      state = cache_channel(state, channel)
      {:continue, state}
    else
      case flush_sftp_responses_with_channel(socket, state, channel, 0) do
        {:ok, state, _channel} ->
          {:continue, state}

        {:closed, state} ->
          {:continue, state}

        {:error, reason, state} ->
          Logger.debug("pure ssh failed to flush sftp responses: #{inspect(reason)}")
          {:stop, state}
      end
    end
  end

  defp prepend_reversed([], acc), do: acc
  defp prepend_reversed([response | rest], acc), do: prepend_reversed(rest, [response | acc])

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
      {:continue, %{state | auth_session: session, auth_failures: 0}}
    else
      _ -> userauth_failure(state, socket)
    end
  end

  defp userauth_failure(state, socket) do
    failures = Map.get(state, :auth_failures, 0) + 1
    state = %{state | auth_failures: failures}

    if failures >= @max_auth_failures do
      {:ok, state} =
        send_encrypted_payload(socket, state, [
          <<1, 14::32>>,
          Wire.string("too many authentication failures"),
          Wire.string("")
        ])

      {:stop, state}
    else
      {:ok, state} =
        send_encrypted_payload(socket, state, [
          <<51>>,
          Wire.name_list(["publickey", "password"]),
          Wire.boolean(false)
        ])

      {:continue, state}
    end
  end

  defp recv_identification(socket), do: recv_identification(socket, "")

  defp recv_identification(socket, acc) when byte_size(acc) <= 255 do
    case :gen_tcp.recv(socket, 1, @handshake_timeout) do
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
        case :gen_tcp.recv(socket, 0, @handshake_timeout) do
          {:ok, data} -> recv_clear_packet(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.debug("pure ssh decrypt failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp recv_clear_transport_packet(socket, state) do
    case recv_clear_packet(socket, Map.get(state, :buffer, "")) do
      {:ok, payload, rest} -> {:ok, payload, Map.put(state, :buffer, rest)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_encrypted_payload(socket, %{buffer: buffer, c2s_cipher: cipher} = state)
       when buffer in [nil, ""] do
    case :gen_tcp.recv(socket, 4, @encrypted_idle_timeout) do
      {:ok, <<packet_length::32>>}
      when packet_length > 0 and packet_length <= @max_encrypted_packet_length ->
        with {:ok, encrypted_body} <-
               :gen_tcp.recv(socket, packet_length + @aead_tag_size, @encrypted_idle_timeout) do
          case Cipher.decrypt_packet_payload(cipher, packet_length, encrypted_body) do
            {:ok, payload, cipher} ->
              {:ok, payload, %{state | buffer: "", c2s_cipher: cipher}}

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:ok, <<_packet_length::32>>} ->
        {:error, :invalid_packet_length}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_encrypted_payload(socket, %{buffer: buffer, c2s_cipher: cipher} = state) do
    case recv_encrypted_packet(socket, buffer, @encrypted_idle_timeout) do
      {:ok, packet_length, encrypted_body, rest} ->
        case Cipher.decrypt_packet_payload(cipher, packet_length, encrypted_body) do
          {:ok, payload, cipher} ->
            {:ok, payload, %{state | buffer: rest, c2s_cipher: cipher}}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, buffer} ->
        case Cipher.decrypt_packet_payload(cipher, buffer) do
          {:ok, payload, rest, cipher} ->
            {:ok, payload, %{state | buffer: rest, c2s_cipher: cipher}}

          :more ->
            {:error, :bad_packet}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_buffered_encrypted_payload(%{buffer: buffer, c2s_cipher: cipher} = state)
       when is_binary(buffer) and byte_size(buffer) > 0 do
    case Cipher.decrypt_packet_payload(cipher, buffer) do
      {:ok, payload, rest, cipher} ->
        {:ok, payload, %{state | buffer: rest, c2s_cipher: cipher}}

      :more ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_buffered_encrypted_payload(_state), do: :none

  defp recv_buffered_or_available_encrypted_payload(socket, state) do
    case recv_buffered_encrypted_payload(state) do
      :none -> recv_available_encrypted_payload(socket, state)
      result -> result
    end
  end

  defp recv_available_encrypted_payload(socket, %{buffer: buffer} = state)
       when buffer in [nil, ""] do
    case :gen_tcp.recv(socket, 0, 0) do
      {:ok, data} ->
        state = %{state | buffer: data}

        case recv_buffered_encrypted_payload(state) do
          :none -> {:none, state}
          result -> result
        end

      {:error, :timeout} ->
        {:none, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_available_encrypted_payload(_socket, state), do: {:none, state}

  defp recv_encrypted_packet(socket, "", timeout) do
    case :gen_tcp.recv(socket, 4, timeout) do
      {:ok, <<packet_length::32>>}
      when packet_length > 0 and packet_length <= @max_encrypted_packet_length ->
        with {:ok, encrypted_body} <-
               :gen_tcp.recv(socket, packet_length + @aead_tag_size, timeout) do
          {:ok, packet_length, encrypted_body, ""}
        end

      {:ok, <<_packet_length::32>>} ->
        {:error, :invalid_packet_length}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_encrypted_packet(socket, buffer, timeout) do
    case encrypted_packet_missing_bytes(buffer) do
      0 ->
        {:ok, buffer}

      bytes when is_integer(bytes) ->
        case :gen_tcp.recv(socket, bytes, timeout) do
          {:ok, data} -> recv_encrypted_packet(socket, buffer <> data, timeout)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encrypted_packet_missing_bytes(<<packet_length::32, _rest::binary>> = buffer)
       when packet_length > 0 and packet_length <= @max_encrypted_packet_length do
    max(4 + packet_length + @aead_tag_size - byte_size(buffer), 0)
  end

  defp encrypted_packet_missing_bytes(<<_packet_length::32, _rest::binary>>) do
    {:error, :invalid_packet_length}
  end

  defp encrypted_packet_missing_bytes(buffer), do: 4 - byte_size(buffer)

  defp send_encrypted_payload(socket, %{s2c_cipher: cipher} = state, payload) do
    {encrypted, cipher} =
      Cipher.encrypt_packet(cipher, Packet.encode_aead_packet(payload, Cipher.block_size(cipher)))

    case :gen_tcp.send(socket, encrypted) do
      :ok -> {:ok, %{state | s2c_cipher: cipher}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_encrypted_payloads(socket, state, payloads) do
    %{s2c_cipher: cipher} = state
    {encrypted, cipher} = Cipher.encrypt_payloads(cipher, payloads, Cipher.block_size(cipher))
    state = %{state | s2c_cipher: cipher}

    case :gen_tcp.send(socket, encrypted) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp flush_sftp_responses_with_channel(socket, state, channel, bytes_read) do
    channel = %{channel | recv_window_adjust: channel.recv_window_adjust + bytes_read}
    adjust_sent? = channel.recv_window_adjust >= @window_adjust_batch_size

    {response_payloads, pending, response_bytes} =
      SFTPBridge.payloads_for_window(channel, channel.pending_responses)

    channel = %{
      channel
      | pending_responses: pending,
        client_window: channel.client_window - response_bytes
    }

    payloads =
      if adjust_sent? do
        [<<93, channel.client_channel::32, channel.recv_window_adjust::32>> | response_payloads]
      else
        response_payloads
      end

    channel =
      if adjust_sent? do
        %{channel | recv_window_adjust: 0}
      else
        channel
      end

    state =
      if state.active_channel_id in [nil, channel.server_channel] do
        %{state | active_channel_id: channel.server_channel, active_channel: channel}
      else
        cache_channel(state, channel)
      end

    case payloads do
      [] ->
        if channel.eof_received? do
          case maybe_close_eof_channel(socket, state, channel) do
            {:ok, state} -> {:ok, state, channel}
            {:closed, state} -> {:closed, state}
            {:error, reason, state} -> {:error, reason, state}
          end
        else
          {:ok, state, channel}
        end

      payloads ->
        case send_encrypted_payloads(socket, state, payloads) do
          {:ok, state} ->
            if channel.eof_received? do
              case maybe_close_eof_channel(socket, state, channel) do
                {:ok, state} -> {:ok, state, channel}
                {:closed, state} -> {:closed, state}
                {:error, reason, state} -> {:error, reason, state}
              end
            else
              {:ok, state, channel}
            end

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  defp maybe_close_eof_channel(
         socket,
         state,
         %{eof_received?: true, pending_responses: [], sftp_buffer: sftp_buffer} = channel
       ) do
    if sftp_buffer_empty?(sftp_buffer) do
      _ = SFTP.Session.cleanup_open_handles(channel.sftp_session)

      case send_encrypted_payload(socket, state, <<97, channel.client_channel::32>>) do
        {:ok, state} ->
          {:closed, delete_channel(state, channel.server_channel)}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:ok, state}
    end
  end

  defp maybe_close_eof_channel(_socket, state, _channel), do: {:ok, state}

  defp append_pending_responses(channel, []), do: channel

  defp append_pending_responses(%{pending_responses: []} = channel, responses) do
    %{channel | pending_responses: responses}
  end

  defp append_pending_responses(channel, responses) do
    %{channel | pending_responses: channel.pending_responses ++ responses}
  end

  if function_exported?(Mix, :env, 0) and Mix.env() == :test do
    @doc false
    def __test_sftp_response_payloads__(channel, responses) do
      SFTPBridge.response_payloads(channel, responses)
    end

    @doc false
    def __test_split_responses_for_window__(responses, window) do
      SFTPBridge.split_responses_for_window(responses, window)
    end

    @doc false
    def __test_validate_backend__(backend) do
      validate_backend(backend)
    end

    @doc false
    def __test_global_request_reply__(payload) do
      global_request_reply(payload)
    end

    @doc false
    def __test_cleanup_open_handles__(state) do
      cleanup_open_handles(state)
    end

    @doc false
    def __test_window_adjust_payloads__(client_channel, recv_window_adjust) do
      adjust_sent? = recv_window_adjust >= @window_adjust_batch_size

      if adjust_sent? do
        [<<93, client_channel::32, recv_window_adjust::32>>]
      else
        []
      end
    end

    @doc false
    def __test_sftp_flush_payloads__(channel, ready, adjust_sent?) do
      response_payloads = SFTPBridge.response_payloads(channel, ready)

      if adjust_sent? do
        [<<93, channel.client_channel::32, channel.recv_window_adjust::32>> | response_payloads]
      else
        response_payloads
      end
    end

    @doc false
    def __test_split_sftp_packets__(buffer, data), do: split_sftp_packets(buffer, data)

    @doc false
    def __test_finish_channel_data_drain__(drain_result) do
      finish_channel_data_drain(nil, drain_result)
    end

    @doc false
    def __test_append_pending_responses__(channel, responses) do
      append_pending_responses(channel, responses)
    end

    @doc false
    def __test_recv_buffered_or_available_encrypted_payload__(socket, state) do
      recv_buffered_or_available_encrypted_payload(socket, state)
    end

    @doc false
    def __test_drain_buffered_sftp_data__(
          socket,
          recipient,
          state,
          channel,
          responses,
          bytes_read
        ) do
      drain_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read)
    end

    @doc false
    def __test_put_channel__(state, channel), do: put_channel(state, channel)

    @doc false
    def __test_cache_channel__(state, channel), do: cache_channel(state, channel)

    @doc false
    def __test_fetch_active_channel__(state, server_channel) do
      fetch_active_channel(state, server_channel)
    end

    @doc false
    def __test_sync_active_channel__(state), do: sync_active_channel(state)

    @doc false
    def __test_delete_channel__(state, server_channel), do: delete_channel(state, server_channel)
  end

  defp authenticate_password(auth, username, password, socket) do
    peer =
      case :inet.peername(socket) do
        {:ok, peer} -> peer
        {:error, _reason} -> nil
      end

    case Sftpd.Auth.Adapter.authenticate_password(auth, username, password, peer) do
      {:ok, session} when is_map(session) -> {:ok, session}
      :disconnect -> :disconnect
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

  defp fetch_active_channel(
         %{active_channel_id: server_channel, active_channel: channel},
         server_channel
       )
       when not is_nil(channel),
       do: {:ok, channel}

  defp fetch_active_channel(state, server_channel), do: fetch_channel(state, server_channel)

  defp max_channels_reached?(state) do
    map_size(state.channels) >= state.max_channels
  end

  defp parse_channel_open_sender(rest) do
    with {:ok, "session", rest} <- Wire.take_string(rest),
         <<client_channel::32, _client_window::32, _client_max_packet::32, ""::binary>> <- rest do
      {:ok, client_channel}
    else
      _ -> {:error, :bad_message}
    end
  end

  defp put_channel(state, %{server_channel: server_channel} = channel) do
    state =
      if Map.get(state, :active_channel_id) in [nil, server_channel] do
        state
      else
        sync_active_channel(state)
      end

    state
    |> Map.put(:channels, Map.put(state.channels, server_channel, channel))
    |> Map.put(:active_channel_id, server_channel)
    |> Map.put(:active_channel, channel)
  end

  defp cache_channel(state, %{server_channel: server_channel} = channel) do
    state =
      if Map.get(state, :active_channel_id) in [nil, server_channel] do
        state
      else
        sync_active_channel(state)
      end

    state
    |> Map.put(:active_channel_id, server_channel)
    |> Map.put(:active_channel, channel)
  end

  defp sync_active_channel(%{active_channel_id: nil} = state), do: state
  defp sync_active_channel(%{active_channel: nil} = state), do: state

  defp sync_active_channel(%{active_channel_id: server_channel, active_channel: channel} = state) do
    Map.put(state, :channels, Map.put(state.channels, server_channel, channel))
  end

  defp sync_active_channel(state), do: state

  defp delete_channel(state, server_channel) do
    state = Map.put(state, :channels, Map.delete(state.channels, server_channel))

    if Map.get(state, :active_channel_id) == server_channel do
      state
      |> Map.put(:active_channel_id, nil)
      |> Map.put(:active_channel, nil)
    else
      state
    end
  end

  defp cleanup_open_handles(%{channels: _channels} = state) do
    state = sync_active_channel(state)
    channels = state.channels

    channels =
      Map.new(channels, fn {server_channel, channel} ->
        {server_channel,
         %{channel | sftp_session: SFTP.Session.cleanup_open_handles(channel.sftp_session)}}
      end)

    %{state | channels: channels}
  end

  defp cleanup_open_handles(state), do: state

  defp handle_sftp_data(data, channel) do
    case split_sftp_packets(channel.sftp_buffer, data) do
      {:ok, [], buffer} ->
        {[], %{channel | sftp_buffer: buffer}}

      {:ok, packets, buffer} ->
        {responses, sftp_session} =
          Enum.map_reduce(packets, channel.sftp_session, fn packet, session ->
            SFTP.Session.handle_packet(packet, session)
          end)

        {responses, %{channel | sftp_buffer: buffer, sftp_session: sftp_session}}

      {:error, reason} ->
        {[SFTP.Codec.status(0, reason)], %{channel | sftp_buffer: ""}}
    end
  end

  defp split_sftp_packets("", data), do: split_complete_sftp_packets(data, [])

  defp split_sftp_packets(%{header: header}, data) do
    needed = 4 - byte_size(header)

    if byte_size(data) < needed do
      {:ok, [], %{header: header <> data}}
    else
      <<header_tail::binary-size(^needed), rest::binary>> = data
      <<packet_length::32>> = header <> header_tail
      continue_partial_sftp_packet(packet_length, [], 0, rest, [])
    end
  end

  defp split_sftp_packets(%{packet_length: packet_length, parts: parts, size: size}, data) do
    continue_partial_sftp_packet(packet_length, parts, size, data, [])
  end

  defp split_complete_sftp_packets(<<>>, packets), do: {:ok, Enum.reverse(packets), ""}

  defp split_complete_sftp_packets(data, packets) when byte_size(data) < 4 do
    {:ok, Enum.reverse(packets), %{header: data}}
  end

  defp split_complete_sftp_packets(<<packet_length::32, _rest::binary>>, _packets)
       when packet_length > @max_sftp_packet_length,
       do: {:error, :bad_message}

  defp split_complete_sftp_packets(
         <<packet_length::32, packet::binary-size(packet_length), rest::binary>>,
         packets
       ) do
    split_complete_sftp_packets(rest, [packet | packets])
  end

  defp split_complete_sftp_packets(<<packet_length::32, rest::binary>>, packets) do
    continue_partial_sftp_packet(packet_length, [], 0, rest, packets)
  end

  defp continue_partial_sftp_packet(packet_length, _parts, _size, _data, _packets)
       when packet_length > @max_sftp_packet_length,
       do: {:error, :bad_message}

  defp continue_partial_sftp_packet(packet_length, parts, size, data, packets) do
    needed = packet_length - size

    if byte_size(data) < needed do
      {:ok, Enum.reverse(packets),
       %{packet_length: packet_length, parts: [data | parts], size: size + byte_size(data)}}
    else
      <<part::binary-size(^needed), rest::binary>> = data
      packet = IO.iodata_to_binary(Enum.reverse([part | parts]))
      split_complete_sftp_packets(rest, [packet | packets])
    end
  end

  defp sftp_buffer_empty?(""), do: true
  defp sftp_buffer_empty?(_buffer), do: false

  defp parse_want_reply(rest) do
    with {:ok, _request, rest} <- Wire.take_string(rest),
         {:ok, want_reply?, _rest} <- Wire.take_boolean(rest) do
      want_reply?
    else
      _ -> false
    end
  end
end
