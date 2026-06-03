defmodule Sftpd.DirectIODeviceTest do
  use ExUnit.Case, async: true

  alias Sftpd.Backends.Memory
  alias Sftpd.DirectIODevice

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
end
