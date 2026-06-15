defmodule Sftpd.Backends.BenchmarkTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.Backends.Benchmark

  setup do
    {:ok, state} = Benchmark.init([])
    %{state: state}
  end

  property "tracks uploaded size without storing content", %{state: state} do
    check all(
            first_offset <- integer(0..4096),
            first_size <- integer(0..2048),
            second_offset <- integer(0..8192),
            second_size <- integer(0..2048)
          ) do
      {:ok, handle} = Benchmark.open_write("/upload.bin", %{}, %{}, state)

      {:ok, handle} =
        Benchmark.write_at(handle, first_offset, :binary.copy("a", first_size), state)

      {:ok, handle} =
        Benchmark.write_at(handle, second_offset, :binary.copy("b", second_size), state)

      assert :ok = Benchmark.finish_write(handle, state)

      expected_size = max(first_offset + first_size, second_offset + second_size)

      assert {:ok, {:file_info, ^expected_size, :regular, _, _, _, _, _, _, _, _, _, _, _}} =
               Benchmark.file_info("/upload.bin", state)
    end
  end

  test "normalizes configured files and root listings" do
    mtime = ~N[2026-01-02 03:04:05]

    {:ok, state} =
      Benchmark.init(
        files: %{
          "/sized.bin" => %{size: 12, mtime: mtime},
          "/content.bin" => %{content: ["abc", "def"], mtime: mtime},
          "/raw.bin" => "raw"
        }
      )

    assert {:ok, listing} = Benchmark.list_dir("/", state)
    assert ~c"sized.bin" in listing
    assert ~c"content.bin" in listing
    assert ~c"raw.bin" in listing

    assert {:ok, {:file_info, 12, :regular, _, _, _, _, _, _, _, _, _, _, _}} =
             Benchmark.file_info("/sized.bin", state)

    assert {:ok, {:file_info, 6, :regular, _, _, _, _, _, _, _, _, _, _, _}} =
             Benchmark.file_info("/content.bin", state)

    assert {:ok, {:file_info, 3, :regular, _, _, _, _, _, _, _, _, _, _, _}} =
             Benchmark.file_info("/raw.bin", state)
  end

  property "returns zero-filled reads bounded by file size", %{state: state} do
    check all(
            file_size <- integer(1..8192),
            offset <- integer(0..8192),
            len <- integer(0..8192)
          ) do
      assert :ok = Benchmark.write_file("/download.bin", :binary.copy("x", file_size), state)
      {:ok, handle} = Benchmark.open_read("/download.bin", %{}, state)

      expected_size = max(min(len, file_size - offset), 0)

      if offset >= file_size and len > 0 do
        assert :eof = Benchmark.read_at(handle, offset, len, state)
      else
        assert {:ok, data} = Benchmark.read_at(handle, offset, len, state)
        assert byte_size(data) == expected_size
        assert data == :binary.copy(<<0>>, expected_size)
      end
    end
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

  property "legacy range callback uses the same bounded zero reads", %{state: state} do
    check all(
            file_size <- integer(1..8192),
            offset <- integer(0..8192),
            len <- integer(1..8192)
          ) do
      assert :ok = Benchmark.write_file("/range.bin", :binary.copy("x", file_size), state)

      expected_size = max(min(len, file_size - offset), 0)

      if offset >= file_size do
        assert :eof = Benchmark.read_file_range("/range.bin", offset, len, state)
      else
        assert {:ok, data} = Benchmark.read_file_range("/range.bin", offset, len, state)
        assert byte_size(data) == expected_size
        assert data == :binary.copy(<<0>>, expected_size)
      end
    end
  end

  test "whole-file reads return zero-filled binaries and reject directories", %{state: state} do
    assert :ok = Benchmark.write_file("/file.bin", :binary.copy("x", 1_050_000), state)
    assert {:ok, data} = Benchmark.read_file("/file.bin", state)
    assert IO.iodata_length(data) == 1_050_000
    assert IO.iodata_to_binary(data) == :binary.copy(<<0>>, 1_050_000)

    assert :ok = Benchmark.make_dir("/dir", state)
    assert {:error, :eisdir} = Benchmark.read_file("/dir", state)
    assert {:error, :enoent} = Benchmark.read_file("/missing", state)
  end

  test "rename, delete, and directory removal update synthetic metadata", %{state: state} do
    assert :ok = Benchmark.make_dir("/dir", state)
    assert :ok = Benchmark.write_file("/dir/file.txt", "ignored", state)
    assert {:error, :eexist} = Benchmark.del_dir("/dir", state)

    assert :ok = Benchmark.rename("/dir/file.txt", "/dir/renamed.txt", state)
    assert {:error, :enoent} = Benchmark.file_info("/dir/file.txt", state)

    assert {:ok, {:file_info, 7, :regular, _, _, _, _, _, _, _, _, _, _, _}} =
             Benchmark.file_info("/dir/renamed.txt", state)

    assert :ok = Benchmark.delete("/dir/renamed.txt", state)
    assert :ok = Benchmark.del_dir("/dir", state)
  end

  test "rename moves directory markers and children", %{state: state} do
    assert :ok = Benchmark.make_dir("/dir", state)
    assert :ok = Benchmark.write_file("/dir/file.txt", "ignored", state)

    assert :ok = Benchmark.rename("/dir", "/other", state)

    assert {:error, :enoent} = Benchmark.file_info("/dir/file.txt", state)

    assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
             Benchmark.file_info("/other", state)

    assert {:ok, {:file_info, 7, :regular, _, _, _, _, _, _, _, _, _, _, _}} =
             Benchmark.file_info("/other/file.txt", state)
  end

  test "handle callback aliases share the module backend contract", %{state: state} do
    assert :ok = Benchmark.make_dir("/dir", %{}, %{}, state)
    assert :ok = Benchmark.write_file("/dir/file.txt", "ignored", state)
    assert {:ok, dir} = Benchmark.open_dir("/dir", %{}, state)
    assert {:ok, entries, dir} = Benchmark.read_dir(dir, state)
    assert Enum.map(entries, & &1.name) == [".", "..", "file.txt"]
    assert :eof = Benchmark.read_dir(dir, state)
    assert :ok = Benchmark.close_dir(dir, state)

    assert {:ok, writer} = Benchmark.begin_write("/abort.bin", state)
    assert {:ok, writer} = Benchmark.write_chunk(writer, 0, "abc", state)
    assert :ok = Benchmark.abort_write(writer, state)
    assert {:error, :enoent} = Benchmark.open_read("/abort.bin", %{}, state)

    assert :ok = Benchmark.rename("/dir/file.txt", "/dir/moved.txt", %{}, state)
    assert {:error, :enoent} = Benchmark.file_attrs("/dir/file.txt", %{}, state)
    assert {:ok, %{size: 7}} = Benchmark.file_attrs("/dir/moved.txt", %{}, state)
    assert :ok = Benchmark.delete("/dir/moved.txt", %{}, state)
    assert :ok = Benchmark.del_dir("/dir", %{}, state)
  end
end
