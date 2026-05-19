defmodule Sftpd.IODeviceTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Sftpd.IODevice
  alias Sftpd.FileHandler
  alias Sftpd.Test.TelemetryHelper

  defmodule MockBackend do
    def read_file(_path, %{content: content}), do: {:ok, content}
    def read_file(_path, %{error: reason}), do: {:error, reason}

    def write_file(_path, _content, %{write_error: reason}), do: {:error, reason}

    def write_file(_path, content, state) do
      send(state.test_pid, {:written, content})
      :ok
    end
  end

  defmodule RangeBackend do
    def file_info(_path, %{content: content}) do
      {:ok, Sftpd.Backend.file_info(byte_size(content), {{2024, 1, 1}, {0, 0, 0}})}
    end

    def read_file_range(_path, offset, len, %{content: content}) do
      size = byte_size(content)

      if offset >= size do
        :eof
      else
        bytes_to_read = min(len, size - offset)
        {:ok, binary_part(content, offset, bytes_to_read)}
      end
    end
  end

  defmodule RangeEmptyBackend do
    def file_info(_path, _state),
      do: {:ok, Sftpd.Backend.file_info(10, {{2024, 1, 1}, {0, 0, 0}})}

    def read_file_range(_path, _offset, _len, _state), do: {:ok, <<>>}
  end

  defmodule RangeErrorBackend do
    def file_info(_path, _state),
      do: {:ok, Sftpd.Backend.file_info(10, {{2024, 1, 1}, {0, 0, 0}})}

    def read_file_range(_path, _offset, _len, _state), do: {:error, :eio}
  end

  defmodule RangeStatErrorBackend do
    def file_info(_path, _state), do: {:error, :enoent}
    def read_file_range(_path, _offset, _len, _state), do: {:ok, "unused"}
  end

  defmodule HangingOpenBackend do
    def read_file(_path, %{test_pid: test_pid}) do
      send(test_pid, {:open_started, self()})
      Process.sleep(:infinity)
    end
  end

  defmodule SlowProcessReadBackend do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    def reply(pid, reply), do: GenServer.cast(pid, {:reply_read, reply})

    @impl GenServer
    def init(test_pid), do: {:ok, %{test_pid: test_pid, read_from: nil}}

    @impl GenServer
    def handle_call({:read_file, path}, from, state) do
      send(state.test_pid, {:process_read_opened, self(), path})
      {:noreply, %{state | read_from: from}}
    end

    @impl GenServer
    def handle_cast({:reply_read, reply}, %{read_from: from} = state) do
      GenServer.reply(from, reply)
      {:noreply, %{state | read_from: nil}}
    end
  end

  defmodule CrashingOpenBackend do
    def read_file(_path, _state), do: raise("open failed")
  end

  defmodule StreamingBackend do
    def begin_write(_path, %{test_pid: test_pid}), do: {:ok, %{chunks: [], test_pid: test_pid}}

    def write_chunk(handle, offset, chunk, _state) do
      data = IO.iodata_to_binary(chunk)
      send(handle.test_pid, {:stream_chunk, offset, data})
      {:ok, %{handle | chunks: handle.chunks ++ [{offset, data}]}}
    end

    def finish_write(handle, _state) do
      send(handle.test_pid, {:stream_finish, handle.chunks})
      :ok
    end

    def abort_write(handle, _state) do
      send(handle.test_pid, {:stream_abort, handle.chunks})
      :ok
    end
  end

  defmodule HangingStreamingOpenBackend do
    def begin_write(_path, %{test_pid: test_pid}) do
      send(test_pid, {:stream_open_started, self()})
      Process.sleep(:infinity)
    end

    def write_chunk(handle, _offset, _chunk, _state), do: {:ok, handle}
    def finish_write(_handle, _state), do: :ok
    def abort_write(_handle, _state), do: :ok
  end

  defmodule PartialStreamingBackend do
    def begin_write(_path, %{test_pid: test_pid}), do: {:ok, %{test_pid: test_pid}}

    def write_file(_path, content, %{test_pid: test_pid}) do
      send(test_pid, {:partial_written, content})
      :ok
    end
  end

  defmodule ReplayBackend do
    def begin_write(_path, %{agent: agent, test_pid: test_pid}) do
      Agent.get_and_update(agent, fn attempts ->
        next_attempt = attempts + 1

        result =
          case next_attempt do
            1 -> {:error, :fallback_once}
            _ -> {:ok, %{chunks: [], test_pid: test_pid}}
          end

        {result, next_attempt}
      end)
    end

    def write_chunk(handle, offset, chunk, _state) do
      data = IO.iodata_to_binary(chunk)
      send(handle.test_pid, {:replay_chunk, offset, data})
      {:ok, %{handle | chunks: handle.chunks ++ [{offset, data}]}}
    end

    def finish_write(handle, _state) do
      send(handle.test_pid, {:replay_finish, handle.chunks})
      :ok
    end

    def abort_write(handle, _state) do
      send(handle.test_pid, {:replay_abort, handle.chunks})
      :ok
    end
  end

  defmodule StreamingWriteErrorBackend do
    def begin_write(_path, %{test_pid: test_pid}), do: {:ok, %{test_pid: test_pid}}
    def write_chunk(_handle, _offset, _chunk, _state), do: {:error, :eio}
    def finish_write(_handle, _state), do: :ok
    def abort_write(_handle, _state), do: {:error, :abort_failed}
  end

  defmodule StreamingFinishErrorBackend do
    def begin_write(_path, %{test_pid: test_pid}), do: {:ok, %{chunks: [], test_pid: test_pid}}

    def write_chunk(handle, offset, chunk, _state) do
      data = IO.iodata_to_binary(chunk)
      {:ok, %{handle | chunks: handle.chunks ++ [{offset, data}]}}
    end

    def finish_write(_handle, _state), do: {:error, :eio}

    def abort_write(handle, _state) do
      send(handle.test_pid, {:finish_error_abort, handle.chunks})
      :ok
    end
  end

  defmodule ReplayWriteErrorBackend do
    def begin_write(_path, %{agent: agent, test_pid: test_pid}) do
      Agent.get_and_update(agent, fn attempts ->
        next_attempt = attempts + 1

        result =
          case next_attempt do
            1 -> {:error, :fallback_once}
            _ -> {:ok, %{test_pid: test_pid}}
          end

        {result, next_attempt}
      end)
    end

    def write_chunk(_handle, _offset, _chunk, _state), do: {:error, :eio}
    def finish_write(_handle, _state), do: :ok
    def abort_write(_handle, _state), do: :ok
  end

  defmodule ReplayFinishErrorBackend do
    def begin_write(_path, %{agent: agent, test_pid: test_pid}) do
      Agent.get_and_update(agent, fn attempts ->
        next_attempt = attempts + 1

        result =
          case next_attempt do
            1 -> {:error, :fallback_once}
            _ -> {:ok, %{chunks: [], test_pid: test_pid}}
          end

        {result, next_attempt}
      end)
    end

    def write_chunk(handle, offset, chunk, _state) do
      data = IO.iodata_to_binary(chunk)
      {:ok, %{handle | chunks: handle.chunks ++ [{offset, data}]}}
    end

    def finish_write(_handle, _state), do: {:error, :eio}

    def abort_write(handle, _state) do
      send(handle.test_pid, {:replay_finish_error_abort, handle.chunks})
      :ok
    end
  end

  describe "read mode" do
    property "buffered reads return the original content across arbitrary read sizes" do
      check all(
              content <- binary(max_length: 256),
              lengths <- list_of(integer(1..64), min_length: 1, max_length: 20)
            ) do
        {:ok, pid} =
          IODevice.start(%{
            path: ~c"/test.txt",
            mode: :read,
            backend: MockBackend,
            backend_state: %{content: content}
          })

        data = read_until_eof(pid, lengths ++ [byte_size(content) + 1])
        assert data == content
        assert :eof = GenServer.call(pid, {:read, 1})
        GenServer.stop(pid)
      end
    end

    property "range reads advance by exactly the bytes returned by the backend" do
      check all(
              content <- binary(max_length: 256),
              lengths <- list_of(integer(1..64), min_length: 1, max_length: 20)
            ) do
        {:ok, pid} =
          IODevice.start(%{
            path: ~c"/range.txt",
            mode: :read,
            backend: RangeBackend,
            backend_state: %{content: content}
          })

        data = read_until_eof(pid, lengths ++ [byte_size(content) + 1])
        assert data == content
        assert :eof = GenServer.call(pid, {:read, 1})
        GenServer.stop(pid)
      end
    end

    property "eof-relative read positions are clamped to valid file offsets" do
      check all(
              content <- binary(max_length: 256),
              offset <- integer(-256..0)
            ) do
        {:ok, pid} =
          IODevice.start(%{
            path: ~c"/range.txt",
            mode: :read,
            backend: RangeBackend,
            backend_state: %{content: content}
          })

        expected = max(byte_size(content) + offset, 0)

        if byte_size(content) + offset >= 0 do
          assert {:ok, ^expected} = GenServer.call(pid, {:position, {:eof, offset}})
        else
          assert {:error, :einval} = GenServer.call(pid, {:position, {:eof, offset}})
        end

        GenServer.stop(pid)
      end
    end

    test "reads file content on init for legacy backends" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "hello world"}
        })

      assert {:ok, "hello"} = GenServer.call(pid, {:read, 5})
      assert {:ok, " worl"} = GenServer.call(pid, {:read, 5})
      assert {:ok, "d"} = GenServer.call(pid, {:read, 5})
      assert :eof = GenServer.call(pid, {:read, 5})
    end

    test "file handler emits telemetry for reads" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :sftp, :read]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      state = %{backend: MockBackend, backend_state: %{content: "hello world"}}
      {{:ok, pid}, _state} = FileHandler.open(~c"/test.txt", [:read], state)

      assert {{:ok, "hello"}, _state} = FileHandler.read(pid, 5, state)

      assert_receive {:telemetry_event, [:sftpd, :sftp, :read], measurements, metadata}
      assert measurements.bytes == 5
      assert metadata.result == :ok
      assert metadata.bytes_requested == 5
      assert metadata.backend == MockBackend

      GenServer.stop(pid)
    end

    test "file handler emits eof telemetry for reads" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :sftp, :read]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      state = %{backend: RangeEmptyBackend, backend_state: %{}}
      {{:ok, pid}, _state} = FileHandler.open(~c"/range.txt", [:read], state)

      assert {:eof, ^state} = FileHandler.read(pid, 3, state)

      assert_receive {:telemetry_event, [:sftpd, :sftp, :read], measurements, metadata}
      assert measurements.bytes == 0
      assert metadata.result == :eof
      assert metadata.reason == nil

      GenServer.stop(pid)
    end

    test "uses read_file_range when the backend supports it" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/range.txt",
          mode: :read,
          backend: RangeBackend,
          backend_state: %{content: "abcdefghij"}
        })

      assert {:ok, "abc"} = GenServer.call(pid, {:read, 3})
      assert {:ok, "defg"} = GenServer.call(pid, {:read, 4})
      assert {:ok, 8} = GenServer.call(pid, {:position, {:eof, -2}})
      assert {:ok, "ij"} = GenServer.call(pid, {:read, 4})
      assert :eof = GenServer.call(pid, {:read, 1})
    end

    test "handles read error gracefully" do
      assert {:error, :enoent} =
               IODevice.start(%{
                 path: ~c"/missing.txt",
                 mode: :read,
                 backend: MockBackend,
                 backend_state: %{error: :enoent}
               })
    end

    test "returns eof when a range backend yields an empty chunk" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/range.txt",
          mode: :read,
          backend: RangeEmptyBackend,
          backend_state: %{}
        })

      assert :eof = GenServer.call(pid, {:read, 3})
    end

    test "returns backend errors from range reads" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/range.txt",
          mode: :read,
          backend: RangeErrorBackend,
          backend_state: %{}
        })

      assert {:error, :eio} = GenServer.call(pid, {:read, 3})
    end

    test "logs and surfaces file_info errors for range backends" do
      log =
        capture_log(fn ->
          assert {:error, :enoent} =
                   IODevice.start(%{
                     path: ~c"/range.txt",
                     mode: :read,
                     backend: RangeStatErrorBackend,
                     backend_state: %{}
                   })
        end)

      assert log =~ "Failed to stat file"
    end

    test "times out and terminates devices when read setup hangs" do
      test_pid = self()

      task =
        Task.async(fn ->
          capture_log(fn ->
            result =
              IODevice.start(%{
                path: ~c"/stuck.txt",
                mode: :read,
                backend: HangingOpenBackend,
                backend_state: %{test_pid: test_pid},
                open_timeout: 10
              })

            send(test_pid, {:open_result, result})
          end)
        end)

      assert_receive {:open_started, pid}, 1000
      ref = Process.monitor(pid)
      assert_receive {:open_result, {:error, :timeout}}, 1000
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000

      assert Task.await(task, 1000) =~ "Timed out waiting 10ms"
    end

    test "process backend read open honors open_timeout beyond GenServer call default" do
      {:ok, backend} = SlowProcessReadBackend.start_link(self())

      task =
        Task.async(fn ->
          IODevice.start(%{
            path: ~c"/slow.txt",
            mode: :read,
            backend: {:genserver, backend},
            backend_state: :ignored,
            open_timeout: 7_000
          })
        end)

      assert_receive {:process_read_opened, ^backend, ~c"/slow.txt"}, 1_000
      Process.sleep(5_200)
      refute Task.yield(task, 0)

      SlowProcessReadBackend.reply(backend, {:ok, "slow"})

      assert {:ok, pid} = Task.await(task, 2_000)
      assert {:ok, "slow"} = GenServer.call(pid, {:read, 10})
    end

    test "returns eio immediately when read setup crashes" do
      test_pid = self()

      task =
        Task.async(fn ->
          capture_log(fn ->
            result =
              IODevice.start(%{
                path: ~c"/crash.txt",
                mode: :read,
                backend: CrashingOpenBackend,
                backend_state: %{},
                open_timeout: 10_000
              })

            send(test_pid, {:open_result, result})
          end)
        end)

      assert_receive {:open_result, {:error, :eio}}, 1_000
      assert Task.await(task, 1_000) =~ "IODevice open worker failed: open failed"
    end

    test "position bof sets absolute position" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "0123456789"}
        })

      assert {:ok, 5} = GenServer.call(pid, {:position, {:bof, 5}})
      assert {:ok, "56789"} = GenServer.call(pid, {:read, 10})
    end

    test "position cur sets relative position" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "0123456789"}
        })

      assert {:ok, "012"} = GenServer.call(pid, {:read, 3})
      assert {:ok, 5} = GenServer.call(pid, {:position, {:cur, 2}})
      assert {:ok, "56789"} = GenServer.call(pid, {:read, 10})
    end

    test "position with integer sets absolute position" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "0123456789"}
        })

      assert {:ok, 7} = GenServer.call(pid, {:position, 7})
      assert {:ok, "789"} = GenServer.call(pid, {:read, 10})
    end

    test "invalid positions return einval" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "0123456789"}
        })

      assert {:error, :einval} = GenServer.call(pid, {:position, {:bogus, 1}})
      assert {:error, :einval} = GenServer.call(pid, {:position, -1})
    end

    test "returns eof when position is at or past end" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "abc"}
        })

      assert {:ok, 10} = GenServer.call(pid, {:position, {:bof, 10}})
      assert :eof = GenServer.call(pid, {:read, 1})
    end

    test "close message stops read-mode process" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "hello"}
        })

      ref = Process.monitor(pid)
      send(pid, {:file_request, self(), make_ref(), :close})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "terminate is clean for read mode" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "hello"}
        })

      assert :ok = GenServer.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "write mode" do
    property "legacy sequential writes persist exactly the concatenated bytes on close" do
      check all(chunks <- list_of(binary(max_length: 64), min_length: 1, max_length: 20)) do
        {:ok, pid} =
          IODevice.start(%{
            path: ~c"/output.txt",
            mode: :write,
            backend: MockBackend,
            backend_state: %{test_pid: self()}
          })

        for chunk <- chunks do
          assert :ok = GenServer.call(pid, {:write, chunk})
        end

        assert :ok = GenServer.call(pid, :close)
        assert_receive {:written, written}, 1000
        assert written == IO.iodata_to_binary(chunks)
      end
    end

    property "streaming sequential writes preserve chunk offsets and finish state" do
      check all(chunks <- list_of(binary(max_length: 64), min_length: 1, max_length: 20)) do
        {:ok, pid} =
          IODevice.start(%{
            path: ~c"/stream.txt",
            mode: :write,
            backend: StreamingBackend,
            backend_state: %{test_pid: self()}
          })

        expected =
          chunks
          |> Enum.reduce({0, []}, fn chunk, {offset, acc} ->
            assert :ok = GenServer.call(pid, {:write, chunk})
            assert_receive {:stream_chunk, ^offset, ^chunk}, 1000
            {offset + byte_size(chunk), acc ++ [{offset, chunk}]}
          end)
          |> elem(1)

        assert :ok = GenServer.call(pid, :close)
        assert_receive {:stream_finish, ^expected}, 1000
      end
    end

    test "persists writes through the legacy backend on close" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "hello "})
      assert :ok = GenServer.call(pid, {:write, "world"})
      assert :ok = GenServer.call(pid, :close)

      assert_receive {:written, "hello world"}, 1000
      refute_receive {:written, _}, 200
    end

    test "file handler emits telemetry for writes" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :sftp, :write]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      state = %{backend: MockBackend, backend_state: %{test_pid: self()}}
      {{:ok, pid}, _state} = FileHandler.open(~c"/output.txt", [:write], state)

      assert {:ok, _state} = FileHandler.write(pid, "hello", state)

      assert_receive {:telemetry_event, [:sftpd, :sftp, :write], measurements, metadata}
      assert measurements.bytes == 5
      assert metadata.result == :ok
      assert metadata.backend == MockBackend

      assert :ok = GenServer.call(pid, :close)
    end

    test "file handler emits error telemetry for failed writes" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :sftp, :write]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      state = %{backend: StreamingWriteErrorBackend, backend_state: %{test_pid: self()}}
      {{:ok, pid}, _state} = FileHandler.open(~c"/output.txt", [:write], state)

      assert {{:error, :eio}, ^state} = FileHandler.write(pid, "hello", state)

      assert_receive {:telemetry_event, [:sftpd, :sftp, :write], measurements, metadata}
      assert measurements.bytes == 5
      assert metadata.result == :error
      assert metadata.reason == :eio

      GenServer.stop(pid)
    end

    test "creates temp files with owner-only permissions" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      %{temp_path: temp_path} = :sys.get_state(pid)
      assert {:ok, %{mode: mode}} = File.stat(temp_path)
      assert Bitwise.band(mode, 0o777) == 0o600

      assert :ok = GenServer.call(pid, :close)
    end

    test "open timeout cleans up temp files while streaming write setup hangs" do
      test_pid = self()
      before = sftpd_temp_files()

      task =
        Task.async(fn ->
          capture_log(fn ->
            result =
              IODevice.start(%{
                path: ~c"/stuck-output.txt",
                mode: :write,
                backend: HangingStreamingOpenBackend,
                backend_state: %{test_pid: test_pid},
                open_timeout: 10
              })

            send(test_pid, {:open_result, result})
          end)
        end)

      assert_receive {:stream_open_started, worker}, 1000
      ref = Process.monitor(worker)
      assert_receive {:open_result, {:error, :timeout}}, 1000
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1000
      assert Task.await(task, 1000) =~ "Timed out waiting 10ms"
      assert sftpd_temp_files() == before
    end

    test "logs temp file removal failures" do
      temp_dir = Path.join(System.tmp_dir!(), "sftpd-test-#{System.unique_integer([:positive])}")
      File.mkdir!(temp_dir)

      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      %{temp_path: original_temp_path} = :sys.get_state(pid)

      :sys.replace_state(pid, fn state ->
        %{state | temp_path: temp_dir}
      end)

      log =
        capture_log(fn ->
          assert {:error, _reason} = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to remove temp file"
      File.rm(original_temp_path)
      File.rmdir!(temp_dir)
    end

    test "does not upload buffered content on terminate" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "content"})
      GenServer.stop(pid)

      refute_receive {:written, _}, 200
    end

    test "logs and returns an error when legacy finalization fails" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{write_error: :eacces}
        })

      assert :ok = GenServer.call(pid, {:write, "content"})

      log =
        capture_log(fn ->
          assert {:error, :eacces} = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to finalize legacy write"
    end

    test "position bof updates the write cursor" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert {:ok, 100} = GenServer.call(pid, {:position, {:bof, 100}})
    end

    test "position eof returns einval in write mode" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert {:error, :einval} = GenServer.call(pid, {:position, {:eof, 0}})
    end

    test "handles iodata in writes" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, [?a, "bc", [?d, ?e]]})
      assert :ok = GenServer.call(pid, :close)

      assert_receive {:written, "abcde"}, 1000
    end

    test "finalizes active streaming writes on close" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/stream.txt",
          mode: :write,
          backend: StreamingBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "hello"})
      assert_receive {:stream_chunk, 0, "hello"}
      assert :ok = GenServer.call(pid, :close)
      assert_receive {:stream_finish, [{0, "hello"}]}
    end

    test "falls back to replay mode when streaming initialization fails" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      log =
        capture_log(fn ->
          {:ok, pid} =
            IODevice.start(%{
              path: ~c"/stream.txt",
              mode: :write,
              backend: ReplayBackend,
              backend_state: %{agent: agent, test_pid: self()}
            })

          assert :ok = GenServer.call(pid, {:write, "hello"})
          assert :ok = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to initialize streaming write"
      assert_receive {:replay_chunk, 0, "hello"}
      assert_receive {:replay_finish, [{0, "hello"}]}
    end

    test "falls back to legacy writes unless all streaming callbacks are present" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/partial.txt",
          mode: :write,
          backend: PartialStreamingBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "hello"})
      assert :ok = GenServer.call(pid, :close)
      assert_receive {:partial_written, "hello"}, 1000
    end

    test "non-sequential writes downgrade to temp-file replay mode" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/stream.txt",
          mode: :write,
          backend: StreamingBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "abc"})
      assert_receive {:stream_chunk, 0, "abc"}

      assert {:ok, 1} = GenServer.call(pid, {:position, {:bof, 1}})
      assert :ok = GenServer.call(pid, {:write, "Z"})
      assert_receive {:stream_abort, [{0, "abc"}]}

      assert :ok = GenServer.call(pid, :close)
      assert_receive {:stream_chunk, 0, "aZc"}
      assert_receive {:stream_finish, [{0, "aZc"}]}
    end

    test "returns write errors and logs cleanup failures for streaming backends" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/stream.txt",
          mode: :write,
          backend: StreamingWriteErrorBackend,
          backend_state: %{test_pid: self()}
        })

      log =
        capture_log(fn ->
          assert {:error, :eio} = GenServer.call(pid, {:write, "hello"})
          assert {:error, :eio} = GenServer.call(pid, :close)
        end)

      assert log =~ "Streaming write failed"
      assert log =~ "Failed to abort streaming write"
    end

    test "preserves write errors for precomputed-byte write calls" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/stream.txt",
          mode: :write,
          backend: StreamingWriteErrorBackend,
          backend_state: %{test_pid: self()}
        })

      capture_log(fn ->
        assert {:error, :eio} = GenServer.call(pid, {:write, "hello"})
        assert {:error, :eio} = GenServer.call(pid, {:write, "world", 5})
      end)

      GenServer.stop(pid)
    end

    test "returns errors when finish_write fails" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/stream.txt",
          mode: :write,
          backend: StreamingFinishErrorBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "hello"})

      log =
        capture_log(fn ->
          assert {:error, :eio} = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to finalize streaming write"
      assert_receive {:finish_error_abort, [{0, "hello"}]}
    end

    test "returns errors when replaying the temp file fails" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      log =
        capture_log(fn ->
          {:ok, pid} =
            IODevice.start(%{
              path: ~c"/stream.txt",
              mode: :write,
              backend: ReplayWriteErrorBackend,
              backend_state: %{agent: agent, test_pid: self()}
            })

          assert :ok = GenServer.call(pid, {:write, "hello"})
          assert {:error, :eio} = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to replay temp file"
    end

    test "aborts replayed streaming writes when finish_write fails" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      log =
        capture_log(fn ->
          {:ok, pid} =
            IODevice.start(%{
              path: ~c"/stream.txt",
              mode: :write,
              backend: ReplayFinishErrorBackend,
              backend_state: %{agent: agent, test_pid: self()}
            })

          assert :ok = GenServer.call(pid, {:write, "hello"})
          assert {:error, :eio} = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to replay temp file"
      assert_receive {:replay_finish_error_abort, [{0, "hello"}]}
    end

    test "returns an error instead of looping when temp replay hits unexpected eof" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      log =
        capture_log(fn ->
          {:ok, pid} =
            IODevice.start(%{
              path: ~c"/stream.txt",
              mode: :write,
              backend: ReplayBackend,
              backend_state: %{agent: agent, test_pid: self()}
            })

          assert :ok = GenServer.call(pid, {:write, "abc"})
          :sys.replace_state(pid, fn state -> %{state | size: 10} end)
          assert {:error, :eof} = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to replay temp file"
      assert_receive {:replay_chunk, 0, "abc"}
      assert_receive {:replay_abort, [{0, "abc"}]}
    end
  end

  describe "handle_info catch-all" do
    test "ignores unknown messages and stays alive" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "hello"}
        })

      send(pid, :unknown_message)
      send(pid, {:some, :other, :message})

      assert {:ok, "hello"} = GenServer.call(pid, {:read, 5})
    end
  end

  defp read_until_eof(pid, lengths) do
    Enum.reduce_while(lengths, "", fn length, acc ->
      case GenServer.call(pid, {:read, length}) do
        {:ok, data} -> {:cont, acc <> data}
        :eof -> {:halt, acc}
        {:error, reason} -> flunk("unexpected read error: #{inspect(reason)}")
      end
    end)
  end

  defp sftpd_temp_files do
    System.tmp_dir!()
    |> Path.join("sftpd-*.tmp")
    |> Path.wildcard()
    |> MapSet.new()
  end
end
