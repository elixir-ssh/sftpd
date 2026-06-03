defmodule Sftpd.Backends.BenchmarkTest do
  use ExUnit.Case, async: true

  alias Sftpd.Backends.Benchmark

  setup do
    {:ok, state} = Benchmark.init([])
    %{state: state}
  end

  test "tracks uploaded size without storing content", %{state: state} do
    {:ok, handle} = Benchmark.open_write("/upload.bin", %{}, %{}, state)
    {:ok, handle} = Benchmark.write_at(handle, 0, :binary.copy("a", 1024), state)
    {:ok, handle} = Benchmark.write_at(handle, 4096, :binary.copy("b", 512), state)

    assert :ok = Benchmark.finish_write(handle, state)

    assert {:ok, {:file_info, 4608, :regular, _, _, _, _, _, _, _, _, _, _, _}} =
             Benchmark.file_info("/upload.bin", state)
  end

  test "returns zero-filled reads bounded by file size", %{state: state} do
    assert :ok = Benchmark.write_file("/download.bin", :binary.copy("x", 4096), state)
    {:ok, handle} = Benchmark.open_read("/download.bin", %{}, state)

    assert {:ok, data} = Benchmark.read_at(handle, 1024, 2048, state)
    assert byte_size(data) == 2048
    assert data == :binary.copy(<<0>>, 2048)

    assert {:ok, data} = Benchmark.read_at(handle, 3072, 4096, state)
    assert byte_size(data) == 1024
    assert :eof = Benchmark.read_at(handle, 4096, 1, state)
  end

  test "supports directory metadata and listing", %{state: state} do
    assert :ok = Benchmark.make_dir("/dir", state)
    assert :ok = Benchmark.write_file("/dir/file.txt", "ignored", state)

    assert {:ok, listing} = Benchmark.list_dir("/dir", state)
    assert ~c"file.txt" in listing

    assert {:ok, attrs} = Benchmark.file_attrs("/dir/file.txt", %{}, state)
    assert attrs.size == 7
    assert attrs.type == :regular
  end

  test "legacy range callback uses the same bounded zero reads", %{state: state} do
    assert :ok = Benchmark.write_file("/range.bin", :binary.copy("x", 100), state)

    assert {:ok, data} = Benchmark.read_file_range("/range.bin", 90, 50, state)
    assert byte_size(data) == 10
    assert data == :binary.copy(<<0>>, 10)

    assert :eof = Benchmark.read_file_range("/range.bin", 100, 1, state)
  end
end
