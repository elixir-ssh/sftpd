defmodule SftpdTest do
  use ExUnit.Case, async: false

  alias Sftpd.Test.TelemetryHelper

  @client_opts [
    silently_accept_hosts: true,
    user: ~c"testuser",
    password: ~c"testpass"
  ]

  # GenServer backend that wraps Memory for testing {:genserver, pid} dispatch
  defmodule GenServerBackend do
    use GenServer
    alias Sftpd.Backends.Memory

    def start_link, do: GenServer.start_link(__MODULE__, [])

    def init(_), do: Memory.init([])

    def handle_call({:list_dir, path}, _from, mem_state),
      do: {:reply, Memory.list_dir(path, mem_state), mem_state}

    def handle_call({:file_info, path}, _from, mem_state),
      do: {:reply, Memory.file_info(path, mem_state), mem_state}

    def handle_call({:make_dir, path}, _from, mem_state) do
      :ok = Memory.make_dir(path, mem_state)
      {:reply, :ok, mem_state}
    end

    def handle_call({:del_dir, path}, _from, mem_state),
      do: {:reply, Memory.del_dir(path, mem_state), mem_state}

    def handle_call({:delete, path}, _from, mem_state),
      do: {:reply, Memory.delete(path, mem_state), mem_state}

    def handle_call({:rename, src, dst}, _from, mem_state),
      do: {:reply, Memory.rename(src, dst, mem_state), mem_state}

    def handle_call({:read_file, path}, _from, mem_state),
      do: {:reply, Memory.read_file(path, mem_state), mem_state}

    def handle_call({:write_file, path, content}, _from, mem_state) do
      :ok = Memory.write_file(path, content, mem_state)
      {:reply, :ok, mem_state}
    end
  end

  defmodule SessionGenServerBackend do
    use GenServer
    alias Sftpd.Backends.Memory

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    def init(test_pid) do
      {:ok, mem_state} = Memory.init([])
      {:ok, %{test_pid: test_pid, mem_state: mem_state}}
    end

    def handle_call({:list_dir, path, session}, _from, state) do
      send(state.test_pid, {:session_backend_call, session})
      {:reply, Memory.list_dir(path, state.mem_state), state}
    end

    def handle_call({:file_info, path, _session}, _from, state),
      do: {:reply, Memory.file_info(path, state.mem_state), state}

    def handle_call({:make_dir, path, _session}, _from, state) do
      :ok = Memory.make_dir(path, state.mem_state)
      {:reply, :ok, state}
    end

    def handle_call({:del_dir, path, _session}, _from, state),
      do: {:reply, Memory.del_dir(path, state.mem_state), state}

    def handle_call({:delete, path, _session}, _from, state),
      do: {:reply, Memory.delete(path, state.mem_state), state}

    def handle_call({:rename, src, dst, _session}, _from, state),
      do: {:reply, Memory.rename(src, dst, state.mem_state), state}

    def handle_call({:read_file, path, _session}, _from, state),
      do: {:reply, Memory.read_file(path, state.mem_state), state}

    def handle_call({:write_file, path, content, _session}, _from, state) do
      :ok = Memory.write_file(path, content, state.mem_state)
      {:reply, :ok, state}
    end
  end

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

  defmodule SessionBackend do
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    def list_dir(_path, session, %{test_pid: test_pid}) do
      send(test_pid, {:backend_session, session})
      {:ok, [~c".", ~c".."]}
    end

    def file_info(_path, _state), do: {:ok, Sftpd.Backend.directory_info()}
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

    test "server callback ignores unrelated messages" do
      state = %{ref: self(), monitor_ref: make_ref(), daemon_down?: false}

      assert {:noreply, ^state} = Sftpd.Server.handle_info(:ignored, state)
    end

    test "server callback skips stop when daemon already exited" do
      assert :ok = Sftpd.Server.terminate(:shutdown, %{daemon_down?: true})
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

  describe "genserver backend" do
    setup do
      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      {:ok, server_pid} = GenServerBackend.start_link()

      {:ok, ref} =
        Sftpd.start_server(
          port: port,
          backend: {:genserver, server_pid},
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

    test "session-aware genserver backend receives authenticated session" do
      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      {:ok, server_pid} = SessionGenServerBackend.start_link(self())

      {:ok, ref} =
        Sftpd.start_server(
          port: port,
          backend: {:genserver, server_pid, session: true},
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
      assert_receive {:session_backend_call, %{tenant_id: "tenant-123"}}, 1_000
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
end
