defmodule Sftpd.BackendTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.Backend

  describe "path helpers" do
    property "normalize_path removes leading slash runs and preserves the rest" do
      check all(path <- path_string()) do
        expected = String.trim_leading(path, "/")

        assert Backend.normalize_path(path) == expected
        assert Backend.normalize_path(String.to_charlist(path)) == expected
        refute String.starts_with?(Backend.normalize_path(path), "/")
      end
    end

    property "root_path? recognizes only documented root forms among generated paths" do
      root_forms = ["/", "/.", "/..", "..", ".", ""]

      check all(path <- path_string()) do
        assert Backend.root_path?(path) == path in root_forms
        assert Backend.root_path?(String.to_charlist(path)) == path in root_forms
      end
    end
  end

  describe "file attrs helpers" do
    test "round trips regular file_info into fast attrs" do
      info = Backend.file_info(12, {{2024, 1, 1}, {0, 0, 0}}, :read_write)

      assert %{
               size: 12,
               type: :regular,
               permissions: 33188,
               uid: 1,
               gid: 1,
               atime: 1_704_067_200,
               mtime: 1_704_067_200
             } = Backend.attrs_from_file_info(info)
    end

    test "converts fast attrs to OTP file_info" do
      assert {:file_info, 42, :regular, :read_write, _, _, _, 33188, 1, 0, 0, _, 1000, 1000} =
               Backend.file_info_from_attrs(%{
                 size: 42,
                 type: :regular,
                 permissions: 33188,
                 uid: 1000,
                 gid: 1000,
                 mtime: 1_704_067_200
               })
    end

    test "builds directory info and directory attrs with defaults" do
      assert {:file_info, 4096, :directory, :read, _, _, _, 16877, 2, 0, 0, 0, 1, 1} =
               Backend.directory_info()

      assert {:file_info, 0, :directory, :read_write, _, _, _, 16877, 1, 0, 0, _, 1, 1} =
               Backend.file_info_from_attrs(%{type: :directory})
    end

    test "accepts multiple timestamp forms for attrs" do
      naive = ~N[2024-01-02 03:04:05]
      erl = {{2024, 1, 2}, {3, 4, 5}}

      assert Backend.unix_time(naive) == 1_704_164_645
      assert Backend.unix_time(erl) == 1_704_164_645

      assert {:file_info, 0, :regular, :read_write, ^erl, ^erl, ^erl, 33188, 1, 0, 0, _, 1, 1} =
               Backend.file_info_from_attrs(%{mtime: erl})

      assert {:file_info, 0, :regular, :read_write, ^erl, ^erl, ^erl, 33188, 1, 0, 0, _, 1, 1} =
               Backend.file_info_from_attrs(%{mtime: naive})
    end

    test "normalizes unknown file types from OTP file info to regular attrs" do
      info =
        {:file_info, 3, :device, :read, :bad_time, :bad_time, :bad_time, 0o100600, 1, 2, 3, 4, 5,
         6}

      assert %{size: 3, type: :regular, permissions: 0o100600, uid: 5, gid: 6} =
               Backend.attrs_from_file_info(info)
    end

    test "maps file_info access and modification times from their own tuple slots" do
      atime = {{2024, 1, 2}, {3, 4, 5}}
      mtime = {{2024, 1, 3}, {3, 4, 5}}
      info = {:file_info, 1, :regular, :read, atime, mtime, mtime, 0o100600, 1, 2, 3, 4, 5, 6}

      assert %{
               atime: 1_704_164_645,
               mtime: 1_704_251_045,
               uid: 5,
               gid: 6
             } = Backend.attrs_from_file_info(info)
    end
  end

  defp path_string do
    gen all(
          slash_count <- integer(0..4),
          segments <- list_of(string(:alphanumeric, min_length: 1), max_length: 4)
        ) do
      String.duplicate("/", slash_count) <> Enum.join(segments, "/")
    end
  end
end
