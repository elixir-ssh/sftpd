defmodule Sftpd.FileHandlerTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Sftpd.FileHandler
  alias Sftpd.Test.TelemetryHelper

  @state %{backend: nil, backend_state: nil}

  defmodule MockBackend do
    def read_file(_path, _state), do: {:ok, "content"}
    def list_dir(_path, _state), do: {:ok, [~c".", ~c"..", ~c"entry"]}
    def make_dir(_path, _state), do: :ok
    def del_dir(_path, _state), do: :ok
    def delete(_path, _state), do: :ok
    def rename(_src, _dst, _state), do: :ok

    def file_info(~c"/dir", _state),
      do: {:ok, {:file_info, 4096, :directory, :read, {}, {}, {}, 0, 0, 0, 0, 0, 0, 0}}

    def file_info(~c"/file", _state),
      do: {:ok, {:file_info, 3, :regular, :read_write, {}, {}, {}, 0, 0, 0, 0, 0, 0, 0}}

    def file_info(_path, _state), do: {:error, :enoent}
  end

  defmodule ReadErrorBackend do
    def read_file(_path, _state), do: {:error, :enoent}
  end

  defmodule HangingOpenBackend do
    def read_file(_path, %{test_pid: test_pid}) do
      send(test_pid, {:open_started, self()})
      Process.sleep(:infinity)
    end
  end

  defmodule SlowCloseDevice do
    use GenServer

    def start, do: GenServer.start(__MODULE__, [])

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_call(:close, _from, state) do
      Process.sleep(50)
      {:stop, :normal, :ok, state}
    end
  end

  defmodule HangingCloseDevice do
    use GenServer

    def start, do: GenServer.start(__MODULE__, [])

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_call(:close, _from, state) do
      Process.sleep(:infinity)
      {:reply, :ok, state}
    end
  end

  defmodule ControlledCloseDevice do
    use GenServer

    def start(test_pid, release_delay \\ nil),
      do: GenServer.start(__MODULE__, {test_pid, release_delay})

    @impl true
    def init({test_pid, release_delay}),
      do: {:ok, %{test_pid: test_pid, release_delay: release_delay}}

    @impl true
    def handle_call(:close, _from, state) do
      if state.release_delay do
        Process.send_after(self(), :release_close, state.release_delay)
      end

      receive do
        :release_close -> {:stop, :normal, :ok, state}
      end
    end
  end

  describe "make_symlink/3" do
    test "always returns enotsup" do
      assert {{:error, :enotsup}, _state} =
               FileHandler.make_symlink(~c"/src", ~c"/dst", @state)
    end
  end

  describe "read_link/2" do
    test "always returns einval" do
      assert {{:error, :einval}, _state} = FileHandler.read_link(~c"/path", @state)
    end
  end

  describe "write_file_info/3" do
    test "always returns ok" do
      assert {:ok, _state} = FileHandler.write_file_info(~c"/path", {}, @state)
    end
  end

  describe "get_cwd/1" do
    test "returns '/' and sets cwd when no cwd in state" do
      {{:ok, cwd}, new_state} = FileHandler.get_cwd(@state)
      assert cwd == ~c"/"
      assert new_state.cwd == ~c"/"
    end

    test "returns existing cwd when present" do
      state = Map.put(@state, :cwd, ~c"/home/user")
      {{:ok, cwd}, _new_state} = FileHandler.get_cwd(state)
      assert cwd == ~c"/home/user"
    end

    test "emits telemetry for cwd lookups" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :sftp, :get_cwd]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      {{:ok, cwd}, _new_state} = FileHandler.get_cwd(@state)

      assert cwd == ~c"/"
      assert_receive {:telemetry_event, [:sftpd, :sftp, :get_cwd], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.result == :ok
      assert metadata.backend_kind == :module
    end
  end

  describe "open/3" do
    test "falls back to read mode when no modes specified" do
      state = %{backend: MockBackend, backend_state: %{}}
      {{:ok, pid}, _state} = FileHandler.open(~c"/file.txt", [], state)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "returns read setup errors before issuing a handle" do
      state = %{backend: ReadErrorBackend, backend_state: %{}}

      assert {{:error, :enoent}, ^state} = FileHandler.open(~c"/missing.txt", [:read], state)
    end

    test "returns timeout when read setup hangs before issuing a handle" do
      state = %{
        backend: HangingOpenBackend,
        backend_state: %{test_pid: self()},
        open_timeout: 10
      }

      log =
        capture_log(fn ->
          assert {{:error, :timeout}, ^state} = FileHandler.open(~c"/stuck.txt", [:read], state)
        end)

      assert_receive {:open_started, pid}, 1000
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000
      assert log =~ "Timed out waiting 10ms"
    end

    test "emits telemetry for open" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :sftp, :open]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      state = %{backend: MockBackend, backend_state: %{}}
      {{:ok, pid}, _state} = FileHandler.open(~c"/file.txt", [], state)

      assert_receive {:telemetry_event, [:sftpd, :sftp, :open], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.result == :ok
      assert metadata.mode == :read
      assert metadata.path == "/file.txt"
      assert metadata.backend == MockBackend
      assert metadata.open_timeout == 30_000

      GenServer.stop(pid)
    end
  end

  describe "path operation telemetry" do
    test "emits telemetry for backend path operations" do
      handler_id =
        TelemetryHelper.attach(self(), [
          [:sftpd, :sftp, :list_dir],
          [:sftpd, :sftp, :make_dir],
          [:sftpd, :sftp, :delete],
          [:sftpd, :sftp, :rename]
        ])

      on_exit(fn -> :telemetry.detach(handler_id) end)

      state = %{backend: MockBackend, backend_state: %{}}

      assert {{:ok, [~c".", ~c"..", ~c"entry"]}, ^state} = FileHandler.list_dir(~c"/items", state)
      assert {:ok, ^state} = FileHandler.make_dir(~c"/items", state)
      assert {:ok, ^state} = FileHandler.delete(~c"/items/file.txt", state)
      assert {:ok, ^state} = FileHandler.rename(~c"/old.txt", ~c"/new.txt", state)

      assert_receive {:telemetry_event, [:sftpd, :sftp, :list_dir], list_measurements,
                      list_metadata}

      assert is_integer(list_measurements.duration)
      assert list_metadata.path == "/items"
      assert list_metadata.result == :ok

      assert_receive {:telemetry_event, [:sftpd, :sftp, :make_dir], make_measurements,
                      make_metadata}

      assert is_integer(make_measurements.duration)
      assert make_metadata.path == "/items"
      assert make_metadata.result == :ok

      assert_receive {:telemetry_event, [:sftpd, :sftp, :delete], delete_measurements,
                      delete_metadata}

      assert is_integer(delete_measurements.duration)
      assert delete_metadata.path == "/items/file.txt"
      assert delete_metadata.result == :ok

      assert_receive {:telemetry_event, [:sftpd, :sftp, :rename], rename_measurements,
                      rename_metadata}

      assert is_integer(rename_measurements.duration)
      assert rename_metadata.src_path == "/old.txt"
      assert rename_metadata.dst_path == "/new.txt"
      assert rename_metadata.result == :ok
    end

    test "emits only a read_file_info event for file info lookups" do
      handler_id =
        TelemetryHelper.attach(self(), [
          [:sftpd, :sftp, :read_file_info],
          [:sftpd, :sftp, :read_link_info]
        ])

      on_exit(fn -> :telemetry.detach(handler_id) end)

      state = %{backend: MockBackend, backend_state: %{}}

      assert {{:ok, {:file_info, 3, :regular, :read_write, {}, {}, {}, 0, 0, 0, 0, 0, 0, 0}},
              ^state} = FileHandler.read_file_info(~c"/file", state)

      assert_receive {:telemetry_event, [:sftpd, :sftp, :read_file_info], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.path == "/file"
      assert metadata.result == :ok
      refute_receive {:telemetry_event, [:sftpd, :sftp, :read_link_info], _, _}
    end

    test "emits telemetry for directory checks" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :sftp, :is_dir]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      state = %{backend: MockBackend, backend_state: %{}}

      assert {true, ^state} = FileHandler.is_dir(~c"/dir", state)
      assert_receive {:telemetry_event, [:sftpd, :sftp, :is_dir], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.path == "/dir"
      assert metadata.result == :directory

      assert {false, ^state} = FileHandler.is_dir(~c"/missing", state)
      assert_receive {:telemetry_event, [:sftpd, :sftp, :is_dir], _, metadata}
      assert metadata.path == "/missing"
      assert metadata.result == :not_directory
    end
  end

  describe "close/2" do
    property "timed-out close can still finish cleanly within the cleanup grace" do
      check all(release_delay <- integer(25..50), max_runs: 10) do
        {:ok, pid} = ControlledCloseDevice.start(self(), release_delay)
        ref = Process.monitor(pid)

        capture_log(fn ->
          assert {{:error, :timeout}, _state} =
                   FileHandler.close(pid, %{
                     backend: nil,
                     backend_state: nil,
                     close_timeout: 1,
                     close_shutdown_grace: release_delay + 100
                   })
        end)

        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      end
    end

    test "returns timeout but allows a slow close to clean up during the grace window" do
      {:ok, pid} = ControlledCloseDevice.start(self(), 50)
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          assert {{:error, :timeout}, _state} =
                   FileHandler.close(pid, %{
                     backend: nil,
                     backend_state: nil,
                     close_timeout: 10,
                     close_shutdown_grace: 200
                   })
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      assert log =~ "Timed out waiting 10ms"
    end

    test "does not leave late close replies in the caller mailbox after timeout" do
      {:ok, pid} = SlowCloseDevice.start()
      ref = Process.monitor(pid)

      capture_log(fn ->
        assert {{:error, :timeout}, _state} =
                 FileHandler.close(pid, %{
                   backend: nil,
                   backend_state: nil,
                   close_timeout: 10,
                   close_shutdown_grace: 200
                 })
      end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      Process.sleep(100)
      refute_received {_tag, :ok}
      refute_received {:ok, _}
    end

    test "kills the device when cleanup grace also expires" do
      {:ok, pid} = HangingCloseDevice.start()
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          assert {{:error, :timeout}, _state} =
                   FileHandler.close(pid, %{
                     backend: nil,
                     backend_state: nil,
                     close_timeout: 10,
                     close_shutdown_grace: 10
                   })
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
      assert log =~ "did not close within 10ms cleanup grace"
    end

    test "emits telemetry for close timeouts" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :sftp, :close]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, pid} = HangingCloseDevice.start()

      capture_log(fn ->
        assert {{:error, :timeout}, _state} =
                 FileHandler.close(pid, %{
                   backend: nil,
                   backend_state: nil,
                   close_timeout: 10,
                   close_shutdown_grace: 10
                 })
      end)

      assert_receive {:telemetry_event, [:sftpd, :sftp, :close], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.result == :error
      assert metadata.reason == :timeout
      assert metadata.close_timeout == 10
      assert metadata.close_shutdown_grace == 10
    end
  end
end
