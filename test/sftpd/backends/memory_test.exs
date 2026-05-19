defmodule Sftpd.Backends.MemoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.Backends.Memory

  setup do
    {:ok, state} = Memory.init([])
    %{state: state}
  end

  describe "init/1" do
    test "starts with empty storage" do
      {:ok, state} = Memory.init([])
      assert {:ok, [~c".", ~c".."]} = Memory.list_dir(~c"/", state)
    end

    test "can be initialized with files" do
      {:ok, state} =
        Memory.init(
          files: %{
            "test.txt" => %{content: "hello", mtime: ~N[2024-01-01 00:00:00]}
          }
        )

      assert {:ok, [~c".", ~c"..", ~c"test.txt"]} = Memory.list_dir(~c"/", state)
    end
  end

  describe "file operations" do
    property "written files can be read back byte-for-byte" do
      check all(files <- map_of(path_generator(), binary(max_length: 128), max_length: 25)) do
        {:ok, state} = Memory.init([])

        for {path, content} <- files do
          assert :ok = Memory.write_file(String.to_charlist(path), content, state)
        end

        for {path, content} <- files do
          assert {:ok, ^content} = Memory.read_file(String.to_charlist(path), state)
        end
      end
    end

    test "write and read file", %{state: state} do
      assert :ok = Memory.write_file(~c"/test.txt", "hello world", state)
      assert {:ok, "hello world"} = Memory.read_file(~c"/test.txt", state)
    end

    test "read non-existent file returns error", %{state: state} do
      assert {:error, :enoent} = Memory.read_file(~c"/nonexistent.txt", state)
    end

    test "delete file", %{state: state} do
      Memory.write_file(~c"/test.txt", "hello", state)
      assert :ok = Memory.delete(~c"/test.txt", state)
      assert {:error, :enoent} = Memory.read_file(~c"/test.txt", state)
    end

    test "rename file", %{state: state} do
      Memory.write_file(~c"/old.txt", "content", state)
      assert :ok = Memory.rename(~c"/old.txt", ~c"/new.txt", state)
      assert {:error, :enoent} = Memory.read_file(~c"/old.txt", state)
      assert {:ok, "content"} = Memory.read_file(~c"/new.txt", state)
    end

    test "rename non-existent source is a no-op", %{state: state} do
      assert :ok = Memory.rename(~c"/nonexistent.txt", ~c"/dest.txt", state)
      assert {:error, :enoent} = Memory.read_file(~c"/dest.txt", state)
    end
  end

  describe "directory operations" do
    property "directory listings expose only immediate children plus dot entries" do
      check all(
              files <-
                map_of(path_generator(), binary(max_length: 16), min_length: 1, max_length: 30),
              dir <- candidate_dirs(files)
            ) do
        {:ok, state} = Memory.init([])

        for {path, content} <- files do
          assert :ok = Memory.write_file(String.to_charlist(path), content, state)
        end

        assert {:ok, listing} = Memory.list_dir(String.to_charlist(dir), state)

        expected_entries =
          files
          |> Map.keys()
          |> immediate_children(dir)
          |> Enum.map(&String.to_charlist/1)

        assert Enum.sort(listing) == Enum.sort([~c".", ~c".." | expected_entries])
      end
    end

    test "make and list directory", %{state: state} do
      assert :ok = Memory.make_dir(~c"/mydir", state)
      assert {:ok, listing} = Memory.list_dir(~c"/", state)
      assert ~c"mydir" in listing
    end

    test "delete directory", %{state: state} do
      Memory.make_dir(~c"/mydir", state)
      assert :ok = Memory.del_dir(~c"/mydir", state)
      assert {:ok, [~c".", ~c".."]} = Memory.list_dir(~c"/", state)
    end

    test "does not delete non-empty directory", %{state: state} do
      Memory.make_dir(~c"/mydir", state)
      Memory.write_file(~c"/mydir/file.txt", "content", state)

      assert {:error, :eexist} = Memory.del_dir(~c"/mydir", state)
      assert {:ok, listing} = Memory.list_dir(~c"/mydir", state)
      assert ~c"file.txt" in listing
    end

    test "does not delete non-empty directory with trailing slash", %{state: state} do
      Memory.make_dir(~c"/mydir", state)
      Memory.write_file(~c"/mydir/file.txt", "content", state)

      assert {:error, :eexist} = Memory.del_dir(~c"/mydir/", state)
      assert {:ok, listing} = Memory.list_dir(~c"/mydir", state)
      assert ~c"file.txt" in listing
    end

    test "directory operations tolerate trailing slashes", %{state: state} do
      assert :ok = Memory.make_dir(~c"/mydir/", state)

      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c"/mydir/", state)

      assert :ok = Memory.del_dir(~c"/mydir/", state)
      assert {:ok, [~c".", ~c".."]} = Memory.list_dir(~c"/", state)
    end

    test "list files in subdirectory", %{state: state} do
      Memory.make_dir(~c"/subdir", state)
      Memory.write_file(~c"/subdir/file1.txt", "a", state)
      Memory.write_file(~c"/subdir/file2.txt", "b", state)

      assert {:ok, listing} = Memory.list_dir(~c"/subdir", state)
      assert ~c"." in listing
      assert ~c".." in listing
      assert ~c"file1.txt" in listing
      assert ~c"file2.txt" in listing
    end

    test "list_dir strips only one copy of a repeated directory prefix", %{state: state} do
      Memory.write_file(~c"/dir/dir/file.txt", "a", state)

      assert {:ok, listing} = Memory.list_dir(~c"/dir", state)
      assert ~c"dir" in listing
      refute ~c"file.txt" in listing
    end
  end

  describe "root path variants" do
    test "list_dir with '.' returns root", %{state: state} do
      Memory.write_file(~c"/test.txt", "hello", state)
      assert {:ok, listing} = Memory.list_dir(~c".", state)
      assert ~c"test.txt" in listing
    end

    test "list_dir with empty path returns root", %{state: state} do
      Memory.write_file(~c"/test.txt", "hello", state)
      assert {:ok, listing} = Memory.list_dir(~c"", state)
      assert ~c"test.txt" in listing
    end

    test "file_info with '.' returns directory", %{state: state} do
      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c".", state)
    end

    test "file_info with empty path returns directory", %{state: state} do
      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c"", state)
    end
  end

  describe "file_info" do
    test "root is always a directory", %{state: state} do
      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c"/", state)
    end

    test "file returns regular type", %{state: state} do
      Memory.write_file(~c"/test.txt", "hello", state)

      assert {:ok, {:file_info, 5, :regular, :read_write, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c"/test.txt", state)
    end

    test "directory returns directory type", %{state: state} do
      Memory.make_dir(~c"/mydir", state)

      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c"/mydir", state)
    end

    test "non-existent returns error", %{state: state} do
      assert {:error, :enoent} = Memory.file_info(~c"/nonexistent", state)
    end
  end

  defp path_generator do
    gen all(segments <- list_of(path_segment(), min_length: 1, max_length: 4)) do
      "/" <> Enum.join(segments, "/")
    end
  end

  defp path_segment do
    string(:alphanumeric, min_length: 1, max_length: 8)
  end

  defp candidate_dirs(files) do
    dirs =
      files
      |> Map.keys()
      |> Enum.flat_map(fn path ->
        path
        |> String.trim_leading("/")
        |> String.split("/")
        |> parent_dirs()
      end)
      |> Enum.uniq()

    StreamData.member_of(["/" | dirs])
  end

  defp parent_dirs([_file]), do: []

  defp parent_dirs(parts) do
    1..(length(parts) - 1)
    |> Enum.map(fn count -> "/" <> (parts |> Enum.take(count) |> Enum.join("/")) end)
  end

  defp immediate_children(paths, dir) do
    prefix = if dir == "/", do: "", else: String.trim_leading(dir, "/") <> "/"

    paths
    |> Enum.flat_map(fn path ->
      path = String.trim_leading(path, "/")

      if String.starts_with?(path, prefix) do
        path
        |> String.replace_prefix(prefix, "")
        |> String.split("/")
        |> case do
          [""] -> []
          [child | _] -> [child]
        end
      else
        []
      end
    end)
    |> Enum.uniq()
  end
end
