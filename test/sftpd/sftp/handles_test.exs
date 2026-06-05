defmodule Sftpd.SFTP.HandlesTest do
  use ExUnit.Case, async: true

  alias Sftpd.SFTP.Handles

  defmodule Backend do
    def abort_write(%{test_pid: test_pid, path: path}, _state) do
      send(test_pid, {:abort, path})
      :ok
    end

    def close_dir(%{test_pid: test_pid, path: path}, _state) do
      send(test_pid, {:close_dir, path})
      :ok
    end

    def file_attrs("/known.txt", _session, _state),
      do: {:ok, %{type: :regular, size: 10, permissions: 0o100644}}

    def file_attrs(_path, _session, _state), do: {:error, :enoent}
  end

  test "cleanup aborts writable handles and closes directory handles" do
    test_pid = self()

    state = %{
      backend: Backend,
      backend_state: %{},
      session: %{},
      handles: %{
        "read" => {:file, :read, "/known.txt", :read_handle},
        "write" =>
          {:file, :write, "/pending.txt", %{test_pid: test_pid, path: "/pending.txt"}, nil, 0},
        "dir" => {:dir, %{test_pid: test_pid, path: "/dir"}}
      }
    }

    state = Handles.cleanup_open_handles(state, fn _overlay -> send(test_pid, :overlay) end)

    assert state.handles == %{}
    assert_receive {:abort, "/pending.txt"}
    assert_receive {:close_dir, "/dir"}
    refute_receive :overlay
  end

  test "pending write attrs report uncommitted size" do
    state = %{backend: Backend, backend_state: %{}, session: %{}}

    assert {:ok, %{size: 42, type: :regular}} =
             Handles.file_attrs({:file, :write, "/known.txt", :writer, nil, 42}, state)
  end

  test "pending attrs synthesize new file attrs before close" do
    state = %{backend: Backend, backend_state: %{}, session: %{}}

    assert {:ok, %{size: 7, type: :regular, permissions: 0o100644}} =
             Handles.file_attrs({:file, :write, "/new.txt", :writer, nil, 7}, state)
  end

  test "put stores opaque handles by type prefix" do
    state = %{handles: %{}}

    for {value, prefix} <- [
          {{:file, :read, "/file.txt", :reader}, "F"},
          {{:file, :write, "/file.txt", :writer, nil, 0}, "W"},
          {{:file, :read_write, "/file.txt", :reader, :writer, nil, false, :overlay, 0}, "B"},
          {{:dir, :dir_handle}, "D"}
        ] do
      {_response, state} = Handles.put(1, value, state)
      assert [{handle, ^value}] = Map.to_list(state.handles)
      assert String.starts_with?(handle, prefix)
    end
  end
end
