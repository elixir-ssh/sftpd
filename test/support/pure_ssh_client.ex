defmodule Sftpd.Test.PureSSHClient do
  @moduledoc false

  import ExUnit.Assertions

  @pure_ssh_channel_window_size 64 * 1024 * 1024
  @pure_ssh_channel_max_packet_size 1_048_576

  def open_raw_authenticated_session(port, opts \\ []) do
    %{socket: socket, c2s: c2s, s2c: s2c, session_id: session_id} =
      open_raw_userauth_session(port)

    {c2s, s2c} = assert_password_auth_success(socket, c2s, s2c)

    client_channel = 7
    client_window = Keyword.get(opts, :client_window, 2_097_152)
    client_max_packet = Keyword.get(opts, :client_max_packet, 262_144)

    {packet, c2s} =
      encrypt_client_packet(c2s, [
        <<90>>,
        Sftpd.SSH.Wire.string("session"),
        <<client_channel::32, client_window::32, client_max_packet::32>>
      ])

    assert :ok = :gen_tcp.send(socket, packet)

    assert {:ok,
            <<91, ^client_channel::32, server_channel::32, @pure_ssh_channel_window_size::32,
              @pure_ssh_channel_max_packet_size::32>>, s2c} =
             recv_encrypted_server_packet(socket, s2c)

    %{
      socket: socket,
      c2s: c2s,
      s2c: s2c,
      session_id: session_id,
      client_channel: client_channel,
      server_channel: server_channel
    }
  end

  def open_raw_userauth_session(port) do
    assert {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    assert {:ok, "SSH-2.0-sftpd-elixir\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
    assert :ok = :gen_tcp.send(socket, "SSH-2.0-test-client\r\n")
    assert {:ok, packet} = :gen_tcp.recv(socket, 0, 1_000)

    assert {:ok, <<20, _rest::binary>> = server_kexinit, ""} =
             Sftpd.SSH.Packet.decode_clear(packet)

    {client_kexinit, _parsed} = Sftpd.SSH.Algorithms.server_kexinit()
    {client_public, client_private} = Sftpd.SSH.Kex.generate_keypair()
    assert :ok = :gen_tcp.send(socket, Sftpd.SSH.Packet.encode_clear(client_kexinit))

    assert :ok =
             :gen_tcp.send(
               socket,
               Sftpd.SSH.Packet.encode_clear([<<30>>, Sftpd.SSH.Wire.string(client_public)])
             )

    assert {:ok, <<31, reply::binary>>, rest} = recv_clear_packet(socket, "")
    assert {:ok, host_key_blob, reply} = Sftpd.SSH.Wire.take_string(reply)
    assert {:ok, server_public, reply} = Sftpd.SSH.Wire.take_string(reply)
    assert {:ok, _signature_blob, ""} = Sftpd.SSH.Wire.take_string(reply)
    assert {:ok, <<21>>, _rest} = recv_clear_packet(socket, rest)

    {:ok, shared_secret} = Sftpd.SSH.Kex.shared_secret(server_public, client_private)

    exchange_hash =
      Sftpd.SSH.Kex.exchange_hash(%{
        client_version: "SSH-2.0-test-client",
        server_version: "SSH-2.0-sftpd-elixir",
        client_kexinit: client_kexinit,
        server_kexinit: server_kexinit,
        host_key_blob: host_key_blob,
        client_public: client_public,
        server_public: server_public,
        shared_secret: shared_secret
      })

    c2s =
      Sftpd.SSH.Cipher.new(
        "aes256-gcm@openssh.com",
        :client_to_server,
        shared_secret,
        exchange_hash,
        exchange_hash
      )

    s2c =
      Sftpd.SSH.Cipher.new(
        "aes256-gcm@openssh.com",
        :server_to_client,
        shared_secret,
        exchange_hash,
        exchange_hash
      )

    assert :ok = :gen_tcp.send(socket, Sftpd.SSH.Packet.encode_clear(<<21>>))
    {c2s, s2c} = assert_service_accept(socket, c2s, s2c)
    %{socket: socket, c2s: c2s, s2c: s2c, session_id: exchange_hash}
  end

  def start_raw_sftp(socket, c2s, s2c, client_channel, server_channel) do
    {packet, c2s} =
      encrypt_client_packet(c2s, [
        <<98, server_channel::32>>,
        Sftpd.SSH.Wire.string("subsystem"),
        Sftpd.SSH.Wire.boolean(true),
        Sftpd.SSH.Wire.string("sftp")
      ])

    assert :ok = :gen_tcp.send(socket, packet)
    assert {:ok, <<99, ^client_channel::32>>, s2c} = recv_encrypted_server_packet(socket, s2c)

    sftp_init = <<5::32, 1, 3::32>>

    {packet, c2s} =
      encrypt_client_packet(c2s, [
        <<94, server_channel::32>>,
        Sftpd.SSH.Wire.string(sftp_init)
      ])

    assert :ok = :gen_tcp.send(socket, packet)

    assert {:ok, rest, s2c, buffer} =
             recv_channel_data_after_optional_adjust(
               socket,
               s2c,
               "",
               client_channel,
               byte_size(sftp_init)
             )

    assert {:ok, sftp_response, ""} = Sftpd.SSH.Wire.take_string(rest)
    assert <<5::32, 2, 3::32>> = sftp_response

    {c2s, s2c, buffer}
  end

  def recv_clear_packet(socket, buffer) do
    case Sftpd.SSH.Packet.decode_clear(buffer) do
      {:ok, payload, rest} ->
        {:ok, payload, rest}

      :more ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
        recv_clear_packet(socket, buffer <> data)
    end
  end

  def assert_encrypted_exchange(socket, c2s, s2c) do
    {c2s, s2c} = assert_service_accept(socket, c2s, s2c)
    assert_password_auth_success(socket, c2s, s2c)
  end

  def assert_service_accept(socket, c2s, s2c) do
    {packet, c2s} =
      encrypt_client_packet(c2s, [<<5>>, Sftpd.SSH.Wire.string("ssh-userauth")])

    assert :ok = :gen_tcp.send(socket, packet)
    assert {:ok, <<6, rest::binary>>, s2c} = recv_encrypted_server_packet(socket, s2c)
    assert {:ok, "ssh-userauth", ""} = Sftpd.SSH.Wire.take_string(rest)
    {c2s, s2c}
  end

  def assert_password_auth_success(socket, c2s, s2c) do
    {packet, c2s} = encrypt_client_password_auth(c2s, "user", "password")

    assert :ok = :gen_tcp.send(socket, packet)
    assert {:ok, <<52>>, s2c} = recv_encrypted_server_packet(socket, s2c)
    {c2s, s2c}
  end

  def encrypt_client_password_auth(cipher, username, password) do
    encrypt_client_packet(cipher, [
      <<50>>,
      Sftpd.SSH.Wire.string(username),
      Sftpd.SSH.Wire.string("ssh-connection"),
      Sftpd.SSH.Wire.string("password"),
      Sftpd.SSH.Wire.boolean(false),
      Sftpd.SSH.Wire.string(password)
    ])
  end

  def assert_encrypted_sftp_init(socket, c2s, s2c) do
    client_channel = 7

    {packet, c2s} =
      encrypt_client_packet(c2s, [
        <<90>>,
        Sftpd.SSH.Wire.string("session"),
        <<client_channel::32, 2_097_152::32, 262_144::32>>
      ])

    assert :ok = :gen_tcp.send(socket, packet)

    assert {:ok,
            <<91, ^client_channel::32, server_channel::32, @pure_ssh_channel_window_size::32,
              @pure_ssh_channel_max_packet_size::32>>, s2c} =
             recv_encrypted_server_packet(socket, s2c)

    {packet, c2s} =
      encrypt_client_packet(c2s, [
        <<98, server_channel::32>>,
        Sftpd.SSH.Wire.string("subsystem"),
        Sftpd.SSH.Wire.boolean(true),
        Sftpd.SSH.Wire.string("sftp")
      ])

    assert :ok = :gen_tcp.send(socket, packet)
    assert {:ok, <<99, ^client_channel::32>>, s2c} = recv_encrypted_server_packet(socket, s2c)

    sftp_init = <<5::32, 1, 3::32>>

    {packet, c2s} =
      encrypt_client_packet(c2s, [
        <<94, server_channel::32>>,
        Sftpd.SSH.Wire.string(sftp_init)
      ])

    assert :ok = :gen_tcp.send(socket, packet)

    assert {:ok, rest, s2c, _buffer} =
             recv_channel_data_after_optional_adjust(
               socket,
               s2c,
               "",
               client_channel,
               byte_size(sftp_init)
             )

    assert {:ok, sftp_response, ""} = Sftpd.SSH.Wire.take_string(rest)
    assert <<5::32, 2, 3::32>> = sftp_response

    {c2s, s2c}
  end

  def recv_channel_data_after_optional_adjust(
        socket,
        s2c,
        buffer,
        client_channel,
        expected_adjust_bytes \\ nil
      ) do
    case recv_encrypted_server_packet_with_rest(socket, s2c, buffer) do
      {:ok, <<93, ^client_channel::32, bytes::32>>, s2c, buffer} ->
        if expected_adjust_bytes, do: assert(bytes == expected_adjust_bytes)

        case recv_encrypted_server_packet_with_rest(socket, s2c, buffer) do
          {:ok, <<94, ^client_channel::32, rest::binary>>, s2c, buffer} ->
            {:ok, rest, s2c, buffer}

          other ->
            other
        end

      {:ok, <<94, ^client_channel::32, rest::binary>>, s2c, buffer} ->
        {:ok, rest, s2c, buffer}

      other ->
        other
    end
  end

  def encrypt_client_packet(cipher, payload) do
    {packet, cipher} =
      Sftpd.SSH.Cipher.encrypt_packet(
        cipher,
        Sftpd.SSH.Packet.encode_aead_packet(payload, Sftpd.SSH.Cipher.block_size(cipher))
      )

    {IO.iodata_to_binary(packet), cipher}
  end

  def encrypt_client_channel_data(cipher, server_channel, sftp_payload) do
    len = IO.iodata_length(sftp_payload)

    encrypt_client_packet(cipher, [
      <<94, server_channel::32>>,
      Sftpd.SSH.Wire.string([<<len::32>>, sftp_payload])
    ])
  end

  def rekey(socket, c2s, s2c, session_id) do
    {client_kexinit, _parsed} = Sftpd.SSH.Algorithms.server_kexinit()
    {client_public, client_private} = Sftpd.SSH.Kex.generate_keypair()

    {packet, c2s} = encrypt_client_packet(c2s, client_kexinit)
    assert :ok = :gen_tcp.send(socket, packet)

    assert {:ok, <<20, _rest::binary>> = server_kexinit, s2c} =
             recv_encrypted_server_packet(socket, s2c)

    {packet, c2s} =
      encrypt_client_packet(c2s, [<<30>>, Sftpd.SSH.Wire.string(client_public)])

    assert :ok = :gen_tcp.send(socket, packet)

    assert {:ok, <<31, reply::binary>>, s2c, buffer} =
             recv_encrypted_server_packet_with_rest(socket, s2c, "")

    assert {:ok, host_key_blob, reply} = Sftpd.SSH.Wire.take_string(reply)
    assert {:ok, server_public, reply} = Sftpd.SSH.Wire.take_string(reply)
    assert {:ok, _signature_blob, ""} = Sftpd.SSH.Wire.take_string(reply)

    assert {:ok, <<21>>, _old_s2c, _buffer} =
             recv_encrypted_server_packet_with_rest(socket, s2c, buffer)

    {:ok, shared_secret} = Sftpd.SSH.Kex.shared_secret(server_public, client_private)

    exchange_hash =
      Sftpd.SSH.Kex.exchange_hash(%{
        client_version: "SSH-2.0-test-client",
        server_version: "SSH-2.0-sftpd-elixir",
        client_kexinit: client_kexinit,
        server_kexinit: server_kexinit,
        host_key_blob: host_key_blob,
        client_public: client_public,
        server_public: server_public,
        shared_secret: shared_secret
      })

    {packet, _old_c2s} = encrypt_client_packet(c2s, <<21>>)
    assert :ok = :gen_tcp.send(socket, packet)

    c2s =
      Sftpd.SSH.Cipher.new(
        "aes256-gcm@openssh.com",
        :client_to_server,
        shared_secret,
        exchange_hash,
        session_id
      )

    s2c =
      Sftpd.SSH.Cipher.new(
        "aes256-gcm@openssh.com",
        :server_to_client,
        shared_secret,
        exchange_hash,
        session_id
      )

    {c2s, s2c}
  end

  def recv_encrypted_server_packet(socket, cipher, buffer \\ "") do
    {:ok, payload, cipher, _rest} = recv_encrypted_server_packet_with_rest(socket, cipher, buffer)
    {:ok, payload, cipher}
  end

  def recv_encrypted_server_packet_with_rest(socket, cipher, buffer) do
    case Sftpd.SSH.Cipher.decrypt_packet(cipher, buffer) do
      {:ok, clear_packet, rest, cipher} ->
        assert {:ok, payload, ""} = Sftpd.SSH.Packet.decode_clear(clear_packet)
        {:ok, payload, cipher, rest}

      :more ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
        recv_encrypted_server_packet_with_rest(socket, cipher, buffer <> data)
    end
  end
end
