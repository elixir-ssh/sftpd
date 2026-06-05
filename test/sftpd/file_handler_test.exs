defmodule Sftpd.FileHandlerTest do
  use ExUnit.Case, async: false

  alias Sftpd.{IODevice, FileHandler}
  alias Sftpd.Backends.Memory
  alias Sftpd.Test.TelemetryHelper

  @state %{backend: nil, backend_state: nil}

  defmodule MockBackend do
    def open_read("/file.txt", _session, _state), do: {:ok, %{content: "content"}}
    def open_read("/file", _session, _state), do: {:ok, %{content: "abc"}}
    def open_read(_path, _session, _state), do: {:error, :enoent}

    def read_at(%{content: content}, offset, len, _state) do
      if offset >= byte_size(content) do
        :eof
      else
        {:ok, binary_part(content, offset, min(len, byte_size(content) - offset))}
      end
    end

    def open_write(path, _attrs, _session, _state), do: {:ok, %{path: path, chunks: []}}

    def write_at(handle, offset, data, _state),
      do: {:ok, %{handle | chunks: [{offset, data} | handle.chunks]}}

    def finish_write(_handle, _state), do: :ok
    def abort_write(_handle, _state), do: :ok

    def open_dir("/items", _session, _state) do
      {:ok,
       %{
         pages: [
           [
             %{name: ".", attrs: %{type: :directory, size: 0}},
             %{name: "..", attrs: %{type: :directory, size: 0}},
             %{name: "entry", attrs: %{type: :regular, size: 0}}
           ]
         ]
       }}
    end

    def open_dir("/paged", _session, _state) do
      {:ok,
       %{
         pages: [
           [
             %{name: ".", attrs: %{type: :directory, size: 0}},
             %{name: "..", attrs: %{type: :directory, size: 0}}
           ],
           [
             %{name: "one", attrs: %{type: :regular, size: 0}},
             %{name: "two", attrs: %{type: :regular, size: 0}}
           ]
         ]
       }}
    end

    def open_dir("/read-dir-error", _session, _state), do: {:ok, %{pages: :error}}

    def open_dir("/legacy-items", _session, _state) do
      {:ok,
       %{
         entries: [
           %{name: ".", attrs: %{type: :directory, size: 0}},
           %{name: "..", attrs: %{type: :directory, size: 0}},
           %{name: "entry", attrs: %{type: :regular, size: 0}}
         ]
       }}
    end

    def read_dir(%{pages: []}, _state), do: :eof
    def read_dir(%{pages: :error}, _state), do: {:error, :eio}

    def read_dir(%{pages: [entries | pages]} = handle, _state),
      do: {:ok, entries, %{handle | pages: pages}}

    def read_dir(%{entries: entries} = handle, _state),
      do: {:ok, entries, Map.delete(handle, :entries)}

    def close_dir(_handle, _state), do: :ok

    def make_dir(_path, _attrs, _session, _state), do: :ok
    def del_dir(_path, _session, _state), do: :ok
    def delete(_path, _session, _state), do: :ok
    def rename(_src, _dst, _session, _state), do: :ok

    def file_attrs("/dir", _session, _state), do: {:ok, %{type: :directory, size: 4096}}
    def file_attrs("/file", _session, _state), do: {:ok, %{type: :regular, size: 3}}
    def file_attrs("/file.txt", _session, _state), do: {:ok, %{type: :regular, size: 7}}
    def file_attrs(_path, _session, _state), do: {:error, :enoent}
  end

  defmodule ReadErrorBackend do
    def file_attrs(_path, _session, _state), do: {:error, :enoent}
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
      {{:ok, handle}, _state} = FileHandler.open(~c"/file.txt", [], state)
      assert IODevice.handle?(handle)
      assert {:ok, _state} = FileHandler.close(handle, state)
    end

    test "returns read setup errors before issuing a handle" do
      state = %{backend: ReadErrorBackend, backend_state: %{}}

      assert {{:error, :enoent}, ^state} = FileHandler.open(~c"/missing.txt", [:read], state)
    end

    test "supports mixed read/write opens without returning a write-only handle" do
      state = %{backend: MockBackend, backend_state: %{}}

      assert {{:ok, handle}, ^state} = FileHandler.open(~c"/file.txt", [:read, :write], state)
      assert IODevice.handle?(handle)
      assert {{:ok, "content"}, ^state} = FileHandler.read(handle, 16, state)

      assert {{:ok, 0}, ^state} = FileHandler.position(handle, {:bof, 0}, state)
      assert {:ok, ^state} = FileHandler.write(handle, "updated", state)
      assert {:ok, ^state} = FileHandler.close(handle, state)
    end

    test "preserves truncate semantics for mixed read/write opens" do
      {:ok, backend_state} = Memory.init([])
      :ok = Memory.write_file(~c"/file.txt", "content", backend_state)
      state = %{backend: Memory, backend_state: backend_state}

      assert {{:ok, handle}, ^state} =
               FileHandler.open(~c"/file.txt", [:read, :write, :truncate], state)

      assert {:ok, ^state} = FileHandler.close(handle, state)
      assert {:ok, ""} = Memory.read_file(~c"/file.txt", backend_state)
    end

    test "uses direct handles for memory backend reads and writes" do
      {:ok, backend_state} = Memory.init([])
      :ok = Memory.write_file(~c"/file.txt", "content", backend_state)
      state = %{backend: Memory, backend_state: backend_state}

      assert {{:ok, read_handle}, ^state} = FileHandler.open(~c"/file.txt", [:read], state)
      assert IODevice.handle?(read_handle)
      assert {{:ok, "content"}, ^state} = FileHandler.read(read_handle, 16, state)
      assert {:ok, ^state} = FileHandler.close(read_handle, state)

      assert {{:ok, write_handle}, ^state} = FileHandler.open(~c"/out.txt", [:write], state)
      assert IODevice.handle?(write_handle)
      assert {:ok, ^state} = FileHandler.write(write_handle, ["fast", "-", "path"], state)
      assert {:ok, ^state} = FileHandler.close(write_handle, state)
      assert {:ok, "fast-path"} = Memory.read_file(~c"/out.txt", backend_state)
    end

    test "emits telemetry for open" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :sftp, :open]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      state = %{backend: MockBackend, backend_state: %{}}
      {{:ok, handle}, _state} = FileHandler.open(~c"/file.txt", [], state)

      assert_receive {:telemetry_event, [:sftpd, :sftp, :open], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.result == :ok
      assert metadata.mode == :read
      assert metadata.path == "/file.txt"
      assert metadata.backend == MockBackend

      assert {:ok, _state} = FileHandler.close(handle, state)
    end
  end

  describe "list_dir/2" do
    test "drains paged backend directory handles" do
      state = %{backend: MockBackend, backend_state: %{}}

      assert {{:ok, [~c".", ~c"..", ~c"one", ~c"two"]}, ^state} =
               FileHandler.list_dir(~c"/paged", state)
    end

    test "closes backend directory handles after read errors" do
      state = %{backend: MockBackend, backend_state: %{}}
      assert {{:error, :eio}, ^state} = FileHandler.list_dir(~c"/read-dir-error", state)
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

      assert {{:ok, {:file_info, 3, :regular, :read_write, _, _, _, _, _, _, _, _, _, _}}, ^state} =
               FileHandler.read_file_info(~c"/file", state)

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
    test "emits telemetry for invalid non-direct handles" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :sftp, :close]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {{:error, :einval}, _state} =
               FileHandler.close(self(), %{backend: nil, backend_state: nil})

      assert_receive {:telemetry_event, [:sftpd, :sftp, :close], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.result == :error
      assert metadata.reason == :einval
    end
  end
end
