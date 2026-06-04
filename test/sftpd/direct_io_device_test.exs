defmodule Sftpd.DirectIODeviceTest do
  use ExUnit.Case, async: true

  alias Sftpd.Backends.Memory
  alias Sftpd.DirectIODevice

  defmodule ErrorBackend do
    @moduledoc false

    def file_attrs("/attrs-error", _session, _state), do: {:error, :enoent}
    def file_attrs(_path, _session, _state), do: {:ok, %{size: 4}}

    def open_read("/open-read-error", _session, _state), do: {:error, :eacces}
    def open_read("/read-error", _session, _state), do: {:ok, :read_error}
    def open_read("/iodata", _session, _state), do: {:ok, :iodata}
    def open_read(_path, _session, _state), do: {:ok, :reader}

    def read_at(:read_error, _offset, _len, _state), do: {:error, :eio}
    def read_at(:iodata, _offset, _len, _state), do: {:ok, ["io", "data"]}
    def read_at(_handle, _offset, 0, _state), do: {:ok, ""}
    def read_at(_handle, _offset, len, _state), do: {:ok, binary_part("data", 0, min(len, 4))}

    def open_write("/open-write-error", _attrs, _session, _state), do: {:error, :eacces}
    def open_write("/finish-error", _attrs, _session, _state), do: {:ok, :finish_error}
    def open_write("/write-error", _attrs, _session, _state), do: {:ok, :write_error}
    def open_write(_path, _attrs, _session, _state), do: {:ok, :writer}

    def write_at(:write_error, _offset, _data, _state), do: {:error, :eio}
    def write_at(handle, _offset, _data, _state), do: {:ok, handle}

    def finish_write(:finish_error, _state), do: {:error, :eio}
    def finish_write(_handle, _state), do: :ok

    def abort_write(:write_error, %{test_pid: test_pid}), do: send(test_pid, :aborted)
    def abort_write(_handle, _state), do: :ok
  end

  setup do
    {:ok, state} = Memory.init([])
    %{backend_state: state}
  end

  test "reads ranges without a per-file process", %{backend_state: backend_state} do
    :ok = Memory.write_file(~c"/file.bin", "abcdefghij", backend_state)

    assert {:ok, handle} =
             DirectIODevice.start(%{
               path: ~c"/file.bin",
               mode: :read,
               backend: Memory,
               backend_state: backend_state,
               session: %{}
             })

    refute is_pid(handle)
    assert DirectIODevice.handle?(handle)
    assert {:ok, "abcd"} = DirectIODevice.read(handle, 4)
    assert {:ok, 2} = DirectIODevice.position(handle, {:bof, 2})
    assert {:ok, "cde"} = DirectIODevice.read(handle, 3)
    assert {:ok, 9} = DirectIODevice.position(handle, {:eof, -1})
    assert {:ok, "j"} = DirectIODevice.read(handle, 4)
    assert :eof = DirectIODevice.read(handle, 4)
    assert :ok = DirectIODevice.close(handle)
  end

  test "normalizes backend iodata reads to binaries" do
    assert {:ok, handle} =
             DirectIODevice.start(%{
               path: "/iodata",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:ok, "iodata"} = DirectIODevice.read(handle, 6)
  end

  test "writes iodata and finalizes on close", %{backend_state: backend_state} do
    assert {:ok, handle} =
             DirectIODevice.start(%{
               path: ~c"/out.bin",
               mode: :write,
               backend: Memory,
               backend_state: backend_state,
               session: %{}
             })

    assert :ok = DirectIODevice.write(handle, ["abc", "def"], 6)
    assert {:ok, 2} = DirectIODevice.position(handle, {:bof, 2})
    assert :ok = DirectIODevice.write(handle, "XY", 2)
    assert :ok = DirectIODevice.close(handle)

    assert {:ok, "abXYef"} = Memory.read_file(~c"/out.bin", backend_state)
  end

  test "returns einval for stale handles" do
    handle = {:sftpd_direct_io, make_ref()}

    assert {:error, :einval} = DirectIODevice.position(handle, 0)
    assert {:error, :einval} = DirectIODevice.read(handle, 1)
    assert {:error, :einval} = DirectIODevice.write(handle, "x", 1)
    assert :ok = DirectIODevice.close(handle)
  end

  test "rejects invalid positions and operations for the handle mode", %{
    backend_state: backend_state
  } do
    :ok = Memory.write_file(~c"/file.bin", "abcd", backend_state)

    assert {:ok, read_handle} =
             DirectIODevice.start(%{
               path: ~c"/file.bin",
               mode: :read,
               backend: Memory,
               backend_state: backend_state
             })

    assert {:error, :einval} = DirectIODevice.position(read_handle, {:bof, -1})
    assert {:error, :einval} = DirectIODevice.position(read_handle, {:cur, -1})
    assert {:error, :einval} = DirectIODevice.position(read_handle, {:eof, -5})
    assert {:error, :einval} = DirectIODevice.position(read_handle, :bad)
    assert {:error, :einval} = DirectIODevice.write(read_handle, "x", 1)

    assert {:ok, write_handle} =
             DirectIODevice.start(%{
               path: ~c"/out.bin",
               mode: :write,
               backend: Memory,
               backend_state: backend_state
             })

    assert {:error, :einval} = DirectIODevice.read(write_handle, 1)
  end

  test "propagates backend start, read, write, and close errors" do
    assert {:error, :enoent} =
             DirectIODevice.start(%{
               path: "/attrs-error",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:error, :eacces} =
             DirectIODevice.start(%{
               path: "/open-read-error",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:error, :eacces} =
             DirectIODevice.start(%{
               path: "/open-write-error",
               mode: :write,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:ok, read_handle} =
             DirectIODevice.start(%{
               path: "/read-error",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:error, :eio} = DirectIODevice.read(read_handle, 1)

    assert {:ok, empty_handle} =
             DirectIODevice.start(%{
               path: "/empty-read",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert :eof = DirectIODevice.read(empty_handle, 0)

    assert {:ok, write_handle} =
             DirectIODevice.start(%{
               path: "/write-error",
               mode: :write,
               backend: ErrorBackend,
               backend_state: %{test_pid: self()}
             })

    assert {:error, :eio} = DirectIODevice.write(write_handle, "x", 1)
    assert_receive :aborted
    assert :ok = DirectIODevice.close(write_handle)

    assert {:ok, close_handle} =
             DirectIODevice.start(%{
               path: "/finish-error",
               mode: :write,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:error, :eio} = DirectIODevice.close(close_handle)
  end
end
