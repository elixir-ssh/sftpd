defmodule Sftpd.BackendTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.Backend

  describe "file_info/2" do
    test "defaults access to :read_write" do
      mtime = {{2024, 1, 1}, {0, 0, 0}}
      result = Backend.file_info(100, mtime)

      assert {:file_info, 100, :regular, :read_write, ^mtime, ^mtime, ^mtime, 33188, 1, 0, 0, _,
              1, 1} = result
    end
  end

  describe "call/3 with module" do
    test "applies function on module backend" do
      {:ok, mem_state} = Sftpd.Backends.Memory.init([])
      result = Backend.call(Sftpd.Backends.Memory, :list_dir, [~c"/", mem_state])
      assert {:ok, [~c".", ~c".."]} = result
    end
  end

  describe "call/4 with module" do
    defmodule SessionModuleBackend do
      def list_dir(_path, %{tenant: tenant}, _state), do: {:ok, [to_charlist(tenant)]}
      def file_info(_path, _state), do: {:error, :legacy_called}
    end

    defmodule SessionRecordingBackend do
      def list_dir(path, session, state), do: {:list_dir, path, session, state}
      def file_info(path, session, state), do: {:file_info, path, session, state}
      def make_dir(path, session, state), do: {:make_dir, path, session, state}
      def del_dir(path, session, state), do: {:del_dir, path, session, state}
      def delete(path, session, state), do: {:delete, path, session, state}
      def rename(src, dst, session, state), do: {:rename, src, dst, session, state}
      def read_file(path, session, state), do: {:read_file, path, session, state}

      def write_file(path, content, session, state),
        do: {:write_file, path, content, session, state}

      def read_file_range(path, offset, len, session, state),
        do: {:read_file_range, path, offset, len, session, state}

      def begin_write(path, session, state), do: {:begin_write, path, session, state}

      def write_chunk(handle, offset, chunk, session, state),
        do: {:write_chunk, handle, offset, chunk, session, state}

      def finish_write(handle, session, state), do: {:finish_write, handle, session, state}
      def abort_write(handle, session, state), do: {:abort_write, handle, session, state}
    end

    test "prefers session-aware callbacks when implemented" do
      result = Backend.call(SessionModuleBackend, :list_dir, [~c"/", nil], %{tenant: "acme"})
      assert {:ok, [~c"acme"]} = result
    end

    test "supports_callback? detects session-aware arity" do
      assert Backend.supports_callback?(SessionModuleBackend, :list_dir, 2)
    end

    test "falls back to legacy callbacks when session-aware callbacks are absent" do
      result = Backend.call(SessionModuleBackend, :file_info, [~c"/", nil], %{tenant: "acme"})
      assert {:error, :legacy_called} = result
    end

    property "inserts session before backend state for every session-aware callback shape" do
      session = %{user_id: 123, tenant_id: "acme"}
      state = %{backend: :state}

      check all({operation, args, expected} <- session_callback_call()) do
        expected_result = apply_expected(expected, session, state)

        assert ^expected_result =
                 Backend.call(SessionRecordingBackend, operation, args ++ [state], session)
      end
    end
  end

  describe "call/3 with genserver" do
    defmodule EchoServer do
      use GenServer

      def start_link(reply), do: GenServer.start_link(__MODULE__, reply)
      def init(reply), do: {:ok, reply}
      def handle_call({:list_dir, _path}, _from, reply), do: {:reply, reply, reply}
    end

    test "dispatches to genserver process" do
      expected = {:ok, [~c".", ~c"..", ~c"test.txt"]}
      {:ok, pid} = EchoServer.start_link(expected)

      result = Backend.call({:genserver, pid}, :list_dir, [~c"/", nil])
      assert result == expected
    end

    test "dispatches three-tuple genserver process calls without session by default" do
      expected = {:ok, [~c".", ~c"..", ~c"test.txt"]}
      {:ok, pid} = EchoServer.start_link(expected)

      result = Backend.call({:genserver, pid, session: true}, :list_dir, [~c"/", nil])
      assert result == expected
    end
  end

  describe "call/4 with genserver" do
    defmodule LegacyEchoServer do
      use GenServer

      def start_link(reply), do: GenServer.start_link(__MODULE__, reply)
      def init(reply), do: {:ok, reply}

      def handle_call({:read_file, path}, _from, reply),
        do: {:reply, {reply, path}, reply}
    end

    defmodule SessionEchoServer do
      use GenServer

      def start_link(reply), do: GenServer.start_link(__MODULE__, reply)
      def init(reply), do: {:ok, reply}

      def handle_call({:read_file, path, session}, _from, reply),
        do: {:reply, {reply, path, session}, reply}
    end

    test "preserves legacy message shapes for genserver processes by default" do
      {:ok, pid} = LegacyEchoServer.start_link(:ok)

      assert {:ok, ~c"/file.txt"} =
               Backend.call({:genserver, pid}, :read_file, [~c"/file.txt", nil], %{user_id: 123})
    end

    test "preserves legacy message shapes for three-tuple genserver processes unless opted in" do
      {:ok, pid} = LegacyEchoServer.start_link(:ok)

      assert {:ok, ~c"/file.txt"} =
               Backend.call(
                 {:genserver, pid, session: false},
                 :read_file,
                 [~c"/file.txt", nil],
                 %{user_id: 123}
               )
    end

    test "dispatches session-aware messages to genserver processes" do
      {:ok, pid} = SessionEchoServer.start_link(:ok)

      assert {:ok, ~c"/file.txt", %{user_id: 123}} =
               Backend.call(
                 {:genserver, pid, session: true},
                 :read_file,
                 [~c"/file.txt", nil],
                 %{user_id: 123}
               )
    end
  end

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
      root_forms = [~c"/", ~c"/.", ~c"/..", ~c"..", ~c".", ~c""]

      check all(path <- path_string()) do
        char_path = String.to_charlist(path)
        assert Backend.root_path?(char_path) == char_path in root_forms
      end
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

  defp session_callback_call do
    member_of([
      {:list_dir, [~c"/dir"], {:list_dir, ~c"/dir"}},
      {:file_info, [~c"/file"], {:file_info, ~c"/file"}},
      {:make_dir, [~c"/dir"], {:make_dir, ~c"/dir"}},
      {:del_dir, [~c"/dir"], {:del_dir, ~c"/dir"}},
      {:delete, [~c"/file"], {:delete, ~c"/file"}},
      {:rename, [~c"/old", ~c"/new"], {:rename, ~c"/old", ~c"/new"}},
      {:read_file, [~c"/file"], {:read_file, ~c"/file"}},
      {:write_file, [~c"/file", "content"], {:write_file, ~c"/file", "content"}},
      {:read_file_range, [~c"/file", 5, 8], {:read_file_range, ~c"/file", 5, 8}},
      {:begin_write, [~c"/file"], {:begin_write, ~c"/file"}},
      {:write_chunk, [:handle, 5, "content"], {:write_chunk, :handle, 5, "content"}},
      {:finish_write, [:handle], {:finish_write, :handle}},
      {:abort_write, [:handle], {:abort_write, :handle}}
    ])
  end

  defp apply_expected(expected, session, state) do
    expected
    |> Tuple.to_list()
    |> then(fn [operation | args] -> List.to_tuple([operation | args ++ [session, state]]) end)
  end
end
