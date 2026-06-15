defmodule Sftpd.SFTP.PathsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.SFTP.Paths

  defmodule Backend do
    def file_attrs("/dir", _session, _state), do: {:ok, %{type: :directory}}
    def file_attrs("/file", _session, _state), do: {:ok, %{type: :regular}}
    def file_attrs(_path, _session, _state), do: {:error, :enoent}
  end

  property "open flag predicates only depend on their own bit" do
    check all(flags <- integer(0..0xFFFF)) do
      assert Paths.read_open?(flags) == (Bitwise.band(flags, 0x0001) != 0)
      assert Paths.write_open?(flags) == (Bitwise.band(flags, 0x0002) != 0)
      assert Paths.append_open?(flags) == (Bitwise.band(flags, 0x0004) != 0)
      assert Paths.create_open?(flags) == (Bitwise.band(flags, 0x0008) != 0)
      assert Paths.truncate_open?(flags) == (Bitwise.band(flags, 0x0010) != 0)
      assert Paths.exclusive_open?(flags) == (Bitwise.band(flags, 0x0020) != 0)
    end
  end

  property "realpath normalization returns absolute paths" do
    check all(path <- string(:alphanumeric, max_length: 32)) do
      normalized = Paths.normalize_realpath(path)

      assert String.starts_with?(normalized, "/")
      refute String.starts_with?(normalized, "//")
    end
  end

  test "realpath normalization preserves root" do
    for path <- ["", "/", "////"] do
      assert Paths.normalize_realpath(path) == "/"
    end
  end

  test "request path normalization confines traversal to root" do
    assert Paths.normalize_request_path("/tenant/./a//../file.txt") == "/tenant/file.txt"
    assert Paths.normalize_request_path("/../../file.txt") == "/file.txt"
    assert Paths.normalize_request_path("/a/b/../../..") == "/"
  end

  test "read-open directory rejection only blocks known directories" do
    state = %{backend: Backend, session: %{}, backend_state: %{}}

    assert {:error, :eisdir} = Paths.reject_directory("/dir", state)
    assert :ok = Paths.reject_directory("/file", state)
    assert :ok = Paths.reject_directory("/missing", state)
  end
end
