defmodule SftpdTest do
  use ExUnit.Case, async: false

  alias Sftpd.Test.TelemetryHelper

  @client_opts [
    silently_accept_hosts: true,
    user: ~c"testuser",
    password: ~c"testpass"
  ]
  # OpenSSH caps an outbound SFTP message at 256KiB including request headers.
  @openssh_sftp_block_size 256 * 1024 - 64
  @pure_ssh_channel_window_size 64 * 1024 * 1024
  @pure_ssh_channel_max_packet_size 1_048_576

  defmodule CustomAuth do
    @behaviour Sftpd.Auth

    @impl true
    def authenticate_password("tenant-user", "secret", _peer, opts) do
      {:ok,
       %{user_id: 123, tenant_id: Keyword.fetch!(opts, :tenant_id), sftp_prefix: "tenants/123/"}}
    end

    def authenticate_password(_username, _password, _peer, _opts), do: :error

    @impl true
    def authorize_public_key("key-user", public_key, opts) do
      if Sftpd.Auth.fingerprint(public_key) == Keyword.fetch!(opts, :fingerprint) do
        {:ok, %{user_id: 456, sftp_prefix: "tenants/456/"}}
      else
        :error
      end
    end

    def authorize_public_key(_username, _public_key, _opts), do: :error
  end

  defmodule MissingPasswordCallbackAuth do
    def authorize_public_key(_username, _public_key, _opts), do: :error
  end

  defmodule ShutdownOnStopServer do
    use GenServer

    def start(test_pid), do: GenServer.start(__MODULE__, test_pid)
    def init(test_pid), do: {:ok, test_pid}

    def terminate(_reason, test_pid) do
      send(test_pid, :terminating)
      exit(:shutdown)
    end
  end

  defmodule SessionBackend do
    def init(opts) do
      {:ok, mem_state} = Sftpd.Backends.Memory.init([])
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), mem_state: mem_state}}
    end

    def open_dir(path, session, %{test_pid: test_pid, mem_state: mem_state}) do
      send(test_pid, {:backend_session, session})
      Sftpd.Backends.Memory.open_dir(path, session, mem_state)
    end

    def read_dir(handle, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.read_dir(handle, mem_state)

    def close_dir(handle, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.close_dir(handle, mem_state)

    def file_attrs(path, session, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.file_attrs(path, session, mem_state)

    def open_read(path, session, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.open_read(path, session, mem_state)

    def read_at(handle, offset, len, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.read_at(handle, offset, len, mem_state)

    def open_write(path, attrs, session, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.open_write(path, attrs, session, mem_state)

    def write_at(handle, offset, data, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.write_at(handle, offset, data, mem_state)

    def finish_write(handle, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.finish_write(handle, mem_state)

    def abort_write(handle, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.abort_write(handle, mem_state)

    def make_dir(path, attrs, session, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.make_dir(path, attrs, session, mem_state)

    def del_dir(path, session, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.del_dir(path, session, mem_state)

    def delete(path, session, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.delete(path, session, mem_state)

    def rename(src, dst, session, %{mem_state: mem_state}),
      do: Sftpd.Backends.Memory.rename(src, dst, session, mem_state)
  end

  setup do
    port = 10_000 + :rand.uniform(10_000)
    system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

    {:ok, ref} =
      Sftpd.start_server(
        port: port,
        backend: Sftpd.Backends.Memory,
        backend_opts: [],
        auth: {:passwords, [{"testuser", "testpass"}]},
        system_dir: system_dir
      )

    {:ok, conn} = :ssh.connect(:localhost, port, @client_opts)
    {:ok, channel} = :ssh_sftp.start_channel(conn)

    on_exit(fn ->
      :ssh.close(conn)
      :ssh.stop_daemon(ref)
    end)

    %{channel: channel, port: port}
  end

  test "pure transport start_server does not link listener to caller" do
    port = 20_000 + :rand.uniform(10_000)
    system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

    assert {:ok, {:elixir, pid} = ref} =
             Sftpd.start_server(
               port: port,
               transport: :elixir,
               backend: Sftpd.Backends.Memory,
               backend_opts: [],
               auth: {:passwords, [{"user", "password"}]},
               system_dir: system_dir
             )

    on_exit(fn -> Sftpd.stop_server(ref) end)

    assert Process.alive?(pid)
    {:links, links} = Process.info(self(), :links)
    refute pid in links
  end

  describe "directory operations" do
    test "list_dir on root returns . and ..", %{channel: ch} do
      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/")
      assert ~c"." in listing
      assert ~c".." in listing
    end

    test "make and list directory", %{channel: ch} do
      assert :ok = :ssh_sftp.make_dir(ch, ~c"/testdir")
      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/")
      assert ~c"testdir" in listing
    end

    test "delete directory", %{channel: ch} do
      :ssh_sftp.make_dir(ch, ~c"/delme")
      assert :ok = :ssh_sftp.del_dir(ch, ~c"/delme")
      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/")
      refute ~c"delme" in listing
    end
  end

  describe "file operations" do
    test "write and read file", %{channel: ch} do
      content = "Hello, SFTP!"

      # Write file
      assert {:ok, handle} = :ssh_sftp.open(ch, ~c"/test.txt", [:write])
      assert :ok = :ssh_sftp.write(ch, handle, content)
      assert :ok = :ssh_sftp.close(ch, handle)

      # Read file - ssh_sftp returns charlist
      assert {:ok, handle} = :ssh_sftp.open(ch, ~c"/test.txt", [:read])
      assert {:ok, read_content} = :ssh_sftp.read(ch, handle, byte_size(content))
      assert to_string(read_content) == content
      assert :ok = :ssh_sftp.close(ch, handle)
    end

    test "read_file_info returns file info", %{channel: ch} do
      {:ok, h} = :ssh_sftp.open(ch, ~c"/info.txt", [:write])
      :ssh_sftp.write(ch, h, "12345")
      :ssh_sftp.close(ch, h)

      assert {:ok, {:file_info, 5, :regular, :read_write, _, _, _, _, _, _, _, _, _, _}} =
               :ssh_sftp.read_file_info(ch, ~c"/info.txt")
    end

    test "read_file_info on directory", %{channel: ch} do
      :ssh_sftp.make_dir(ch, ~c"/adir")

      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               :ssh_sftp.read_file_info(ch, ~c"/adir")
    end

    test "delete file", %{channel: ch} do
      {:ok, h} = :ssh_sftp.open(ch, ~c"/todelete.txt", [:write])
      :ssh_sftp.write(ch, h, "bye")
      :ssh_sftp.close(ch, h)

      assert :ok = :ssh_sftp.delete(ch, ~c"/todelete.txt")
      assert {:error, :no_such_file} = :ssh_sftp.read_file_info(ch, ~c"/todelete.txt")
    end

    test "rename file", %{channel: ch} do
      {:ok, h} = :ssh_sftp.open(ch, ~c"/oldname.txt", [:write])
      :ssh_sftp.write(ch, h, "content")
      :ssh_sftp.close(ch, h)

      assert :ok = :ssh_sftp.rename(ch, ~c"/oldname.txt", ~c"/newname.txt")
      assert {:error, :no_such_file} = :ssh_sftp.read_file_info(ch, ~c"/oldname.txt")
      assert {:ok, _} = :ssh_sftp.read_file_info(ch, ~c"/newname.txt")
    end
  end

  describe "nested directories" do
    test "create nested structure and list", %{channel: ch} do
      :ssh_sftp.make_dir(ch, ~c"/parent")
      :ssh_sftp.make_dir(ch, ~c"/parent/child")

      {:ok, h} = :ssh_sftp.open(ch, ~c"/parent/child/file.txt", [:write])
      :ssh_sftp.write(ch, h, "nested")
      :ssh_sftp.close(ch, h)

      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/parent")
      assert ~c"child" in listing

      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/parent/child")
      assert ~c"file.txt" in listing
    end
  end

  describe "init_backend error handling" do
    defmodule FailingBackend do
      def init(_opts), do: {:error, :init_failed}
    end

    test "start_server propagates backend init error" do
      assert {:error, :init_failed} =
               Sftpd.start_server(
                 backend: FailingBackend,
                 system_dir: "/tmp",
                 auth: {:passwords, []}
               )
    end

    test "start_server rejects invalid backend and transport options" do
      assert {:error, {:invalid_option, {:backend, "not_a_backend"}}} =
               Sftpd.start_server(
                 backend: "not_a_backend",
                 system_dir: "/tmp",
                 auth: {:passwords, []}
               )

      assert {:error, {:invalid_option, {:transport, :bogus}}} =
               Sftpd.start_server(
                 transport: :bogus,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: "/tmp",
                 auth: {:passwords, []}
               )
    end

    test "emits telemetry for start errors" do
      handler_id =
        TelemetryHelper.attach(self(), [
          [:sftpd, :server, :start]
        ])

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :init_failed} =
               Sftpd.start_server(
                 backend: FailingBackend,
                 system_dir: "/tmp",
                 auth: {:passwords, []}
               )

      assert_receive {:telemetry_event, [:sftpd, :server, :start], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.result == :error
      assert metadata.reason == :init_failed
      assert metadata.backend == FailingBackend
      assert metadata.backend_kind == :module
    end
  end

  describe "pure Elixir transport" do
    defmodule NonMemoryBackend do
      def init(_opts), do: {:ok, %{}}
    end

    test "starts and stops as an opt-in pure SSH transport" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, {:elixir, pid} = ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      assert Process.alive?(pid)

      assert {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      assert {:ok, "SSH-2.0-sftpd-elixir\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
      assert :ok = :gen_tcp.send(socket, "SSH-2.0-test-client\r\n")
      assert {:ok, packet} = :gen_tcp.recv(socket, 0, 1_000)
      assert {:ok, <<20, _rest::binary>> = kexinit, ""} = Sftpd.SSH.Packet.decode_clear(packet)
      assert {:ok, parsed} = Sftpd.SSH.Algorithms.decode_kexinit(kexinit)
      assert "curve25519-sha256" in parsed.kex_algorithms
      assert ["aes256-gcm@openssh.com" | _] = parsed.encryption_algorithms_server_to_client

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
      assert {:ok, signature_blob, ""} = Sftpd.SSH.Wire.take_string(reply)
      assert byte_size(server_public) == 32
      assert {:ok, "ssh-ed25519", host_key_rest} = Sftpd.SSH.Wire.take_string(host_key_blob)
      assert {:ok, public_key, ""} = Sftpd.SSH.Wire.take_string(host_key_rest)
      assert byte_size(public_key) == 32
      assert {:ok, "ssh-ed25519", signature_rest} = Sftpd.SSH.Wire.take_string(signature_blob)
      assert {:ok, signature, ""} = Sftpd.SSH.Wire.take_string(signature_rest)
      assert byte_size(signature) == 64
      assert {:ok, <<21>>, _rest} = recv_clear_packet(socket, rest)

      {:ok, shared_secret} = Sftpd.SSH.Kex.shared_secret(server_public, client_private)

      exchange_hash =
        Sftpd.SSH.Kex.exchange_hash(%{
          client_version: "SSH-2.0-test-client",
          server_version: "SSH-2.0-sftpd-elixir",
          client_kexinit: client_kexinit,
          server_kexinit: kexinit,
          host_key_blob: host_key_blob,
          client_public: client_public,
          server_public: server_public,
          shared_secret: shared_secret
        })

      assert Sftpd.SSH.Keys.verify_signature(
               %{
                 private_key:
                   {:ECPrivateKey, 1, <<>>, {:namedCurve, {1, 3, 101, 112}}, public_key,
                    :asn1_NOVALUE}
               },
               exchange_hash,
               signature
             )

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
      {c2s, s2c} = assert_encrypted_exchange(socket, c2s, s2c)
      {_c2s, _s2c} = assert_encrypted_sftp_init(socket, c2s, s2c)
      :gen_tcp.close(socket)

      assert :ok = Sftpd.stop_server(ref)
      refute Process.alive?(pid)
    end

    test "replenishes the SSH channel window during uploads" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      assert {:ok, conn} =
               :ssh.connect(~c"127.0.0.1", port,
                 silently_accept_hosts: true,
                 user: ~c"user",
                 password: ~c"password",
                 user_interaction: false,
                 preferred_algorithms: [cipher: [:"aes256-gcm@openssh.com"]]
               )

      assert {:ok, channel} = :ssh_sftp.start_channel(conn)

      payload = :binary.copy(<<0>>, 3 * 1024 * 1024)
      assert :ok = :ssh_sftp.write_file(channel, ~c"/large-upload.bin", payload)
      assert {:ok, info} = :ssh_sftp.read_file_info(channel, ~c"/large-upload.bin")
      assert elem(info, 1) == byte_size(payload)

      :ssh_sftp.stop_channel(channel)
      :ssh.close(conn)
    end

    test "queues download responses until the client extends the channel window" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()
      content = :binary.copy("0123456789abcdef", 16)

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [
                   files: %{
                     "large.bin" => %{content: content, mtime: NaiveDateTime.utc_now()}
                   }
                 ],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      %{
        socket: socket,
        c2s: c2s,
        s2c: s2c,
        client_channel: client_channel,
        server_channel: server_channel
      } = open_raw_authenticated_session(port, client_window: 128)

      {c2s, s2c, buffer} = start_raw_sftp(socket, c2s, s2c, client_channel, server_channel)

      open_packet = [
        <<3, 1::32>>,
        Sftpd.SSH.Wire.string("/large.bin"),
        <<1::32>>,
        <<0::32>>
      ]

      {packet, c2s} = encrypt_client_channel_data(c2s, server_channel, open_packet)
      assert :ok = :gen_tcp.send(socket, packet)

      assert {:ok, <<93, ^client_channel::32, _bytes::32>>, s2c, buffer} =
               recv_encrypted_server_packet_with_rest(socket, s2c, buffer)

      assert {:ok, <<94, ^client_channel::32, rest::binary>>, s2c, buffer} =
               recv_encrypted_server_packet_with_rest(socket, s2c, buffer)

      assert {:ok, sftp_response, ""} = Sftpd.SSH.Wire.take_string(rest)

      assert <<_len::32, 102, 1::32, handle_len::32, handle::binary-size(handle_len)>> =
               sftp_response

      read_len = byte_size(content)

      read_packet = [
        <<5, 2::32>>,
        Sftpd.SSH.Wire.string(handle),
        <<0::64, read_len::32>>
      ]

      {packet, c2s} = encrypt_client_channel_data(c2s, server_channel, read_packet)
      assert :ok = :gen_tcp.send(socket, packet)

      assert {:ok, <<93, ^client_channel::32, _bytes::32>>, s2c, buffer} =
               recv_encrypted_server_packet_with_rest(socket, s2c, buffer)

      assert {:ok, <<94, ^client_channel::32, rest::binary>>, s2c, buffer} =
               recv_encrypted_server_packet_with_rest(socket, s2c, buffer)

      assert {:ok, partial_response, ""} = Sftpd.SSH.Wire.take_string(rest)
      assert byte_size(partial_response) > 0
      assert byte_size(partial_response) < read_len + 13
      assert partial_response != content

      window_bytes = read_len + 64 - byte_size(partial_response)
      {packet, _c2s} = encrypt_client_packet(c2s, <<93, server_channel::32, window_bytes::32>>)

      assert :ok = :gen_tcp.send(socket, packet)

      assert {:ok, <<94, ^client_channel::32, rest::binary>>, _s2c, _buffer} =
               recv_encrypted_server_packet_with_rest(socket, s2c, buffer)

      assert {:ok, response_tail, ""} = Sftpd.SSH.Wire.take_string(rest)
      sftp_response = partial_response <> response_tail
      assert <<_len::32, 103, 2::32, size::32, data::binary-size(size)>> = sftp_response
      assert data == content
    end

    test "supports common SFTP v3 memory operations through the Erlang client" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      assert {:ok, conn} = connect_elixir_ssh(port)
      assert {:ok, channel} = :ssh_sftp.start_channel(conn)

      assert {:ok, listing} = :ssh_sftp.list_dir(channel, ~c"/")
      assert ~c"." in listing
      assert ~c".." in listing

      assert :ok = :ssh_sftp.make_dir(channel, ~c"/dir")
      assert :ok = :ssh_sftp.write_file(channel, ~c"/dir/file.txt", "hello")
      assert {:ok, "hello"} = :ssh_sftp.read_file(channel, ~c"/dir/file.txt")

      assert {:ok, info} = :ssh_sftp.read_file_info(channel, ~c"/dir/file.txt")
      assert elem(info, 1) == 5

      assert :ok = :ssh_sftp.rename(channel, ~c"/dir/file.txt", ~c"/dir/renamed.txt")
      assert {:error, :no_such_file} = :ssh_sftp.read_file(channel, ~c"/dir/file.txt")
      assert {:ok, "hello"} = :ssh_sftp.read_file(channel, ~c"/dir/renamed.txt")

      assert :ok = :ssh_sftp.delete(channel, ~c"/dir/renamed.txt")
      assert :ok = :ssh_sftp.del_dir(channel, ~c"/dir")

      :ssh_sftp.stop_channel(channel)
      :ssh.close(conn)
    end

    test "supports OpenSSH sftp public-key upload and download" do
      sftp = System.find_executable("sftp") || flunk("OpenSSH sftp executable not found")
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      tmp =
        Path.join(System.tmp_dir!(), "sftpd_openssh_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      key_path = Path.join(tmp, "id_ed25519")
      make_ed25519_key!(key_path)
      fingerprint = public_key_fingerprint!(key_path <> ".pub")

      upload_path = Path.join(tmp, "upload.bin")
      download_path = Path.join(tmp, "download.bin")
      payload = :binary.copy(:crypto.strong_rand_bytes(1024), 1024)
      File.write!(upload_path, payload)

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {CustomAuth, fingerprint: fingerprint}
               )

      on_exit(fn ->
        Sftpd.stop_server(ref)
        File.rm_rf(tmp)
      end)

      batch = Path.join(tmp, "batch")
      File.write!(batch, "put #{upload_path} /bench.bin\nget /bench.bin #{download_path}\n")

      args = [
        "-vvv",
        "-B",
        Integer.to_string(@openssh_sftp_block_size),
        "-R",
        "64",
        "-b",
        batch,
        "-P",
        Integer.to_string(port),
        "-c",
        "aes256-gcm@openssh.com",
        "-i",
        key_path,
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "IdentitiesOnly=yes",
        "key-user@127.0.0.1"
      ]

      assert {openssh_output, 0} = System.cmd(sftp, args, stderr_to_stdout: true)
      assert openssh_output =~ "debug1:"
      assert File.read!(download_path) == payload
    end

    test "keeps OpenSSH sftp sessions open across idle gaps" do
      sftp = System.find_executable("sftp") || flunk("OpenSSH sftp executable not found")
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      tmp =
        Path.join(System.tmp_dir!(), "sftpd_openssh_idle_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      key_path = Path.join(tmp, "id_ed25519")
      make_ed25519_key!(key_path)
      fingerprint = public_key_fingerprint!(key_path <> ".pub")

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {CustomAuth, fingerprint: fingerprint}
               )

      on_exit(fn ->
        Sftpd.stop_server(ref)
        File.rm_rf(tmp)
      end)

      args = [
        "-vvv",
        "-B",
        Integer.to_string(@openssh_sftp_block_size),
        "-R",
        "64",
        "-b",
        "-",
        "-P",
        Integer.to_string(port),
        "-c",
        "aes256-gcm@openssh.com",
        "-i",
        key_path,
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "IdentitiesOnly=yes",
        "key-user@127.0.0.1"
      ]

      port =
        Port.open({:spawn_executable, sftp}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args
        ])

      Port.command(port, "ls /\n")
      Process.sleep(6_000)
      Port.command(port, "ls /\nquit\n")

      assert {output, 0} = collect_port_exit(port, "", 10_000)
      assert output =~ "debug1:"
      refute output =~ "Connection closed"
    end

    test "rejects shell and exec channel requests" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      %{
        socket: socket,
        c2s: c2s,
        s2c: s2c,
        client_channel: client_channel,
        server_channel: server_channel
      } = open_raw_authenticated_session(port)

      {packet, c2s} =
        encrypt_client_packet(c2s, [
          <<98, server_channel::32>>,
          Sftpd.SSH.Wire.string("shell"),
          Sftpd.SSH.Wire.boolean(true)
        ])

      assert :ok = :gen_tcp.send(socket, packet)
      assert {:ok, <<100, ^client_channel::32>>, s2c} = recv_encrypted_server_packet(socket, s2c)

      {packet, _c2s} =
        encrypt_client_packet(c2s, [
          <<98, server_channel::32>>,
          Sftpd.SSH.Wire.string("exec"),
          Sftpd.SSH.Wire.boolean(true),
          Sftpd.SSH.Wire.string("echo nope")
        ])

      assert :ok = :gen_tcp.send(socket, packet)

      assert {:ok, <<100, ^client_channel::32>>, _s2c} =
               recv_encrypted_server_packet(socket, s2c)

      :gen_tcp.close(socket)
    end

    test "rejects global requests that ask for a reply" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      %{socket: socket, c2s: c2s, s2c: s2c} = open_raw_authenticated_session(port)

      {packet, _c2s} =
        encrypt_client_packet(c2s, [
          <<80>>,
          Sftpd.SSH.Wire.string("keepalive@openssh.com"),
          Sftpd.SSH.Wire.boolean(true)
        ])

      assert :ok = :gen_tcp.send(socket, packet)
      assert {:ok, <<82>>, _s2c} = recv_encrypted_server_packet(socket, s2c)

      :gen_tcp.close(socket)
    end

    test "disconnects on encrypted rekey requests" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      %{socket: socket, c2s: c2s, s2c: s2c} = open_raw_authenticated_session(port)

      {packet, _c2s} = encrypt_client_packet(c2s, <<20, 0::128, 0::32>>)

      assert :ok = :gen_tcp.send(socket, packet)
      assert {:ok, <<1, 3::32, _rest::binary>>, _s2c} = recv_encrypted_server_packet(socket, s2c)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    end

    test "disconnects on invalid encrypted packet lengths" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      %{socket: socket} = open_raw_authenticated_session(port)

      assert :ok = :gen_tcp.send(socket, <<0::32>>)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    end

    test "disconnects after repeated failed userauth requests" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      %{socket: socket, c2s: c2s, s2c: s2c} = open_raw_userauth_session(port)

      {c2s, s2c} =
        Enum.reduce(1..5, {c2s, s2c}, fn _attempt, {c2s, s2c} ->
          {packet, c2s} = encrypt_client_password_auth(c2s, "user", "wrong")
          assert :ok = :gen_tcp.send(socket, packet)
          assert {:ok, <<51, _rest::binary>>, s2c} = recv_encrypted_server_packet(socket, s2c)
          {c2s, s2c}
        end)

      {packet, _c2s} = encrypt_client_password_auth(c2s, "user", "wrong")
      assert :ok = :gen_tcp.send(socket, packet)
      assert {:ok, <<1, 14::32, _rest::binary>>, _s2c} = recv_encrypted_server_packet(socket, s2c)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    end

    test "acknowledges channel close and ignores later messages for that channel" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      %{
        socket: socket,
        c2s: c2s,
        s2c: s2c,
        client_channel: client_channel,
        server_channel: server_channel
      } = open_raw_authenticated_session(port)

      {packet, c2s} = encrypt_client_packet(c2s, <<97, server_channel::32>>)
      assert :ok = :gen_tcp.send(socket, packet)
      assert {:ok, <<97, ^client_channel::32>>, _s2c} = recv_encrypted_server_packet(socket, s2c)

      {packet, _c2s} =
        encrypt_client_packet(c2s, [
          <<98, server_channel::32>>,
          Sftpd.SSH.Wire.string("shell"),
          Sftpd.SSH.Wire.boolean(true)
        ])

      assert :ok = :gen_tcp.send(socket, packet)
      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)

      :gen_tcp.close(socket)
    end

    test "notifies the profile owner when pure transport accepts a connection" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert Process.whereis(:sftpd_profile_owner) == nil
      Process.register(self(), :sftpd_profile_owner)

      on_exit(fn ->
        if Process.whereis(:sftpd_profile_owner) == self() do
          Process.unregister(:sftpd_profile_owner)
        end
      end)

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      %{socket: socket} = open_raw_authenticated_session(port)

      assert_receive {:sftpd_connection, pid}
      assert is_pid(pid)

      :gen_tcp.close(socket)
    end

    test "stops active pure transport connections with the listener" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      %{socket: socket} = open_raw_authenticated_session(port)

      assert :ok = Sftpd.stop_server(ref)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    end

    test "refuses new clients when max_sessions is exhausted" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]},
                 max_sessions: 0
               )

      on_exit(fn -> Sftpd.stop_server(ref) end)

      assert {:ok, socket} =
               :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    end

    test "rejects modules that do not implement the backend contract" do
      assert {:error, {:unsupported_backend, NonMemoryBackend}} =
               Sftpd.start_server(
                 port: 20_000 + :rand.uniform(10_000),
                 transport: :elixir,
                 backend: NonMemoryBackend,
                 backend_opts: [],
                 system_dir: "/tmp",
                 auth: {:passwords, [{"user", "password"}]}
               )
    end

    test "accepts non-memory modules that implement the backend contract" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, {:elixir, pid} = ref} =
               Sftpd.start_server(
                 port: port,
                 transport: :elixir,
                 backend: SessionBackend,
                 backend_opts: [test_pid: self()],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      assert Process.alive?(pid)
      assert :ok = Sftpd.stop_server(ref)
      refute Process.alive?(pid)
    end
  end

  describe "authentication API" do
    test "passing legacy users returns a clear error" do
      assert {:error, {:deprecated_option, :users}} =
               Sftpd.start_server(
                 backend: Sftpd.Backends.Memory,
                 system_dir: "/tmp",
                 users: [{"testuser", "testpass"}]
               )
    end

    test "missing auth returns a startup error" do
      assert {:error, {:missing_option, :auth}} =
               Sftpd.start_server(
                 backend: Sftpd.Backends.Memory,
                 system_dir: "/tmp"
               )
    end

    test "malformed static password auth lists return a startup error" do
      assert {:error, {:invalid_option, :auth}} =
               Sftpd.start_server(
                 backend: Sftpd.Backends.Memory,
                 system_dir: "/tmp",
                 auth: {:passwords, ["testuser"]}
               )
    end

    test "custom auth modules without password callback return a startup error" do
      assert {:error, {:invalid_option, :auth}} =
               Sftpd.start_server(
                 backend: Sftpd.Backends.Memory,
                 system_dir: "/tmp",
                 auth: {MissingPasswordCallbackAuth, []}
               )
    end

    test "custom auth modules with password callback pass startup validation" do
      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {CustomAuth, [tenant_id: 123]}
               )

      on_exit(fn -> :ssh.stop_daemon(ref) end)
    end

    test "auth passwords rejects an invalid password" do
      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      {:ok, ref} =
        Sftpd.start_server(
          port: port,
          backend: Sftpd.Backends.Memory,
          backend_opts: [],
          auth: {:passwords, [{"testuser", "testpass"}]},
          system_dir: system_dir
        )

      on_exit(fn -> :ssh.stop_daemon(ref) end)

      assert {:error, _reason} =
               :ssh.connect(:localhost, port,
                 silently_accept_hosts: true,
                 user: ~c"testuser",
                 password: ~c"wrong"
               )
    end

    test "custom password auth session reaches backend operations" do
      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      {:ok, ref} =
        Sftpd.start_server(
          port: port,
          backend: SessionBackend,
          backend_opts: [test_pid: self()],
          auth: {CustomAuth, [tenant_id: 123]},
          system_dir: system_dir
        )

      {:ok, conn} =
        :ssh.connect(:localhost, port,
          silently_accept_hosts: true,
          user: ~c"tenant-user",
          password: ~c"secret"
        )

      {:ok, channel} = :ssh_sftp.start_channel(conn)

      on_exit(fn ->
        :ssh.close(conn)
        :ssh.stop_daemon(ref)
      end)

      assert {:ok, _listing} = :ssh_sftp.list_dir(channel, ~c"/")

      assert_receive {:backend_session,
                      %{user_id: 123, tenant_id: 123, sftp_prefix: "tenants/123/"}}
    end
  end

  describe "supervision" do
    test "child_spec starts under a supervisor and stops cleanly" do
      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      {:ok, supervisor} =
        Supervisor.start_link(
          [
            {Sftpd,
             port: port,
             backend: Sftpd.Backends.Memory,
             backend_opts: [],
             auth: {:passwords, [{"testuser", "testpass"}]},
             system_dir: system_dir}
          ],
          strategy: :one_for_one
        )

      assert [{_, child, :worker, [Sftpd.Server]}] = Supervisor.which_children(supervisor)
      assert is_pid(child)

      assert :ok = Supervisor.stop(supervisor)

      assert {:error, _reason} =
               :ssh.connect(:localhost, port,
                 silently_accept_hosts: true,
                 user: ~c"testuser",
                 password: ~c"testpass",
                 connect_timeout: 100
               )
    end

    test "supervised child restarts when the SSH daemon exits" do
      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      {:ok, supervisor} =
        Supervisor.start_link(
          [
            {Sftpd,
             port: port,
             backend: Sftpd.Backends.Memory,
             backend_opts: [],
             auth: {:passwords, [{"testuser", "testpass"}]},
             system_dir: system_dir}
          ],
          strategy: :one_for_one
        )

      assert [{_, child, :worker, [Sftpd.Server]}] = Supervisor.which_children(supervisor)
      ref = child |> :sys.get_state() |> Map.fetch!(:ref)
      child_ref = Process.monitor(child)

      assert :ok = Sftpd.stop_server(ref)

      assert_receive {:DOWN, ^child_ref, :process, ^child, reason}
                     when reason in [:normal, :shutdown],
                     1_000

      restarted_child = wait_for_restarted_child(supervisor, child)
      assert is_pid(restarted_child)
      assert restarted_child != child

      assert {:ok, conn} =
               :ssh.connect(:localhost, port,
                 silently_accept_hosts: true,
                 user: ~c"testuser",
                 password: ~c"testpass",
                 connect_timeout: 1_000
               )

      :ssh.close(conn)
      assert :ok = Supervisor.stop(supervisor)
    end

    test "server callback stops on abnormal daemon exits" do
      daemon = self()
      monitor_ref = make_ref()
      state = %{ref: daemon, monitor_ref: monitor_ref, daemon_down?: false}

      assert {:stop, {:ssh_daemon_down, :killed}, %{daemon_down?: true}} =
               Sftpd.Server.handle_info({:DOWN, monitor_ref, :process, daemon, :killed}, state)
    end

    test "server callback preserves normal daemon exit reasons" do
      daemon = self()
      monitor_ref = make_ref()
      state = %{ref: daemon, monitor_ref: monitor_ref, daemon_down?: false}

      assert {:stop, :normal, %{daemon_down?: true}} =
               Sftpd.Server.handle_info({:DOWN, monitor_ref, :process, daemon, :normal}, state)

      assert {:stop, :shutdown, %{daemon_down?: true}} =
               Sftpd.Server.handle_info({:DOWN, monitor_ref, :process, daemon, :shutdown}, state)
    end

    test "server callback ignores unrelated messages" do
      state = %{ref: self(), monitor_ref: make_ref(), daemon_down?: false}

      assert {:noreply, ^state} = Sftpd.Server.handle_info(:ignored, state)
    end

    test "server callback returns start errors from the daemon" do
      previous_trap_exit = Process.flag(:trap_exit, true)

      on_exit(fn ->
        Process.flag(:trap_exit, previous_trap_exit)
      end)

      assert {:error, {:deprecated_option, :users}} =
               Sftpd.Server.start_link(
                 backend: Sftpd.Backends.Memory,
                 system_dir: "/tmp",
                 users: [{"testuser", "testpass"}]
               )
    end

    test "server callback skips stop when daemon already exited" do
      assert :ok = Sftpd.Server.terminate(:shutdown, %{daemon_down?: true})
    end

    test "server callback can monitor pure Elixir transport refs" do
      port = 20_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, pid} =
               Sftpd.Server.start_link(
                 port: port,
                 transport: :elixir,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 system_dir: system_dir,
                 auth: {:passwords, [{"user", "password"}]}
               )

      assert Process.alive?(pid)
      assert :ok = GenServer.stop(pid)
    end

    test "stop_server treats already-shutting-down Elixir transports as stopped" do
      {:ok, pid} = ShutdownOnStopServer.start(self())

      assert :ok = Sftpd.stop_server({:elixir, pid})
      assert_receive :terminating
      refute Process.alive?(pid)
    end

    test "stop_server treats already-exited Elixir transports as stopped" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert :ok = Sftpd.stop_server({:elixir, pid})
    end
  end

  describe "telemetry" do
    test "emits start and stop server events" do
      handler_id =
        TelemetryHelper.attach(self(), [
          [:sftpd, :server, :start],
          [:sftpd, :server, :stop]
        ])

      on_exit(fn -> :telemetry.detach(handler_id) end)

      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               Sftpd.start_server(
                 port: port,
                 backend: Sftpd.Backends.Memory,
                 backend_opts: [],
                 auth: {:passwords, [{"testuser", "testpass"}]},
                 system_dir: system_dir
               )

      assert_receive {:telemetry_event, [:sftpd, :server, :start], start_measurements,
                      start_metadata}

      assert is_integer(start_measurements.duration)
      assert start_metadata.result == :ok
      assert start_metadata.port == port
      assert start_metadata.backend == Sftpd.Backends.Memory
      assert start_metadata.server_ref == ref

      assert :ok = Sftpd.stop_server(ref)

      assert_receive {:telemetry_event, [:sftpd, :server, :stop], stop_measurements,
                      stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.result == :ok
      assert stop_metadata.server_ref == ref
    end
  end

  describe "fast module backend" do
    setup do
      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      {:ok, ref} =
        Sftpd.start_server(
          port: port,
          backend: Sftpd.Backends.Memory,
          backend_opts: [],
          auth: {:passwords, [{"testuser", "testpass"}]},
          system_dir: system_dir
        )

      {:ok, conn} = :ssh.connect(:localhost, port, @client_opts)
      {:ok, channel} = :ssh_sftp.start_channel(conn)

      on_exit(fn ->
        :ssh.close(conn)
        :ssh.stop_daemon(ref)
      end)

      %{channel: channel}
    end

    test "list_dir on root works", %{channel: ch} do
      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/")
      assert ~c"." in listing
      assert ~c".." in listing
    end

    test "make_dir and list_dir work", %{channel: ch} do
      assert :ok = :ssh_sftp.make_dir(ch, ~c"/gsdir")
      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/")
      assert ~c"gsdir" in listing
    end

    test "write and read file works", %{channel: ch} do
      content = "genserver file content"

      assert {:ok, handle} = :ssh_sftp.open(ch, ~c"/gs_file.txt", [:write])
      assert :ok = :ssh_sftp.write(ch, handle, content)
      assert :ok = :ssh_sftp.close(ch, handle)

      assert {:ok, handle} = :ssh_sftp.open(ch, ~c"/gs_file.txt", [:read])
      assert {:ok, read_content} = :ssh_sftp.read(ch, handle, byte_size(content))
      assert to_string(read_content) == content
      assert :ok = :ssh_sftp.close(ch, handle)
    end

    test "backend receives authenticated session" do
      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      {:ok, ref} =
        Sftpd.start_server(
          port: port,
          backend: SessionBackend,
          backend_opts: [test_pid: self()],
          auth: {CustomAuth, tenant_id: "tenant-123"},
          system_dir: system_dir
        )

      client_opts = [
        silently_accept_hosts: true,
        user: ~c"tenant-user",
        password: ~c"secret"
      ]

      {:ok, conn} = :ssh.connect(:localhost, port, client_opts)
      {:ok, channel} = :ssh_sftp.start_channel(conn)

      on_exit(fn ->
        :ssh.close(conn)
        :ssh.stop_daemon(ref)
      end)

      assert {:ok, listing} = :ssh_sftp.list_dir(channel, ~c"/")
      assert ~c"." in listing
      assert_receive {:backend_session, %{tenant_id: "tenant-123"}}, 1_000
    end
  end

  defp wait_for_restarted_child(supervisor, old_child, attempts_remaining \\ 50)

  defp wait_for_restarted_child(supervisor, old_child, attempts_remaining)
       when attempts_remaining > 0 do
    case Supervisor.which_children(supervisor) do
      [{_, child, :worker, [Sftpd.Server]}] when is_pid(child) and child != old_child ->
        child

      _other ->
        Process.sleep(100)
        wait_for_restarted_child(supervisor, old_child, attempts_remaining - 1)
    end
  end

  defp wait_for_restarted_child(supervisor, old_child, 0) do
    assert [{_, child, :worker, [Sftpd.Server]}] = Supervisor.which_children(supervisor)
    refute child == old_child
    child
  end

  defp connect_elixir_ssh(port) do
    :ssh.connect(~c"127.0.0.1", port,
      silently_accept_hosts: true,
      user: ~c"user",
      password: ~c"password",
      user_interaction: false,
      preferred_algorithms: [cipher: [:"aes256-gcm@openssh.com"]]
    )
  end

  defp make_ed25519_key!(path) do
    {_, 0} =
      System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path],
        stderr_to_stdout: true
      )
  end

  defp public_key_fingerprint!(pub_path) do
    {:ok, public_key} = pub_path |> File.read!() |> Sftpd.Auth.decode_authorized_key()
    Sftpd.Auth.fingerprint(public_key)
  end

  defp collect_port_exit(port, output, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port_exit(port, output <> data, timeout)

      {^port, {:exit_status, status}} ->
        {output, status}
    after
      timeout ->
        Port.close(port)
        flunk("timed out waiting for sftp to exit; output: #{output}")
    end
  end

  defp open_raw_authenticated_session(port, opts \\ []) do
    %{socket: socket, c2s: c2s, s2c: s2c} = open_raw_userauth_session(port)
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
      client_channel: client_channel,
      server_channel: server_channel
    }
  end

  defp open_raw_userauth_session(port) do
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
    %{socket: socket, c2s: c2s, s2c: s2c}
  end

  defp start_raw_sftp(socket, c2s, s2c, client_channel, server_channel) do
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

    assert {:ok, <<93, ^client_channel::32, bytes::32>>, s2c, buffer} =
             recv_encrypted_server_packet_with_rest(socket, s2c, "")

    assert bytes == byte_size(sftp_init)

    assert {:ok, <<94, ^client_channel::32, rest::binary>>, s2c, buffer} =
             recv_encrypted_server_packet_with_rest(socket, s2c, buffer)

    assert {:ok, sftp_response, ""} = Sftpd.SSH.Wire.take_string(rest)
    assert <<5::32, 2, 3::32>> = sftp_response

    {c2s, s2c, buffer}
  end

  defp recv_clear_packet(socket, buffer) do
    case Sftpd.SSH.Packet.decode_clear(buffer) do
      {:ok, payload, rest} ->
        {:ok, payload, rest}

      :more ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
        recv_clear_packet(socket, buffer <> data)
    end
  end

  defp assert_encrypted_exchange(socket, c2s, s2c) do
    {c2s, s2c} = assert_service_accept(socket, c2s, s2c)
    assert_password_auth_success(socket, c2s, s2c)
  end

  defp assert_service_accept(socket, c2s, s2c) do
    {packet, c2s} =
      encrypt_client_packet(c2s, [<<5>>, Sftpd.SSH.Wire.string("ssh-userauth")])

    assert :ok = :gen_tcp.send(socket, packet)
    assert {:ok, <<6, rest::binary>>, s2c} = recv_encrypted_server_packet(socket, s2c)
    assert {:ok, "ssh-userauth", ""} = Sftpd.SSH.Wire.take_string(rest)
    {c2s, s2c}
  end

  defp assert_password_auth_success(socket, c2s, s2c) do
    {packet, c2s} = encrypt_client_password_auth(c2s, "user", "password")

    assert :ok = :gen_tcp.send(socket, packet)
    assert {:ok, <<52>>, s2c} = recv_encrypted_server_packet(socket, s2c)
    {c2s, s2c}
  end

  defp encrypt_client_password_auth(cipher, username, password) do
    encrypt_client_packet(cipher, [
      <<50>>,
      Sftpd.SSH.Wire.string(username),
      Sftpd.SSH.Wire.string("ssh-connection"),
      Sftpd.SSH.Wire.string("password"),
      Sftpd.SSH.Wire.boolean(false),
      Sftpd.SSH.Wire.string(password)
    ])
  end

  defp assert_encrypted_sftp_init(socket, c2s, s2c) do
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

    assert {:ok, <<93, ^client_channel::32, bytes::32>>, s2c, buffer} =
             recv_encrypted_server_packet_with_rest(socket, s2c, "")

    assert bytes == byte_size(sftp_init)

    assert {:ok, <<94, ^client_channel::32, rest::binary>>, s2c, _buffer} =
             recv_encrypted_server_packet_with_rest(socket, s2c, buffer)

    assert {:ok, sftp_response, ""} = Sftpd.SSH.Wire.take_string(rest)
    assert <<5::32, 2, 3::32>> = sftp_response

    {c2s, s2c}
  end

  defp encrypt_client_packet(cipher, payload) do
    {packet, cipher} =
      Sftpd.SSH.Cipher.encrypt_packet(
        cipher,
        Sftpd.SSH.Packet.encode_aead_packet(payload, Sftpd.SSH.Cipher.block_size(cipher))
      )

    {IO.iodata_to_binary(packet), cipher}
  end

  defp encrypt_client_channel_data(cipher, server_channel, sftp_payload) do
    len = IO.iodata_length(sftp_payload)

    encrypt_client_packet(cipher, [
      <<94, server_channel::32>>,
      Sftpd.SSH.Wire.string([<<len::32>>, sftp_payload])
    ])
  end

  defp recv_encrypted_server_packet(socket, cipher, buffer \\ "") do
    {:ok, payload, cipher, _rest} = recv_encrypted_server_packet_with_rest(socket, cipher, buffer)
    {:ok, payload, cipher}
  end

  defp recv_encrypted_server_packet_with_rest(socket, cipher, buffer) do
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
