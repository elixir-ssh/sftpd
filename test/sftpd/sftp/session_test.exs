defmodule Sftpd.SFTP.SessionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import StreamData, except: [string: 1, string: 2]

  import Bitwise

  alias Sftpd.Backends.Memory
  alias Sftpd.SFTP.SerializedPacket
  alias Sftpd.SFTP.Session

  @ssh_fxp_open 3
  @ssh_fxp_close 4
  @ssh_fxp_read 5
  @ssh_fxp_write 6
  @ssh_fxp_lstat 7
  @ssh_fxp_fstat 8
  @ssh_fxp_setstat 9
  @ssh_fxp_fsetstat 10
  @ssh_fxp_opendir 11
  @ssh_fxp_readdir 12
  @ssh_fxp_remove 13
  @ssh_fxp_mkdir 14
  @ssh_fxp_rmdir 15
  @ssh_fxp_realpath 16
  @ssh_fxp_stat 17
  @ssh_fxp_rename 18
  @ssh_fxp_readlink 19
  @ssh_fxp_symlink 20
  @ssh_fxp_status 101
  @ssh_fxp_handle 102
  @ssh_fxp_data 103
  @ssh_fxp_name 104
  @ssh_fxp_attrs 105

  defmodule ErrorBackend do
    @moduledoc false

    def open_write("/open-write-error", _attrs, _session, _state), do: {:error, :eacces}

    def open_write("/finish-error", _attrs, _session, state),
      do: {:ok, %{path: "/finish-error", finish_error?: true, test_pid: test_pid(state)}}

    def open_write("/write-error", _attrs, _session, _state),
      do: {:ok, %{path: "/write-error", write_error?: true}}

    def open_write("/write-error-after-open", _attrs, _session, _state),
      do: {:ok, %{path: "/write-error-after-open", writes_before_error: 1}}

    def open_write(path, _attrs, _session, _state), do: {:ok, %{path: path}}

    def open_read("/open-read-error", _session, _state), do: {:error, :enoent}

    def open_read("/read-error", _session, _state),
      do: {:ok, %{path: "/read-error", read_error?: true}}

    def open_read("/eof-read", _session, _state),
      do: {:ok, %{path: "/eof-read", eof?: true}}

    def open_read("/empty-read", _session, _state),
      do: {:ok, %{path: "/empty-read", empty?: true}}

    def open_read(path, _session, _state), do: {:ok, %{path: path}}

    def read_at(%{read_error?: true}, _offset, _len, _state), do: {:error, :eacces}
    def read_at(%{eof?: true}, _offset, _len, _state), do: :eof
    def read_at(%{empty?: true}, _offset, _len, _state), do: {:ok, []}
    def read_at(_handle, _offset, _len, _state), do: {:ok, "ok"}

    def write_at(%{write_error?: true}, _offset, _data, _state), do: {:error, :eacces}
    def write_at(%{writes_before_error: 0}, _offset, _data, _state), do: {:error, :eacces}

    def write_at(%{writes_before_error: writes_before_error} = handle, _offset, _data, _state),
      do: {:ok, %{handle | writes_before_error: writes_before_error - 1}}

    def write_at(handle, _offset, _data, _state), do: {:ok, handle}

    def finish_write(%{finish_error?: true}, _state), do: {:error, :eio}
    def finish_write(_handle, _state), do: :ok

    def abort_write(%{path: path, test_pid: test_pid}, _state) when is_pid(test_pid) do
      send(test_pid, {:aborted, path})
      :ok
    end

    def abort_write(_handle, _state), do: :ok

    def file_attrs(path, _session, _state) when path in ["/attrs-error", "/write-error"],
      do: {:error, :enoent}

    def file_attrs("/no-such-file-error", _session, _state), do: {:error, :no_such_file}

    def file_attrs(path, _session, _state)
        when path in ["/open-dir-error", "/read-dir-error", "/close-on-cleanup"],
        do: {:ok, %{type: :directory, size: 0, permissions: 0o040755}}

    def file_attrs(_path, _session, _state),
      do: {:ok, %{type: :regular, size: 2, permissions: 0o100644}}

    def open_dir("/open-dir-error", _session, _state), do: {:error, :enoent}

    def open_dir("/read-dir-error", _session, test_pid) when is_pid(test_pid),
      do: {:ok, %{read_error?: true, test_pid: test_pid}}

    def open_dir("/read-dir-error", _session, _state), do: {:ok, %{read_error?: true}}
    def open_dir("/close-on-cleanup", _session, test_pid), do: {:ok, %{test_pid: test_pid}}
    def open_dir(_path, _session, _state), do: {:ok, %{}}

    def read_dir(%{read_error?: true, test_pid: test_pid} = handle, _state) do
      send(test_pid, {:read_dir_error, handle})
      {:error, :eacces}
    end

    def read_dir(%{read_error?: true}, _state), do: {:error, :eacces}
    def read_dir(handle, _state), do: {:ok, [], handle}

    def close_dir(%{test_pid: test_pid} = handle, _state) do
      send(test_pid, {:closed_dir, handle})
      :ok
    end

    def close_dir(_handle, _state), do: :ok

    def make_dir("/mkdir-error", _attrs, _session, _state), do: {:error, :eacces}
    def make_dir(_path, _attrs, _session, _state), do: :ok

    def del_dir("/rmdir-error", _session, _state), do: {:error, :eacces}
    def del_dir(_path, _session, _state), do: :ok

    def delete("/remove-error", _session, _state), do: {:error, :eacces}
    def delete(_path, _session, _state), do: :ok

    def rename("/rename-error", _newpath, _session, _state), do: {:error, :eacces}
    def rename(_oldpath, _newpath, _session, _state), do: :ok

    defp test_pid(pid) when is_pid(pid), do: pid
    defp test_pid(_state), do: nil
  end

  defmodule AbortBackend do
    @moduledoc false

    def open_write(path, _attrs, _session, test_pid), do: {:ok, %{path: path, test_pid: test_pid}}
    def write_at(handle, _offset, _data, _state), do: {:ok, handle}
    def finish_write(_handle, _state), do: :ok

    def abort_write(%{path: path, test_pid: test_pid}, _state) do
      send(test_pid, {:aborted, path})
      :ok
    end

    def open_read(_path, _session, _state), do: {:error, :enoent}
    def read_at(_handle, _offset, _len, _state), do: :eof

    def open_dir("/close-on-cleanup", _session, test_pid),
      do: {:ok, %{path: "/close-on-cleanup", test_pid: test_pid}}

    def open_dir(_path, _session, _state), do: {:error, :enoent}

    def read_dir(_handle, _state), do: :eof

    def close_dir(%{path: path, test_pid: test_pid}, _state) do
      send(test_pid, {:closed_dir, path})
      :ok
    end

    def close_dir(_handle, _state), do: :ok

    def file_attrs("/close-on-cleanup", _session, _state),
      do: {:ok, %{type: :directory, size: 0}}

    def file_attrs(_path, _session, _state), do: {:ok, %{type: :regular, size: 0}}
    def make_dir(_path, _attrs, _session, _state), do: :ok
    def del_dir(_path, _session, _state), do: :ok
    def delete(_path, _session, _state), do: :ok
    def rename(_oldpath, _newpath, _session, _state), do: :ok
  end

  defmodule ReadLenBackend do
    @moduledoc false

    def open_read(path, _session, test_pid), do: {:ok, %{path: path, test_pid: test_pid}}

    def read_at(%{test_pid: test_pid}, _offset, len, _state) do
      send(test_pid, {:read_len, len})
      :eof
    end

    def file_attrs(_path, _session, _state), do: {:ok, %{type: :regular, size: 8_000_000}}
  end

  defmodule IodataSeedBackend do
    @moduledoc false

    @seed_data ["ab", ["cd"]]

    def open_read("/seeded.txt", _session, _state), do: {:ok, :reader}
    def open_read(_path, _session, _state), do: {:error, :enoent}

    def read_at(:reader, 0, _len, _state), do: {:ok, @seed_data}
    def read_at(:reader, _offset, _len, _state), do: :eof

    def open_write("/seeded.txt", _attrs, _session, test_pid), do: {:ok, {:writer, test_pid}}

    def write_at({:writer, test_pid} = handle, offset, data, _state) do
      send(test_pid, {:seed_write, offset, data, IO.iodata_length(data), is_binary(data)})
      {:ok, handle}
    end

    def finish_write(_handle, _state), do: :ok
    def abort_write(_handle, _state), do: :ok

    def file_attrs("/seeded.txt", _session, _state),
      do: {:ok, %{type: :regular, size: IO.iodata_length(@seed_data), permissions: 0o100644}}
  end

  setup do
    {:ok, backend_state} = Memory.init([])

    session =
      Memory
      |> Session.new(backend_state, %{username: "test"})
      |> Map.put(:initialized?, true)

    %{session: session}
  end

  test "rejects non-init packets before version negotiation" do
    {:ok, backend_state} = Memory.init([])
    session = Session.new(Memory, backend_state, %{username: "test"})

    {response, session} = handle(open(1, "/hello.txt", 0x0000_0001), session)
    assert {:status, 1, 5} = decode_response(response)
    refute session.initialized?

    {response, session} = handle(init(), session)
    assert {:version, 3} = decode_response(response)
    assert session.initialized?
  end

  test "malformed packets before version negotiation return bad message" do
    {:ok, backend_state} = Memory.init([])
    session = Session.new(Memory, backend_state)

    {response, session} = Session.handle_packet(<<255>>, session)

    assert {:status, 0, 5} = decode_response(response)
    refute session.initialized?
  end

  test "writes and reads a file through opaque session handles", %{session: session} do
    {response, session} = handle(open(1, "/hello.txt", 0x0000_000A), session)
    assert {:handle, 1, write_handle} = decode_response(response)

    {response, session} = handle(write(2, write_handle, 0, "hello"), session)
    assert {:status, 2, 0} = decode_response(response)

    {response, session} = handle(close(3, write_handle), session)
    assert {:status, 3, 0} = decode_response(response)

    {response, session} = handle(open(4, "/hello.txt", 0x0000_0001), session)
    assert {:handle, 4, read_handle} = decode_response(response)

    {response, session} = handle(read(5, read_handle, 0, 64), session)
    assert {:data, 5, "hello"} = decode_response(response)

    {response, session} = handle(read(6, read_handle, 5, 64), session)
    assert {:status, 6, 1} = decode_response(response)

    {response, _session} = handle(close(7, read_handle), session)
    assert {:status, 7, 0} = decode_response(response)
  end

  test "normalizes traversal paths before backend operations", %{session: session} do
    {response, session} = handle(open(1, "/dir/../safe.txt", 0x0000_000A), session)
    assert {:handle, 1, write_handle} = decode_response(response)

    {_response, session} = handle(write(2, write_handle, 0, "safe"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/safe.txt", 0x0000_0001), session)
    assert {:handle, 4, read_handle} = decode_response(response)

    {response, _session} = handle(read(5, read_handle, 0, 16), session)
    assert {:data, 5, "safe"} = decode_response(response)
  end

  test "rejects traversal-normalized root mutation targets", %{session: session} do
    {response, session} = handle(open(1, "/file.txt", 0x0000_000A), session)
    assert {:handle, 1, write_handle} = decode_response(response)

    {_response, session} = handle(write(2, write_handle, 0, "safe"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(path_packet(@ssh_fxp_rmdir, 4, "/dir/.."), session)
    assert {:status, 4, 4} = decode_response(response)

    {response, session} = handle(rename(5, "/file.txt", "/dir/.."), session)
    assert {:status, 5, 4} = decode_response(response)

    {response, session} = handle(open(6, "/file.txt", 0x0000_0001), session)
    assert {:handle, 6, read_handle} = decode_response(response)

    {response, _session} = handle(read(7, read_handle, 0, 16), session)
    assert {:data, 7, "safe"} = decode_response(response)
  end

  test "rejects new handles after the session handle limit is reached" do
    {:ok, backend_state} = Memory.init([])

    session =
      Memory
      |> Session.new(backend_state, %{username: "test"}, max_handles: 1)
      |> Map.put(:initialized?, true)

    {response, session} = handle(open(1, "/first.txt", 0x0000_000A), session)
    assert {:handle, 1, _write_handle} = decode_response(response)

    {response, session} = handle(open(2, "/second.txt", 0x0000_000A), session)

    assert {:status, 2, 4} = decode_response(response)
    assert map_size(session.handles) == 1
  end

  test "writes sparse offsets without discarding earlier chunks", %{session: session} do
    {response, session} = handle(open(1, "/sparse.bin", 0x0000_000A), session)
    {:handle, 1, handle} = decode_response(response)

    {_response, session} = handle(write(2, handle, 4, "tail"), session)
    {_response, session} = handle(write(3, handle, 0, "head"), session)
    {_response, session} = handle(close(4, handle), session)

    {response, session} = handle(open(5, "/sparse.bin", 0x0000_0001), session)
    {:handle, 5, read_handle} = decode_response(response)

    {response, _session} = handle(read(6, read_handle, 0, 8), session)
    assert {:data, 6, "headtail"} = decode_response(response)
  end

  test "append opens write at the current end of file", %{session: session} do
    {response, session} = handle(open(1, "/append.txt", 0x0000_000A), session)
    {:handle, 1, handle} = decode_response(response)
    {_response, session} = handle(write(2, handle, 0, "base"), session)
    {_response, session} = handle(close(3, handle), session)

    {response, session} = handle(open(4, "/append.txt", 0x0000_000E), session)
    {:handle, 4, append_handle} = decode_response(response)
    {_response, session} = handle(write(5, append_handle, 0, "tail"), session)
    {_response, session} = handle(close(6, append_handle), session)

    {response, session} = handle(open(7, "/append.txt", 0x0000_0001), session)
    {:handle, 7, read_handle} = decode_response(response)
    {response, _session} = handle(read(8, read_handle, 0, 16), session)
    assert {:data, 8, "basetail"} = decode_response(response)
  end

  test "truncate wins over append for write opens", %{session: session} do
    {response, session} = handle(open(1, "/append-truncate.txt", 0x0000_000A), session)
    {:handle, 1, handle} = decode_response(response)
    {_response, session} = handle(write(2, handle, 0, "base"), session)
    {_response, session} = handle(close(3, handle), session)

    {response, session} = handle(open(4, "/append-truncate.txt", 0x0000_001E), session)
    {:handle, 4, append_handle} = decode_response(response)
    {_response, session} = handle(write(5, append_handle, 123, "tail"), session)
    {_response, session} = handle(close(6, append_handle), session)

    {response, session} = handle(open(7, "/append-truncate.txt", 0x0000_0001), session)
    {:handle, 7, read_handle} = decode_response(response)
    {response, _session} = handle(read(8, read_handle, 0, 16), session)
    assert {:data, 8, "tail"} = decode_response(response)
  end

  test "write-only update opens preserve existing content", %{session: session} do
    {response, session} = handle(open(1, "/update.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "abcdef"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/update.txt", 0x0000_0002), session)
    assert {:handle, 4, update_handle} = decode_response(response)
    {_response, session} = handle(write(5, update_handle, 2, "XY"), session)
    {_response, session} = handle(close(6, update_handle), session)

    {response, session} = handle(open(7, "/update.txt", 0x0000_0001), session)
    {:handle, 7, read_handle} = decode_response(response)

    {response, _session} = handle(read(8, read_handle, 0, 16), session)
    assert {:data, 8, "abXYef"} = decode_response(response)
  end

  test "write-only update seeding passes backend iodata through without flattening" do
    session =
      IodataSeedBackend
      |> Session.new(self(), %{username: "test"})
      |> Map.put(:initialized?, true)

    {response, _session} = handle(open(1, "/seeded.txt", 0x0000_0002), session)

    assert {:handle, 1, _handle} = decode_response(response)
    assert_receive {:seed_write, 0, ["ab", ["cd"]], 4, false}
  end

  test "write opens without create require existing files", %{session: session} do
    {response, session} = handle(open(1, "/missing-write.txt", 0x0000_0002), session)
    assert {:status, 1, 2} = decode_response(response)

    {response, _session} = handle(open(2, "/missing-mixed.txt", 0x0000_0003), session)
    assert {:status, 2, 2} = decode_response(response)
  end

  test "cleanup_open_handles aborts pending write handles" do
    session =
      AbortBackend |> Session.new(self(), %{username: "test"}) |> Map.put(:initialized?, true)

    {response, session} = handle(open(1, "/pending.txt", 0x0000_000A), session)
    {:handle, 1, _handle} = decode_response(response)

    session = Session.cleanup_open_handles(session)

    assert session.handles == %{}
    assert_receive {:aborted, "/pending.txt"}
  end

  test "cleanup_open_handles aborts writes closes directories and leaves read handles alone", %{
    session: session
  } do
    {response, session} = handle(open(1, "/read.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "read"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/read.txt", 0x0000_0001), session)
    assert {:handle, 4, _read_handle} = decode_response(response)

    abort_session =
      AbortBackend
      |> Session.new(self(), %{username: "test"})
      |> Map.put(:initialized?, true)

    {response, abort_session} = handle(open(5, "/mixed.txt", 0x0000_000B), abort_session)
    assert {:handle, 5, _mixed_handle} = decode_response(response)

    {response, abort_session} = handle(opendir(6, "/close-on-cleanup"), abort_session)
    assert {:handle, 6, _dir_handle} = decode_response(response)

    session = %{abort_session | handles: Map.merge(abort_session.handles, session.handles)}
    session = Session.cleanup_open_handles(session)

    assert session.handles == %{}
    assert_receive {:aborted, "/mixed.txt"}
    assert_receive {:closed_dir, "/close-on-cleanup"}
  end

  test "directory handles return one listing and then eof", %{session: session} do
    {_response, session} = handle(mkdir(1, "/dir"), session)

    {response, session} = handle(open(2, "/dir/file.txt", 0x0000_000A), session)
    {:handle, 2, file_handle} = decode_response(response)
    {_response, session} = handle(write(3, file_handle, 0, "data"), session)
    {_response, session} = handle(close(4, file_handle), session)

    {response, session} = handle(opendir(5, "/dir"), session)
    assert {:handle, 5, dir_handle} = decode_response(response)

    {response, session} = handle(readdir(6, dir_handle), session)
    assert {:name, 6, names} = decode_response(response)
    assert "." in names
    assert ".." in names
    assert "file.txt" in names

    {response, session} = handle(readdir(7, dir_handle), session)
    assert {:status, 7, 1} = decode_response(response)

    {response, _session} = handle(close(8, dir_handle), session)
    assert {:status, 8, 0} = decode_response(response)
  end

  test "realpath returns an absolute path", %{session: session} do
    {response, _session} = handle(realpath(1, "dir/file.txt"), session)
    assert {:name, 1, ["/dir/file.txt"]} = decode_response(response)
  end

  test "stat and fstat return attrs for paths and open file handles", %{session: session} do
    {response, session} = handle(open(1, "/file.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "abc"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(path_packet(@ssh_fxp_stat, 4, "/file.txt"), session)
    assert {:attrs, 4, %{size: 3}} = decode_response(response)

    {response, session} = handle(path_packet(@ssh_fxp_lstat, 5, "/file.txt"), session)
    assert {:attrs, 5, %{size: 3}} = decode_response(response)

    {response, session} = handle(open(6, "/file.txt", 0x0000_0001), session)
    {:handle, 6, read_handle} = decode_response(response)

    {response, _session} = handle(handle_packet(@ssh_fxp_fstat, 7, read_handle), session)
    assert {:attrs, 7, %{size: 3}} = decode_response(response)
  end

  test "mutation operations return backend statuses", %{session: session} do
    {_response, session} = handle(mkdir(1, "/dir"), session)

    {response, session} = handle(open(2, "/dir/file.txt", 0x0000_000A), session)
    {:handle, 2, handle} = decode_response(response)
    {_response, session} = handle(write(3, handle, 0, "data"), session)
    {_response, session} = handle(close(4, handle), session)

    {response, session} = handle(rename(5, "/dir/file.txt", "/dir/renamed.txt"), session)
    assert {:status, 5, 0} = decode_response(response)

    {response, session} = handle(path_packet(@ssh_fxp_remove, 6, "/dir/renamed.txt"), session)
    assert {:status, 6, 0} = decode_response(response)

    {response, _session} = handle(path_packet(@ssh_fxp_rmdir, 7, "/dir"), session)
    assert {:status, 7, 0} = decode_response(response)
  end

  test "path operations enforce file and directory target types", %{session: session} do
    {_response, session} = handle(mkdir(1, "/dir"), session)

    {response, session} = handle(open(2, "/file.txt", 0x0000_000A), session)
    {:handle, 2, file_handle} = decode_response(response)
    {_response, session} = handle(write(3, file_handle, 0, "data"), session)
    {_response, session} = handle(close(4, file_handle), session)

    for {packet, id} <- [
          {open(5, "/dir", 0x0000_0012), 5},
          {opendir(6, "/file.txt"), 6},
          {mkdir(7, "/file.txt"), 7},
          {mkdir(8, "/dir"), 8},
          {path_packet(@ssh_fxp_rmdir, 9, "/file.txt"), 9},
          {path_packet(@ssh_fxp_remove, 10, "/dir"), 10},
          {open(11, "/dir", 0x0000_0001), 11}
        ] do
      {response, _session} = handle(packet, session)
      assert {:status, ^id, 4} = decode_response(response)
    end
  end

  test "create and truncate flags do not grant write access", %{session: session} do
    for {packet, id} <- [
          {open(1, "/created-without-write.txt", 0x0000_0008), 1},
          {open(2, "/truncated-without-write.txt", 0x0000_0010), 2}
        ] do
      {response, _session} = handle(packet, session)
      assert {:status, ^id, 8} = decode_response(response)
    end
  end

  test "invalid handles and unsupported requests return status failures", %{session: session} do
    for packet <- [
          close(1, "missing"),
          read(2, "missing", 0, 1),
          write(3, "missing", 0, "x"),
          handle_packet(@ssh_fxp_fstat, 4, "missing"),
          readdir(5, "missing")
        ] do
      {response, _session} = handle(packet, session)
      assert {:status, _id, 4} = decode_response(response)
    end

    for packet <- [
          open(6, "/file", 0),
          path_packet(@ssh_fxp_readlink, 7, "/link"),
          attrs_packet(@ssh_fxp_setstat, 8, "/file"),
          attrs_packet(@ssh_fxp_fsetstat, 9, "handle"),
          rename_like(@ssh_fxp_symlink, 10, "/target", "/link")
        ] do
      {response, _session} = handle(packet, session)
      assert {:status, _id, 8} = decode_response(response)
    end

    {response, _session} = Session.handle_packet(<<255>>, session)
    assert {:status, 0, 5} = decode_response(response)
  end

  test "mixed read/write opens keep the write side usable for official clients", %{
    session: session
  } do
    {response, session} = handle(open(1, "/file.txt", 0x0000_000B), session)
    assert {:handle, 1, mixed_handle} = decode_response(response)

    {response, session} = handle(write(2, mixed_handle, 0, "mixed"), session)
    assert {:status, 2, 0} = decode_response(response)

    {response, session} = handle(close(3, mixed_handle), session)
    assert {:status, 3, 0} = decode_response(response)

    {response, session} = handle(open(4, "/file.txt", 0x0000_0001), session)
    assert {:handle, 4, read_handle} = decode_response(response)

    {response, _session} = handle(read(5, read_handle, 0, 16), session)
    assert {:data, 5, "mixed"} = decode_response(response)
  end

  test "mixed read/write opens read accepted writes before close", %{session: session} do
    {response, session} = handle(open(1, "/scratch.txt", 0x0000_000B), session)
    assert {:handle, 1, mixed_handle} = decode_response(response)

    {response, session} = handle(write(2, mixed_handle, 0, "abc"), session)
    assert {:status, 2, 0} = decode_response(response)

    {response, session} = handle(read(3, mixed_handle, 0, 3), session)
    assert {:data, 3, "abc"} = decode_response(response)

    {response, _session} = handle(close(4, mixed_handle), session)
    assert {:status, 4, 0} = decode_response(response)
  end

  test "mixed read/write overlay temp files are private and removed on close", %{
    session: session
  } do
    {response, session} = handle(open(1, "/private-overlay.txt", 0x0000_000B), session)
    assert {:handle, 1, mixed_handle} = decode_response(response)

    assert {:file, :read_write, _path, _read_handle, _write_handle, _append_offset, _dirty?,
            %{path: overlay_path}, _size} = session.handles[mixed_handle]

    assert {:ok, %{access: :read_write, mode: mode, type: :regular}} = File.stat(overlay_path)
    assert (mode &&& 0o777) == 0o600

    {response, _session} = handle(close(2, mixed_handle), session)
    assert {:status, 2, 0} = decode_response(response)
    refute File.exists?(overlay_path)
  end

  test "mixed read/write opens can read existing content", %{session: session} do
    {response, session} = handle(open(1, "/file.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "old"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/file.txt", 0x0000_0003), session)
    assert {:handle, 4, mixed_handle} = decode_response(response)

    {response, session} = handle(read(5, mixed_handle, 0, 16), session)
    assert {:data, 5, "old"} = decode_response(response)

    {response, _session} = handle(handle_packet(@ssh_fxp_fstat, 6, mixed_handle), session)
    assert {:attrs, 6, %{size: 3}} = decode_response(response)
  end

  test "mixed append opens read base content plus appended writes before close", %{
    session: session
  } do
    {response, session} = handle(open(1, "/append-read.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "base"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/append-read.txt", 0x0000_0007), session)
    assert {:handle, 4, mixed_handle} = decode_response(response)

    {response, session} = handle(write(5, mixed_handle, 0, "tail"), session)
    assert {:status, 5, 0} = decode_response(response)

    {response, session} = handle(read(6, mixed_handle, 0, 16), session)
    assert {:data, 6, "basetail"} = decode_response(response)

    {response, session} = handle(close(7, mixed_handle), session)
    assert {:status, 7, 0} = decode_response(response)

    {response, session} = handle(open(8, "/append-read.txt", 0x0000_0001), session)
    assert {:handle, 8, read_handle} = decode_response(response)

    {response, _session} = handle(read(9, read_handle, 0, 16), session)
    assert {:data, 9, "basetail"} = decode_response(response)
  end

  test "truncate wins over append for mixed read/write opens", %{session: session} do
    {response, session} = handle(open(1, "/mixed-append-truncate.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "base"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/mixed-append-truncate.txt", 0x0000_001F), session)
    assert {:handle, 4, mixed_handle} = decode_response(response)

    {response, session} = handle(read(5, mixed_handle, 0, 16), session)
    assert {:status, 5, 1} = decode_response(response)

    {response, session} = handle(write(6, mixed_handle, 123, "tail"), session)
    assert {:status, 6, 0} = decode_response(response)

    {response, session} = handle(close(7, mixed_handle), session)
    assert {:status, 7, 0} = decode_response(response)

    {response, session} = handle(open(8, "/mixed-append-truncate.txt", 0x0000_0001), session)
    assert {:handle, 8, read_handle} = decode_response(response)

    {response, _session} = handle(read(9, read_handle, 0, 16), session)
    assert {:data, 9, "tail"} = decode_response(response)
  end

  test "closing untouched mixed read/write opens does not truncate existing content", %{
    session: session
  } do
    {response, session} = handle(open(1, "/file.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "old"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/file.txt", 0x0000_0003), session)
    assert {:handle, 4, mixed_handle} = decode_response(response)

    {response, session} = handle(read(5, mixed_handle, 0, 16), session)
    assert {:data, 5, "old"} = decode_response(response)

    {response, session} = handle(close(6, mixed_handle), session)
    assert {:status, 6, 0} = decode_response(response)

    {response, session} = handle(open(7, "/file.txt", 0x0000_0001), session)
    assert {:handle, 7, read_handle} = decode_response(response)

    {response, _session} = handle(read(8, read_handle, 0, 16), session)
    assert {:data, 8, "old"} = decode_response(response)
  end

  test "closing untouched truncating mixed read/write opens truncates content", %{
    session: session
  } do
    {response, session} = handle(open(1, "/truncate.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "old"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/truncate.txt", 0x0000_0013), session)
    assert {:handle, 4, mixed_handle} = decode_response(response)

    {response, session} = handle(close(5, mixed_handle), session)
    assert {:status, 5, 0} = decode_response(response)

    {response, session} = handle(open(6, "/truncate.txt", 0x0000_0001), session)
    assert {:handle, 6, read_handle} = decode_response(response)

    {response, _session} = handle(read(7, read_handle, 0, 16), session)
    assert {:status, 7, 1} = decode_response(response)
  end

  test "mixed read/write overwrites preserve existing prefix and suffix", %{session: session} do
    {response, session} = handle(open(1, "/file.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "abcdef"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/file.txt", 0x0000_0003), session)
    assert {:handle, 4, mixed_handle} = decode_response(response)

    {response, session} = handle(write(5, mixed_handle, 2, "XY"), session)
    assert {:status, 5, 0} = decode_response(response)

    {response, session} = handle(read(6, mixed_handle, 0, 16), session)
    assert {:data, 6, "abXYef"} = decode_response(response)

    {response, session} = handle(close(7, mixed_handle), session)
    assert {:status, 7, 0} = decode_response(response)

    {response, session} = handle(open(8, "/file.txt", 0x0000_0001), session)
    assert {:handle, 8, read_handle} = decode_response(response)

    {response, _session} = handle(read(9, read_handle, 0, 16), session)
    assert {:data, 9, "abXYef"} = decode_response(response)
  end

  test "mixed read/write sparse writes read as zero-filled gaps before close", %{
    session: session
  } do
    {response, session} = handle(open(1, "/sparse-mixed.bin", 0x0000_000B), session)
    assert {:handle, 1, mixed_handle} = decode_response(response)

    {response, session} = handle(write(2, mixed_handle, 4, "tail"), session)
    assert {:status, 2, 0} = decode_response(response)

    {response, session} = handle(read(3, mixed_handle, 0, 8), session)
    assert {:data, 3, <<0, 0, 0, 0, "tail">>} = decode_response(response)

    {response, session} = handle(close(4, mixed_handle), session)
    assert {:status, 4, 0} = decode_response(response)

    {response, session} = handle(open(5, "/sparse-mixed.bin", 0x0000_0001), session)
    assert {:handle, 5, read_handle} = decode_response(response)

    {response, _session} = handle(read(6, read_handle, 0, 8), session)
    assert {:data, 6, <<0, 0, 0, 0, "tail">>} = decode_response(response)
  end

  test "mixed read/write reads treat backend eof as zero-filled base data" do
    session =
      ErrorBackend |> Session.new(%{}, %{username: "test"}) |> Map.put(:initialized?, true)

    {response, session} = handle(open(1, "/eof-read", 0x0000_0003), session)
    assert {:handle, 1, mixed_handle} = decode_response(response)

    {response, _session} = handle(read(2, mixed_handle, 0, 2), session)
    assert {:data, 2, <<0, 0>>} = decode_response(response)
  end

  test "mixed read/write merges overlapping dirty ranges before read", %{session: session} do
    {response, session} = handle(open(1, "/merged-ranges.bin", 0x0000_000B), session)
    assert {:handle, 1, mixed_handle} = decode_response(response)

    {response, session} = handle(write(2, mixed_handle, 0, "abcd"), session)
    assert {:status, 2, 0} = decode_response(response)

    {response, session} = handle(write(3, mixed_handle, 2, "XY"), session)
    assert {:status, 3, 0} = decode_response(response)

    {response, _session} = handle(read(4, mixed_handle, 0, 4), session)
    assert {:data, 4, "abXY"} = decode_response(response)
  end

  test "truncating mixed read/write opens read only new writes", %{session: session} do
    {response, session} = handle(open(1, "/truncate-rewrite.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "old"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/truncate-rewrite.txt", 0x0000_0013), session)
    assert {:handle, 4, mixed_handle} = decode_response(response)

    {response, session} = handle(read(5, mixed_handle, 0, 1), session)
    assert {:status, 5, 1} = decode_response(response)

    {response, session} = handle(write(6, mixed_handle, 0, "new"), session)
    assert {:status, 6, 0} = decode_response(response)

    {response, session} = handle(read(7, mixed_handle, 0, 16), session)
    assert {:data, 7, "new"} = decode_response(response)

    {response, session} = handle(close(8, mixed_handle), session)
    assert {:status, 8, 0} = decode_response(response)

    {response, session} = handle(open(9, "/truncate-rewrite.txt", 0x0000_0001), session)
    assert {:handle, 9, read_handle} = decode_response(response)

    {response, _session} = handle(read(10, read_handle, 0, 16), session)
    assert {:data, 10, "new"} = decode_response(response)
  end

  test "exclusive create rejects existing files", %{session: session} do
    {response, session} = handle(open(1, "/exclusive.txt", 0x0000_000A), session)
    {:handle, 1, write_handle} = decode_response(response)
    {_response, session} = handle(write(2, write_handle, 0, "old"), session)
    {_response, session} = handle(close(3, write_handle), session)

    {response, session} = handle(open(4, "/exclusive.txt", 0x0000_002A), session)
    assert {:status, 4, 4} = decode_response(response)

    {response, session} = handle(open(5, "/new-exclusive.txt", 0x0000_002A), session)
    assert {:handle, 5, exclusive_handle} = decode_response(response)

    {response, _session} = handle(close(6, exclusive_handle), session)
    assert {:status, 6, 0} = decode_response(response)
  end

  test "read requests are capped before backend dispatch" do
    session =
      ReadLenBackend |> Session.new(self(), %{username: "test"}) |> Map.put(:initialized?, true)

    {response, session} = handle(open(1, "/huge-read.bin", 0x0000_0001), session)
    assert {:handle, 1, read_handle} = decode_response(response)

    {response, _session} = handle(read(2, read_handle, 0, 0xFFFF_FFFF), session)
    assert {:status, 2, 1} = decode_response(response)
    assert_receive {:read_len, 1_048_576}
  end

  test "mixed append opens missing files without crashing", %{session: session} do
    {response, session} = handle(open(1, "/missing-append.txt", 0x0000_000E), session)
    assert {:handle, 1, append_handle} = decode_response(response)

    {response, session} = handle(write(2, append_handle, 0, "new"), session)
    assert {:status, 2, 0} = decode_response(response)

    {response, _session} = handle(close(3, append_handle), session)
    assert {:status, 3, 0} = decode_response(response)
  end

  property "fstat returns pending attrs for write handles before close", %{session: session} do
    check all(
            offset <- integer(0..64),
            data <- binary(min_length: 1, max_length: 128)
          ) do
      expected_size = offset + byte_size(data)

      {response, session} = handle(open(1, "/open-write.txt", 0x0000_000A), session)
      {:handle, 1, write_handle} = decode_response(response)

      {response, session} = handle(handle_packet(@ssh_fxp_fstat, 2, write_handle), session)
      {write_response, session} = handle(write(3, write_handle, offset, data), session)

      {pending_response, _session} =
        handle(handle_packet(@ssh_fxp_fstat, 4, write_handle), session)

      assert {:attrs, 2, %{size: 0, permissions: 0o100644}} = decode_response(response)
      assert {:status, 3, 0} = decode_response(write_response)

      assert {:attrs, 4, %{size: ^expected_size, permissions: 0o100644}} =
               decode_response(pending_response)
    end
  end

  test "backend open and file operation errors are returned as SFTP statuses" do
    session =
      ErrorBackend |> Session.new(%{}, %{username: "test"}) |> Map.put(:initialized?, true)

    {response, session} = handle(open(1, "/open-write-error", 0x0000_000A), session)
    assert {:status, 1, 3} = decode_response(response)

    {response, session} = handle(open(2, "/open-read-error", 0x0000_0001), session)
    assert {:status, 2, 2} = decode_response(response)

    {response, session} = handle(open(3, "/finish-error", 0x0000_000A), session)
    {:handle, 3, finish_handle} = decode_response(response)
    {response, session} = handle(close(4, finish_handle), session)
    assert {:status, 4, 4} = decode_response(response)

    {response, session} = handle(open(13, "/finish-error", 0x0000_0003), session)
    {:handle, 13, mixed_finish_handle} = decode_response(response)
    {response, session} = handle(write(14, mixed_finish_handle, 0, "x"), session)
    assert {:status, 14, 0} = decode_response(response)
    {response, session} = handle(close(15, mixed_finish_handle), session)
    assert {:status, 15, 4} = decode_response(response)

    {response, session} = handle(open(5, "/read-error", 0x0000_0001), session)
    {:handle, 5, read_handle} = decode_response(response)
    {response, session} = handle(read(6, read_handle, 0, 1), session)
    assert {:status, 6, 3} = decode_response(response)

    {response, session} = handle(open(15, "/read-error", 0x0000_0003), session)
    {:handle, 15, read_error_handle} = decode_response(response)
    {response, session} = handle(read(16, read_error_handle, 0, 1), session)
    assert {:status, 16, 3} = decode_response(response)

    {response, session} = handle(open(17, "/open-read-error", 0x0000_0003), session)
    assert {:status, 17, 4} = decode_response(response)

    {response, session} = handle(open(25, "/open-read-error", 0x0000_0006), session)
    assert {:status, 25, 2} = decode_response(response)

    {response, session} = handle(open(11, "/empty-read", 0x0000_0001), session)
    {:handle, 11, empty_handle} = decode_response(response)
    {response, session} = handle(read(12, empty_handle, 0, 1), session)
    assert {:status, 12, 1} = decode_response(response)

    {response, session} = handle(open(7, "/write-error", 0x0000_000A), session)
    {:handle, 7, write_handle} = decode_response(response)
    {response, session} = handle(write(8, write_handle, 0, "x"), session)
    assert {:status, 8, 3} = decode_response(response)
    {response, session} = handle(close(9, write_handle), session)
    assert {:status, 9, 4} = decode_response(response)

    {response, session} = handle(open(19, "/write-error", 0x0000_000B), session)
    {:handle, 19, mixed_error_handle} = decode_response(response)
    {response, session} = handle(write(20, mixed_error_handle, 0, "x"), session)
    assert {:status, 20, 0} = decode_response(response)
    {response, session} = handle(close(21, mixed_error_handle), session)
    assert {:status, 21, 3} = decode_response(response)

    {response, session} = handle(open(22, "/write-error-after-open", 0x0000_0003), session)
    {:handle, 22, mixed_write_handle} = decode_response(response)
    {response, session} = handle(write(23, mixed_write_handle, 0, "x"), session)
    assert {:status, 23, 0} = decode_response(response)
    {response, session} = handle(close(24, mixed_write_handle), session)
    assert {:status, 24, 0} = decode_response(response)

    {response, session} = handle(open(9, "/attrs-error", 0x0000_0001), session)
    {:handle, 9, attrs_handle} = decode_response(response)
    {response, _session} = handle(handle_packet(@ssh_fxp_fstat, 10, attrs_handle), session)
    assert {:status, 10, 2} = decode_response(response)
  end

  test "close-time write finalization failures abort backend writers" do
    session =
      ErrorBackend |> Session.new(self(), %{username: "test"}) |> Map.put(:initialized?, true)

    {response, session} = handle(open(1, "/finish-error", 0x0000_000A), session)
    assert {:handle, 1, write_handle} = decode_response(response)

    {response, session} = handle(close(2, write_handle), session)
    assert {:status, 2, 4} = decode_response(response)
    assert_receive {:aborted, "/finish-error"}

    {response, session} = handle(open(3, "/finish-error", 0x0000_0003), session)
    assert {:handle, 3, mixed_handle} = decode_response(response)

    {response, session} = handle(write(4, mixed_handle, 0, "x"), session)
    assert {:status, 4, 0} = decode_response(response)

    {response, _session} = handle(close(5, mixed_handle), session)
    assert {:status, 5, 4} = decode_response(response)
    assert_receive {:aborted, "/finish-error"}
  end

  test "backend directory and mutation errors are returned as SFTP statuses" do
    session =
      ErrorBackend |> Session.new(%{}, %{username: "test"}) |> Map.put(:initialized?, true)

    {response, session} = handle(opendir(1, "/open-dir-error"), session)
    assert {:status, 1, 2} = decode_response(response)

    {response, session} = handle(opendir(2, "/read-dir-error"), session)
    {:handle, 2, dir_handle} = decode_response(response)
    {response, session} = handle(readdir(3, dir_handle), session)
    assert {:status, 3, 3} = decode_response(response)

    for {packet, id} <- [
          {mkdir(4, "/mkdir-error"), 4},
          {path_packet(@ssh_fxp_rmdir, 5, "/rmdir-error"), 5},
          {path_packet(@ssh_fxp_remove, 6, "/remove-error"), 6},
          {rename(7, "/rename-error", "/new"), 7},
          {path_packet(@ssh_fxp_stat, 8, "/attrs-error"), 8}
        ] do
      {response, _session} = handle(packet, session)
      assert {:status, ^id, code} = decode_response(response)
      assert code in [2, 3, 4]
    end
  end

  test "readdir errors close and forget directory handles" do
    session =
      ErrorBackend |> Session.new(self(), %{username: "test"}) |> Map.put(:initialized?, true)

    {response, session} = handle(opendir(1, "/read-dir-error"), session)
    {:handle, 1, dir_handle} = decode_response(response)

    {response, session} = handle(readdir(2, dir_handle), session)
    assert {:status, 2, 3} = decode_response(response)
    assert_receive {:read_dir_error, %{read_error?: true}}
    assert_receive {:closed_dir, %{read_error?: true}}

    {response, _session} = handle(close(3, dir_handle), session)
    assert {:status, 3, 4} = decode_response(response)
  end

  test "mkdir treats no-such-file backend errors as missing paths" do
    session =
      ErrorBackend |> Session.new(%{}, %{username: "test"}) |> Map.put(:initialized?, true)

    {response, _session} = handle(mkdir(1, "/no-such-file-error"), session)
    assert {:status, 1, 0} = decode_response(response)
  end

  defp handle(packet, session) do
    {:ok, request} = unwrap(packet)
    Session.handle_packet(request, session)
  end

  defp unwrap(%SerializedPacket{kind: :iodata, iodata: iodata}), do: unwrap(iodata)

  defp unwrap(%SerializedPacket{kind: :data, header: header, data: data}) do
    unwrap([header, data])
  end

  defp unwrap(iodata) do
    case IO.iodata_to_binary(iodata) do
      <<len::32, packet::binary-size(len)>> -> {:ok, packet}
    end
  end

  defp open(id, path, pflags),
    do: packet([<<@ssh_fxp_open, id::32>>, string(path), <<pflags::32, 0::32>>])

  defp init, do: packet(<<1, 3::32>>)

  defp close(id, handle), do: packet([<<@ssh_fxp_close, id::32>>, string(handle)])

  defp read(id, handle, offset, len),
    do: packet([<<@ssh_fxp_read, id::32>>, string(handle), <<offset::64, len::32>>])

  defp write(id, handle, offset, data),
    do: packet([<<@ssh_fxp_write, id::32>>, string(handle), <<offset::64>>, string(data)])

  defp opendir(id, path), do: packet([<<@ssh_fxp_opendir, id::32>>, string(path)])
  defp readdir(id, handle), do: packet([<<@ssh_fxp_readdir, id::32>>, string(handle)])
  defp mkdir(id, path), do: packet([<<@ssh_fxp_mkdir, id::32>>, string(path), <<0::32>>])
  defp realpath(id, path), do: packet([<<@ssh_fxp_realpath, id::32>>, string(path)])
  defp path_packet(type, id, path), do: packet([<<type, id::32>>, string(path)])
  defp handle_packet(type, id, handle), do: packet([<<type, id::32>>, string(handle)])
  defp attrs_packet(type, id, target), do: packet([<<type, id::32>>, string(target), <<0::32>>])
  defp rename(id, oldpath, newpath), do: rename_like(@ssh_fxp_rename, id, oldpath, newpath)

  defp rename_like(type, id, oldpath, newpath),
    do: packet([<<type, id::32>>, string(oldpath), string(newpath)])

  defp packet(payload) do
    len = IO.iodata_length(payload)
    [<<len::32>>, payload]
  end

  defp string(data) when is_binary(data), do: [<<byte_size(data)::32>>, data]

  defp decode_response(response) do
    {:ok, response} = unwrap(response)

    case response do
      <<@ssh_fxp_status, id::32, code::32, _rest::binary>> ->
        {:status, id, code}

      <<2, version::32, _rest::binary>> ->
        {:version, version}

      <<@ssh_fxp_handle, id::32, rest::binary>> ->
        {:ok, handle, <<>>} = take_string(rest)
        {:handle, id, handle}

      <<@ssh_fxp_data, id::32, rest::binary>> ->
        {:ok, data, <<>>} = take_string(rest)
        {:data, id, data}

      <<@ssh_fxp_name, id::32, count::32, rest::binary>> ->
        {names, <<>>} =
          Enum.map_reduce(1..count, rest, fn _index, acc ->
            {:ok, name, acc} = take_string(acc)
            {:ok, _longname, acc} = take_string(acc)
            {:ok, _attrs, acc} = take_attrs(acc)
            {name, acc}
          end)

        {:name, id, names}

      <<@ssh_fxp_attrs, id::32, rest::binary>> ->
        {:ok, attrs, <<>>} = take_attrs(rest)
        {:attrs, id, attrs}
    end
  end

  defp take_string(<<len::32, rest::binary>>) do
    {value, rest} = :erlang.split_binary(rest, len)
    {:ok, value, rest}
  end

  defp take_attrs(<<flags::32, rest::binary>>) do
    with {:ok, attrs, rest} <- maybe_take_size(flags, rest, %{}),
         {:ok, attrs, rest} <- maybe_take_uidgid(flags, rest, attrs),
         {:ok, attrs, rest} <- maybe_take_permissions(flags, rest, attrs),
         {:ok, attrs, rest} <- maybe_take_acmodtime(flags, rest, attrs) do
      {:ok, attrs, rest}
    end
  end

  defp maybe_take_size(flags, <<size::64, rest::binary>>, attrs) when (flags &&& 1) != 0,
    do: {:ok, Map.put(attrs, :size, size), rest}

  defp maybe_take_size(_flags, rest, attrs), do: {:ok, attrs, rest}

  defp maybe_take_uidgid(flags, <<uid::32, gid::32, rest::binary>>, attrs)
       when (flags &&& 2) != 0,
       do: {:ok, attrs |> Map.put(:uid, uid) |> Map.put(:gid, gid), rest}

  defp maybe_take_uidgid(_flags, rest, attrs), do: {:ok, attrs, rest}

  defp maybe_take_permissions(flags, <<permissions::32, rest::binary>>, attrs)
       when (flags &&& 4) != 0,
       do: {:ok, Map.put(attrs, :permissions, permissions), rest}

  defp maybe_take_permissions(_flags, rest, attrs), do: {:ok, attrs, rest}

  defp maybe_take_acmodtime(flags, <<atime::32, mtime::32, rest::binary>>, attrs)
       when (flags &&& 8) != 0,
       do: {:ok, attrs |> Map.put(:atime, atime) |> Map.put(:mtime, mtime), rest}

  defp maybe_take_acmodtime(_flags, rest, attrs), do: {:ok, attrs, rest}
end
