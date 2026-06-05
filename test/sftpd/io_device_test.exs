defmodule Sftpd.IODeviceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.Backends.Memory
  alias Sftpd.IODevice

  defmodule ErrorBackend do
    @moduledoc false

    def file_attrs("/attrs-error", _session, _state), do: {:error, :enoent}

    def file_attrs("/nested-iodata", _session, %{seed_data: data}),
      do: {:ok, %{size: IO.iodata_length(data)}}

    def file_attrs(_path, _session, _state), do: {:ok, %{size: 4}}

    def open_read("/open-read-error", _session, _state), do: {:error, :eacces}
    def open_read("/read-error", _session, _state), do: {:ok, :read_error}
    def open_read("/backend-eof", _session, _state), do: {:ok, :backend_eof}
    def open_read("/iodata", _session, _state), do: {:ok, :iodata}

    def open_read("/nested-iodata", _session, %{seed_data: data}),
      do: {:ok, {:nested_iodata, data}}

    def open_read(_path, _session, _state), do: {:ok, :reader}

    def read_at(:read_error, _offset, _len, _state), do: {:error, :eio}
    def read_at(:backend_eof, _offset, _len, _state), do: :eof
    def read_at(:iodata, _offset, _len, _state), do: {:ok, ["io", "data"]}
    def read_at({:nested_iodata, data}, _offset, _len, _state), do: {:ok, data}
    def read_at(_handle, _offset, 0, _state), do: {:ok, ""}
    def read_at(_handle, _offset, len, _state), do: {:ok, binary_part("data", 0, min(len, 4))}

    def open_write("/open-write-error", _attrs, _session, _state), do: {:error, :eacces}
    def open_write("/finish-error", _attrs, _session, _state), do: {:ok, :finish_error}
    def open_write("/write-error", _attrs, _session, _state), do: {:ok, :write_error}
    def open_write("/nested-iodata", _attrs, _session, _state), do: {:ok, :nested_writer}
    def open_write(_path, _attrs, _session, _state), do: {:ok, :writer}

    def write_at(:write_error, _offset, _data, _state), do: {:error, :eio}

    def write_at(:nested_writer = handle, offset, data, %{test_pid: test_pid}) do
      send(test_pid, {:seed_write, offset, data, IO.iodata_length(data), is_binary(data)})
      {:ok, handle}
    end

    def write_at(handle, _offset, _data, _state), do: {:ok, handle}

    def finish_write(:finish_error, _state), do: {:error, :eio}
    def finish_write(_handle, _state), do: :ok

    def abort_write(:write_error, %{test_pid: test_pid}), do: send(test_pid, :aborted)
    def abort_write(_handle, _state), do: :ok
  end

  defmodule SequentialBackend do
    @moduledoc false

    def file_attrs("/sized.bin", _session, _state), do: {:ok, %{size: 4}}
    def file_attrs(_path, _session, _state), do: {:ok, %{size: 0}}
    def open_read(_path, _session, _state), do: {:error, :enoent}
    def read_at(_handle, _offset, _len, _state), do: :eof

    def open_write(_path, _attrs, _session, state) do
      open_index =
        Agent.get_and_update(state, fn data ->
          open_index = Map.get(data, :opens, 0) + 1
          {open_index, Map.put(data, :opens, open_index)}
        end)

      {:ok, %{offset: 0, chunks: [], open_index: open_index}}
    end

    def write_at(%{offset: offset} = handle, offset, data, _state) do
      data = IO.iodata_to_binary(data)

      {:ok,
       %{handle | offset: offset + byte_size(data), chunks: [{offset, data} | handle.chunks]}}
    end

    def write_at(_handle, _offset, _data, _state), do: {:error, :einval}

    def finish_write(%{open_index: open_index} = handle, state) do
      if Agent.get(state, &Map.get(&1, :finish_error_on_open)) == open_index do
        {:error, :eio}
      else
        content =
          handle.chunks
          |> Enum.reverse()
          |> Enum.map(fn {_offset, data} -> data end)
          |> IO.iodata_to_binary()

        Agent.update(state, &Map.put(&1, :content, content))
      end
    end

    def abort_write(_handle, state) do
      Agent.update(state, fn data ->
        Map.update(data, :aborts, 1, fn aborts -> aborts + 1 end)
      end)
    end
  end

  setup do
    {:ok, state} = Memory.init([])
    %{backend_state: state}
  end

  test "reads ranges without a per-file process", %{backend_state: backend_state} do
    :ok = Memory.write_file(~c"/file.bin", "abcdefghij", backend_state)

    assert {:ok, handle} =
             IODevice.start(%{
               path: ~c"/file.bin",
               mode: :read,
               backend: Memory,
               backend_state: backend_state,
               session: %{}
             })

    refute is_pid(handle)
    assert IODevice.handle?(handle)
    assert {:ok, "abcd"} = IODevice.read(handle, 4)
    assert {:ok, 2} = IODevice.position(handle, {:bof, 2})
    assert {:ok, "cde"} = IODevice.read(handle, 3)
    assert {:ok, 9} = IODevice.position(handle, {:eof, -1})
    assert {:ok, "j"} = IODevice.read(handle, 4)
    assert :eof = IODevice.read(handle, 4)
    assert :ok = IODevice.close(handle)
  end

  test "normalizes backend iodata reads to binaries" do
    assert {:ok, handle} =
             IODevice.start(%{
               path: "/iodata",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:ok, "iodata"} = IODevice.read(handle, 6)
  end

  property "read/write seeding accepts iodata without flattening backend replay" do
    check all(
            head <- binary(min_length: 1, max_length: 16),
            tail <- binary(max_length: 16)
          ) do
      data = [head, [tail]]
      bytes = IO.iodata_length(data)
      expected = IO.iodata_to_binary(data)

      assert {:ok, handle} =
               IODevice.start(%{
                 path: "/nested-iodata",
                 mode: :read_write,
                 backend: ErrorBackend,
                 backend_state: %{test_pid: self(), seed_data: data}
               })

      assert_receive {:seed_write, 0, ^data, ^bytes, false}
      assert {:ok, ^expected} = IODevice.read(handle, bytes)
      assert :ok = IODevice.close(handle)
    end
  end

  test "writes iodata and finalizes on close", %{backend_state: backend_state} do
    assert {:ok, handle} =
             IODevice.start(%{
               path: ~c"/out.bin",
               mode: :write,
               backend: Memory,
               backend_state: backend_state,
               session: %{}
             })

    assert :ok = IODevice.write(handle, ["abc", "def"], 6)
    assert {:ok, 2} = IODevice.position(handle, {:bof, 2})
    assert :ok = IODevice.write(handle, "XY", 2)
    assert :ok = IODevice.close(handle)

    assert {:ok, "abXYef"} = Memory.read_file(~c"/out.bin", backend_state)
  end

  test "append writes against missing files start at offset zero", %{backend_state: backend_state} do
    assert {:ok, handle} =
             IODevice.start(%{
               path: ~c"/new-append.bin",
               mode: :write,
               append?: true,
               backend: Memory,
               backend_state: backend_state,
               session: %{}
             })

    assert :ok = IODevice.write(handle, "new", 3)
    assert :ok = IODevice.close(handle)

    assert {:ok, "new"} = Memory.read_file(~c"/new-append.bin", backend_state)
  end

  test "replays random writes sequentially when backend rejects positioned writes" do
    {:ok, state} = Agent.start_link(fn -> %{} end)

    assert {:ok, handle} =
             IODevice.start(%{
               path: ~c"/sized.bin",
               mode: :write,
               backend: SequentialBackend,
               backend_state: state,
               session: %{}
             })

    assert :ok = IODevice.write(handle, "abcdef", 6)
    assert {:ok, 2} = IODevice.position(handle, {:bof, 2})
    assert :ok = IODevice.write(handle, "XY", 2)
    assert {:ok, 4} = IODevice.position(handle, 4)
    assert :ok = IODevice.write(handle, "Z", 1)
    assert :ok = IODevice.close(handle)

    assert Agent.get(state, & &1) == %{aborts: 1, content: "abXYZf", opens: 2}
  end

  test "rejects read/write handles without a readable backend side for existing files" do
    {:ok, state} = Agent.start_link(fn -> %{} end)

    assert {:error, :eio} =
             IODevice.start(%{
               path: ~c"/sized.bin",
               mode: :read_write,
               backend: SequentialBackend,
               backend_state: state,
               session: %{}
             })
  end

  test "closing untouched read/write handles preserves existing content", %{
    backend_state: backend_state
  } do
    :ok = Memory.write_file(~c"/file.bin", "content", backend_state)

    assert {:ok, handle} =
             IODevice.start(%{
               path: ~c"/file.bin",
               mode: :read_write,
               backend: Memory,
               backend_state: backend_state,
               session: %{}
             })

    assert {:ok, "content"} = IODevice.read(handle, 16)
    assert :ok = IODevice.close(handle)
    assert {:ok, "content"} = Memory.read_file(~c"/file.bin", backend_state)
  end

  property "read/write handles preserve existing bytes around partial writes", %{
    backend_state: backend_state
  } do
    check all(
            prefix <- binary(min_length: 1, max_length: 32),
            replacement <- binary(min_length: 1, max_length: 32),
            suffix <- binary(min_length: 1, max_length: 32)
          ) do
      original = [prefix, :binary.copy("x", byte_size(replacement)), suffix]
      expected = [prefix, replacement, suffix] |> IO.iodata_to_binary()
      offset = byte_size(prefix)

      :ok = Memory.write_file(~c"/file.bin", original, backend_state)

      assert {:ok, handle} =
               IODevice.start(%{
                 path: ~c"/file.bin",
                 mode: :read_write,
                 backend: Memory,
                 backend_state: backend_state,
                 session: %{}
               })

      assert {:ok, ^offset} = IODevice.position(handle, {:bof, offset})
      assert :ok = IODevice.write(handle, replacement, byte_size(replacement))
      assert :ok = IODevice.close(handle)
      assert {:ok, ^expected} = Memory.read_file(~c"/file.bin", backend_state)
    end
  end

  test "read/write handles read accepted writes before close", %{
    backend_state: backend_state
  } do
    assert {:ok, handle} =
             IODevice.start(%{
               path: ~c"/new.bin",
               mode: :read_write,
               backend: Memory,
               backend_state: backend_state,
               session: %{}
             })

    assert :ok = IODevice.write(handle, "abc", 3)
    assert {:ok, 0} = IODevice.position(handle, {:bof, 0})
    assert {:ok, "abc"} = IODevice.read(handle, 3)
    assert :ok = IODevice.close(handle)
  end

  test "read/write handles read partial overwrites before close", %{
    backend_state: backend_state
  } do
    :ok = Memory.write_file(~c"/file.bin", "abcdef", backend_state)

    assert {:ok, handle} =
             IODevice.start(%{
               path: ~c"/file.bin",
               mode: :read_write,
               backend: Memory,
               backend_state: backend_state,
               session: %{}
             })

    assert {:ok, 2} = IODevice.position(handle, {:bof, 2})
    assert :ok = IODevice.write(handle, "XY", 2)
    assert {:ok, 0} = IODevice.position(handle, {:bof, 0})
    assert {:ok, "abXYef"} = IODevice.read(handle, 6)
    assert :ok = IODevice.close(handle)
  end

  test "truncating read/write handles ignore previous content", %{backend_state: backend_state} do
    :ok = Memory.write_file(~c"/file.bin", "old", backend_state)

    assert {:ok, handle} =
             IODevice.start(%{
               path: ~c"/file.bin",
               mode: :read_write,
               truncate?: true,
               backend: Memory,
               backend_state: backend_state,
               session: %{}
             })

    assert :eof = IODevice.read(handle, 1)
    assert :ok = IODevice.write(handle, "new", 3)
    assert {:ok, 0} = IODevice.position(handle, {:bof, 0})
    assert {:ok, "new"} = IODevice.read(handle, 8)
    assert :ok = IODevice.close(handle)

    assert {:ok, "new"} = Memory.read_file(~c"/file.bin", backend_state)
  end

  test "aborts replay writer when replay finalize fails" do
    {:ok, state} = Agent.start_link(fn -> %{finish_error_on_open: 2} end)

    assert {:ok, handle} =
             IODevice.start(%{
               path: ~c"/out.bin",
               mode: :write,
               backend: SequentialBackend,
               backend_state: state,
               session: %{}
             })

    assert :ok = IODevice.write(handle, "abcdef", 6)
    assert {:ok, 2} = IODevice.position(handle, {:bof, 2})
    assert :ok = IODevice.write(handle, "XY", 2)
    assert {:error, :eio} = IODevice.close(handle)

    assert Agent.get(state, &Map.take(&1, [:aborts, :opens])) == %{aborts: 2, opens: 2}
  end

  test "returns einval for stale handles" do
    handle = {:sftpd_io, make_ref()}

    assert {:error, :einval} = IODevice.position(handle, 0)
    assert {:error, :einval} = IODevice.read(handle, 1)
    assert {:error, :einval} = IODevice.write(handle, "x", 1)
    assert :ok = IODevice.close(handle)
  end

  test "rejects invalid positions and operations for the handle mode", %{
    backend_state: backend_state
  } do
    :ok = Memory.write_file(~c"/file.bin", "abcd", backend_state)

    assert {:ok, read_handle} =
             IODevice.start(%{
               path: ~c"/file.bin",
               mode: :read,
               backend: Memory,
               backend_state: backend_state
             })

    assert {:error, :einval} = IODevice.position(read_handle, {:bof, -1})
    assert {:error, :einval} = IODevice.position(read_handle, {:cur, -1})
    assert {:error, :einval} = IODevice.position(read_handle, {:eof, -5})
    assert {:ok, 0} = IODevice.position(read_handle, 0)
    assert {:error, :einval} = IODevice.position(read_handle, :bad)
    assert {:error, :einval} = IODevice.write(read_handle, "x", 1)

    assert {:ok, write_handle} =
             IODevice.start(%{
               path: ~c"/out.bin",
               mode: :write,
               backend: Memory,
               backend_state: backend_state
             })

    assert {:error, :einval} = IODevice.read(write_handle, 1)
  end

  test "propagates backend start, read, write, and close errors" do
    assert {:error, :enoent} =
             IODevice.start(%{
               path: "/attrs-error",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:error, :eacces} =
             IODevice.start(%{
               path: "/open-read-error",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:error, :eacces} =
             IODevice.start(%{
               path: "/open-write-error",
               mode: :write,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:ok, read_handle} =
             IODevice.start(%{
               path: "/read-error",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:error, :eio} = IODevice.read(read_handle, 1)

    assert {:ok, eof_handle} =
             IODevice.start(%{
               path: "/backend-eof",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert :eof = IODevice.read(eof_handle, 1)

    assert {:ok, empty_handle} =
             IODevice.start(%{
               path: "/empty-read",
               mode: :read,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert :eof = IODevice.read(empty_handle, 0)

    assert {:ok, write_handle} =
             IODevice.start(%{
               path: "/write-error",
               mode: :write,
               backend: ErrorBackend,
               backend_state: %{test_pid: self()}
             })

    assert {:error, :eio} = IODevice.write(write_handle, "x", 1)
    assert_receive :aborted
    assert :ok = IODevice.close(write_handle)

    assert {:ok, close_handle} =
             IODevice.start(%{
               path: "/finish-error",
               mode: :write,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert {:error, :eio} = IODevice.close(close_handle)
  end

  test "read/write start falls back to zero size when attrs are unavailable" do
    assert {:ok, handle} =
             IODevice.start(%{
               path: "/attrs-error",
               mode: :read_write,
               backend: ErrorBackend,
               backend_state: %{}
             })

    assert :eof = IODevice.read(handle, 1)
    assert :ok = IODevice.close(handle)
  end

  test "read/write start rejects existing files that cannot be seeded" do
    assert {:error, :eio} =
             IODevice.start(%{
               path: "/open-read-error",
               mode: :read_write,
               backend: ErrorBackend,
               backend_state: %{}
             })
  end
end
