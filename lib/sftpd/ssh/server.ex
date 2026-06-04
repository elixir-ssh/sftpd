defmodule Sftpd.SSH.Server do
  @moduledoc false

  use GenServer

  require Logger

  alias Sftpd.SFTP
  alias Sftpd.SFTP.SerializedPacket
  alias Sftpd.SSH.{Algorithms, Cipher, Kex, Keys, Packet, Wire}

  @banner "SSH-2.0-sftpd-elixir\r\n"
  @handshake_timeout 30_000
  @encrypted_idle_timeout :infinity
  @channel_window_size 64 * 1024 * 1024
  @channel_max_packet_size 1_048_576
  @aead_tag_size 16

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
    notify_profile_owner(pid)
    send(pid, {:serve, socket, connection_state})
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
    Logger.debug("pure ssh received service request")

    with {:ok, "ssh-userauth", ""} <- Wire.take_string(rest),
         {:ok, state} <-
           send_encrypted_payload(socket, state, [<<6>>, Wire.string("ssh-userauth")]) do
      {:continue, state}
    else
      _ -> {:stop, state}
    end
  end

  defp handle_encrypted_payload(<<50, rest::binary>>, state, socket) do
    Logger.debug("pure ssh received userauth request")

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
    Logger.debug("pure ssh received channel open")

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
        sftp_buffer: "",
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
      _ -> {:stop, state}
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

  defp handle_encrypted_payload(<<94, recipient::32, rest::binary>>, state, socket) do
    Logger.debug("pure ssh received channel data")

    with {:ok, data, ""} <- Wire.take_string(rest),
         {:ok, %{sftp?: true} = channel} <- fetch_channel(state, recipient) do
      {responses, channel} = handle_sftp_data(data, channel)
      state = put_channel(state, channel)

      {responses_acc, state, channel, bytes_read} =
        drain_buffered_sftp_data(
          socket,
          recipient,
          state,
          channel,
          Enum.reverse(responses),
          byte_size(data)
        )

      responses = Enum.reverse(responses_acc)
      channel = append_pending_responses(channel, responses)
      state = put_channel(state, channel)

      case flush_sftp_responses(socket, state, channel, bytes_read) do
        {:ok, state} -> {:continue, state}
        {:error, _reason, state} -> {:stop, state}
      end
    else
      _ -> {:continue, state}
    end
  end

  defp handle_encrypted_payload(<<93, recipient::32, bytes::32>>, state, socket) do
    with {:ok, channel} <- fetch_channel(state, recipient) do
      channel = %{channel | client_window: channel.client_window + bytes}
      state = put_channel(state, channel)

      case flush_sftp_responses(socket, state, channel, 0) do
        {:ok, state} -> {:continue, state}
        {:error, _reason, state} -> {:stop, state}
      end
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
    Logger.debug("pure ssh ignored encrypted message #{inspect(Packet.message_id(payload))}")
    {:continue, state}
  end

  defp drain_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read) do
    if sftp_responses_near_window?(channel, responses) do
      {responses, state, channel, bytes_read}
    else
      drain_more_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read)
    end
  end

  defp drain_more_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read) do
    case recv_buffered_encrypted_payload(state) do
      {:ok, <<94, ^recipient::32, rest::binary>>, state} ->
        with {:ok, data, ""} <- Wire.take_string(rest),
             {:ok, %{sftp?: true} = channel} <- fetch_channel(state, recipient) do
          {new_responses, channel} = handle_sftp_data(data, channel)
          state = put_channel(state, channel)
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
          _ -> {responses, state, channel, bytes_read}
        end

      {:ok, <<93, ^recipient::32, bytes::32>>, state} ->
        channel = %{channel | client_window: channel.client_window + bytes}
        state = put_channel(state, channel)

        case flush_sftp_responses(socket, state, channel, 0) do
          {:ok, state} ->
            {:ok, channel} = fetch_channel(state, recipient)
            drain_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read)

          {:error, _reason, state} ->
            {responses, state, channel, bytes_read}
        end

      {:ok, payload, state} ->
        case handle_encrypted_payload(payload, state, socket) do
          {:continue, state} ->
            drain_buffered_sftp_data(socket, recipient, state, channel, responses, bytes_read)

          {:stop, state} ->
            {responses, state, channel, bytes_read}
        end

      :none ->
        {responses, state, channel, bytes_read}

      {:error, _reason} ->
        {responses, state, channel, bytes_read}
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

  defp recv_encrypted_payload(socket, %{buffer: buffer, c2s_cipher: cipher} = state) do
    case recv_encrypted_packet(socket, buffer || "", @encrypted_idle_timeout) do
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

  defp recv_encrypted_packet(socket, "", timeout) do
    with {:ok, <<packet_length::32>>} <- :gen_tcp.recv(socket, 4, timeout),
         {:ok, encrypted_body} <-
           :gen_tcp.recv(socket, packet_length + @aead_tag_size, timeout) do
      {:ok, packet_length, encrypted_body, ""}
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
    end
  end

  defp encrypted_packet_missing_bytes(<<packet_length::32, _rest::binary>> = buffer) do
    max(4 + packet_length + @aead_tag_size - byte_size(buffer), 0)
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
    {encrypted, state} =
      Enum.map_reduce(payloads, state, fn payload, %{s2c_cipher: cipher} = state ->
        {encrypted, cipher} =
          Cipher.encrypt_packet(
            cipher,
            Packet.encode_aead_packet(payload, Cipher.block_size(cipher))
          )

        {encrypted, %{state | s2c_cipher: cipher}}
      end)

    case :gen_tcp.send(socket, encrypted) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp flush_sftp_responses(socket, state, channel, bytes_read) do
    {ready, pending, response_bytes} =
      split_responses_for_window(channel.pending_responses, channel.client_window)

    channel = %{
      channel
      | pending_responses: pending,
        client_window: channel.client_window - response_bytes
    }

    state = put_channel(state, channel)

    payloads =
      []
      |> maybe_add_window_adjust(channel.client_channel, bytes_read)
      |> prepend_sftp_response_payloads(channel, ready)
      |> Enum.reverse()

    case payloads do
      [] ->
        {:ok, state}

      payloads ->
        case send_encrypted_payloads(socket, state, payloads) do
          {:ok, state} -> {:ok, state}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp maybe_add_window_adjust(payloads, _client_channel, 0), do: payloads

  defp maybe_add_window_adjust(payloads, client_channel, bytes_read) do
    [<<93, client_channel::32, bytes_read::32>> | payloads]
  end

  defp prepend_sftp_response_payloads(payloads, _channel, []), do: payloads

  defp prepend_sftp_response_payloads(payloads, channel, responses) do
    Enum.reverse(sftp_response_payloads(channel, responses), payloads)
  end

  defp append_pending_responses(channel, []), do: channel

  defp append_pending_responses(channel, responses) do
    Map.update!(channel, :pending_responses, &(&1 ++ responses))
  end

  defp split_responses_for_window(responses, window) do
    split_responses_for_window(responses, max(window, 0), [], 0)
  end

  defp split_responses_for_window([], _window, ready, bytes) do
    {Enum.reverse(ready), [], bytes}
  end

  defp split_responses_for_window([response | rest] = responses, window, ready, bytes) do
    {response_size, _response_data} = sftp_response_iodata(response)

    if bytes + response_size <= window do
      split_responses_for_window(rest, window, [response | ready], bytes + response_size)
    else
      {Enum.reverse(ready), responses, bytes}
    end
  end

  defp sftp_responses_near_window?(_channel, []), do: false

  defp sftp_responses_near_window?(channel, responses) do
    sftp_responses_window_size(responses) >=
      max(channel.client_window - channel.client_max_packet, 0)
  end

  defp sftp_responses_window_size(responses) do
    Enum.reduce(responses, 0, fn response, size ->
      {response_size, _response_data} = sftp_response_iodata(response)
      size + response_size
    end)
  end

  defp sftp_response_payloads(channel, responses) when is_list(responses) do
    max_packet = max(1, channel.client_max_packet)
    client_channel = channel.client_channel

    {payloads, parts, size} =
      Enum.reduce(responses, {[], [], 0}, fn response, {payloads, parts, size} ->
        {response_size, response_data} = sftp_response_iodata(response)

        cond do
          response_size > max_packet ->
            payloads = flush_channel_data_payload(payloads, client_channel, parts, size)
            payloads = Enum.reverse(sftp_response_split_payloads(channel, response), payloads)
            {payloads, [], 0}

          size + response_size <= max_packet ->
            {payloads, [parts, response_data], size + response_size}

          true ->
            payloads = flush_channel_data_payload(payloads, client_channel, parts, size)
            {payloads, response_data, response_size}
        end
      end)

    payloads
    |> flush_channel_data_payload(client_channel, parts, size)
    |> Enum.reverse()
  end

  defp flush_channel_data_payload(payloads, _client_channel, _parts, 0), do: payloads

  defp flush_channel_data_payload(payloads, client_channel, parts, _size) do
    [channel_data_payload(client_channel, parts) | payloads]
  end

  defp sftp_response_iodata(%SerializedPacket{kind: :iodata, iodata: data, size: size}) do
    {size, data}
  end

  defp sftp_response_iodata(%SerializedPacket{
         kind: :data,
         header: header,
         data: data,
         size: size
       }) do
    {size, [header, data]}
  end

  defp sftp_response_split_payloads(channel, %SerializedPacket{kind: :iodata, iodata: data}) do
    data = IO.iodata_to_binary(data)
    channel_data_payloads(channel, data)
  end

  defp sftp_response_split_payloads(
         channel,
         %SerializedPacket{kind: :data, header: header, data: data}
       ) do
    channel_data_pair_payloads(channel, header, data)
  end

  defp channel_data_payloads(channel, data) do
    max_packet = max(1, channel.client_max_packet)
    channel_data_payloads(channel.client_channel, data, max_packet, [])
  end

  defp channel_data_payloads(_client_channel, "", _max_packet, acc), do: Enum.reverse(acc)

  defp channel_data_payloads(client_channel, data, max_packet, acc) do
    bytes = min(byte_size(data), max_packet)
    <<chunk::binary-size(^bytes), rest::binary>> = data
    payload = channel_data_payload(client_channel, chunk)
    channel_data_payloads(client_channel, rest, max_packet, [payload | acc])
  end

  defp channel_data_payload(client_channel, data) do
    [<<94, client_channel::32>>, Wire.string(data)]
  end

  defp channel_data_pair_payloads(channel, header, data) do
    max_packet = max(1, channel.client_max_packet)
    client_channel = channel.client_channel
    header_size = byte_size(header)

    cond do
      header_size >= max_packet ->
        channel_data_payloads(client_channel, header, max_packet, []) ++
          channel_data_payloads(client_channel, IO.iodata_to_binary(data), max_packet, [])

      true ->
        channel_data_pair_payloads(client_channel, header, data, max_packet)
    end
  end

  defp channel_data_pair_payloads(client_channel, header, data, max_packet)
       when is_binary(data) do
    first_data_size = min(byte_size(data), max_packet - byte_size(header))
    <<first_data::binary-size(^first_data_size), rest::binary>> = data

    first_payload = channel_data_payload(client_channel, [header, first_data])

    [first_payload | channel_data_payloads(client_channel, rest, max_packet, [])]
  end

  defp channel_data_pair_payloads(client_channel, header, data, max_packet) do
    channel_data_pair_payloads(
      client_channel,
      header,
      IO.iodata_to_binary(data),
      max_packet
    )
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
        SFTP.Session.handle_packet(packet, session)
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
