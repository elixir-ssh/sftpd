defmodule Sftpd.Backend do
  @moduledoc """
  Behaviour for SFTP storage backends.

  See the HexDocs extras `Backends` and `Custom Backends` for package-level
  guidance before implementing this behaviour directly.

  Implement this behaviour to create custom storage backends for the SFTP server.
  Built-in backends include:

  - `Sftpd.Backends.S3` - Amazon S3 or compatible object storage

  ## Module-Based Backends

  Implement the `Sftpd.Backend` behaviour:

      defmodule MyApp.CustomBackend do
        @behaviour Sftpd.Backend

        @impl true
        def init(opts) do
          {:ok, %{root: opts[:root] || "/"}}
        end

        @impl true
        def list_dir(path, state) do
          {:ok, [~c".", ~c"..", ~c"file.txt"]}
        end

        # ... implement other callbacks
      end

  Then use it:

      Sftpd.start_server(
        backend: MyApp.CustomBackend,
        backend_opts: [root: "/data"],
        ...
      )

  ## Process-Based Backends

  For stateful backends, you can use a GenServer process instead:

      Sftpd.start_server(
        backend: {:genserver, MyApp.BackendServer},
        ...
      )

  By default, the process receives the legacy message shapes:

      def handle_call({:list_dir, path}, _from, state)
      def handle_call({:file_info, path}, _from, state)
      def handle_call({:make_dir, path}, _from, state)
      def handle_call({:del_dir, path}, _from, state)
      def handle_call({:delete, path}, _from, state)
      def handle_call({:rename, src, dst}, _from, state)
      def handle_call({:read_file, path}, _from, state)
      def handle_call({:write_file, path, content}, _from, state)

  Opt in to authenticated session context with `{:genserver, server, session:
  true}`. Session-aware processes must handle:

      def handle_call({:list_dir, path, session}, _from, state)
      def handle_call({:file_info, path, session}, _from, state)
      def handle_call({:make_dir, path, session}, _from, state)
      def handle_call({:del_dir, path, session}, _from, state)
      def handle_call({:delete, path, session}, _from, state)
      def handle_call({:rename, src, dst, session}, _from, state)
      def handle_call({:read_file, path, session}, _from, state)
      def handle_call({:write_file, path, content, session}, _from, state)

  Each should reply with the same format as the behaviour callbacks.

  ## Optional Streaming Callbacks

  Module backends can implement optional streaming callbacks for more efficient
  large-file transfers:

  - `read_file_range/4`
  - `begin_write/2`
  - `write_chunk/4`
  - `finish_write/2`
  - `abort_write/2`

  When these callbacks are present, `Sftpd.IODevice` avoids buffering entire
  files in memory for reads and most writes.

  ## Close Semantics

  Erlang's stock `:ssh_sftpd` server ignores the return value of
  `file_handler.close/2` and always reports close success to the client. Write
  failures can therefore only be surfaced reliably during active writes, not on
  close/final multipart completion.
  """

  @typedoc "Backend state, returned from init/1 and threaded through all calls"
  @type state :: term()

  @typedoc "Authenticated SSH session context returned by `Sftpd.Auth` callbacks"
  @type session :: map()

  @typedoc "SFTP path as charlist"
  @type path :: charlist()

  @typedoc "Opaque backend-managed write handle used by optional streaming callbacks"
  @type writer_handle :: term()

  @typedoc "Erlang file_info tuple"
  @type file_info ::
          {:file_info, non_neg_integer(), :regular | :directory, :read | :write | :read_write,
           tuple(), tuple(), tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  Initialize the backend with the given options.

  Called once when the SFTP session starts. Returns the initial state
  that will be passed to all subsequent callbacks.
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  List the contents of a directory.

  Returns a list of filenames as charlists. Must include `.` and `..` entries.
  """
  @callback list_dir(path(), state()) :: {:ok, [charlist()]} | {:error, atom()}
  @callback list_dir(path(), session(), state()) :: {:ok, [charlist()]} | {:error, atom()}

  @doc """
  Get file or directory information.

  Returns an Erlang file_info tuple. Use `Sftpd.Backend.file_info/3` or
  `Sftpd.Backend.directory_info/0` helpers to construct these.
  """
  @callback file_info(path(), state()) :: {:ok, file_info()} | {:error, atom()}
  @callback file_info(path(), session(), state()) :: {:ok, file_info()} | {:error, atom()}

  @doc """
  Create a directory.
  """
  @callback make_dir(path(), state()) :: :ok | {:error, atom()}
  @callback make_dir(path(), session(), state()) :: :ok | {:error, atom()}

  @doc """
  Delete an empty directory.
  """
  @callback del_dir(path(), state()) :: :ok | {:error, atom()}
  @callback del_dir(path(), session(), state()) :: :ok | {:error, atom()}

  @doc """
  Delete a file.
  """
  @callback delete(path(), state()) :: :ok | {:error, atom()}
  @callback delete(path(), session(), state()) :: :ok | {:error, atom()}

  @doc """
  Rename/move a file or directory.
  """
  @callback rename(src :: path(), dst :: path(), state()) :: :ok | {:error, atom()}
  @callback rename(src :: path(), dst :: path(), session(), state()) :: :ok | {:error, atom()}

  @doc """
  Read the entire contents of a file.

  For large files, consider implementing streaming in your backend
  and using the `read_file_range/4` optional callback.
  """
  @callback read_file(path(), state()) :: {:ok, binary()} | {:error, atom()}
  @callback read_file(path(), session(), state()) :: {:ok, binary()} | {:error, atom()}

  @doc """
  Write content to a file, creating or overwriting it.
  """
  @callback write_file(path(), content :: binary(), state()) :: :ok | {:error, atom()}
  @callback write_file(path(), content :: binary(), session(), state()) :: :ok | {:error, atom()}

  @doc """
  Read a byte range from a file.

  This is an optional callback used to avoid buffering entire files in memory.
  Return `:eof` when the requested offset is at or past the end of the file.
  """
  @callback read_file_range(path(), offset :: non_neg_integer(), len :: pos_integer(), state()) ::
              {:ok, binary()} | :eof | {:error, atom()}
  @callback read_file_range(
              path(),
              offset :: non_neg_integer(),
              len :: pos_integer(),
              session(),
              state()
            ) ::
              {:ok, binary()} | :eof | {:error, atom()}

  @doc """
  Begin a streaming write operation.

  The returned writer handle is passed back to subsequent streaming write callbacks.
  """
  @callback begin_write(path(), state()) :: {:ok, writer_handle()} | {:error, atom()}
  @callback begin_write(path(), session(), state()) :: {:ok, writer_handle()} | {:error, atom()}

  @doc """
  Append a chunk to a streaming write operation at the given offset.
  """
  @callback write_chunk(writer_handle(), offset :: non_neg_integer(), iodata(), state()) ::
              {:ok, writer_handle()} | {:error, atom()}
  @callback write_chunk(
              writer_handle(),
              offset :: non_neg_integer(),
              iodata(),
              session(),
              state()
            ) ::
              {:ok, writer_handle()} | {:error, atom()}

  @doc """
  Finalize a streaming write operation.
  """
  @callback finish_write(writer_handle(), state()) :: :ok | {:error, atom()}
  @callback finish_write(writer_handle(), session(), state()) :: :ok | {:error, atom()}

  @doc """
  Abort a streaming write operation.
  """
  @callback abort_write(writer_handle(), state()) :: :ok
  @callback abort_write(writer_handle(), session(), state()) :: :ok

  @optional_callbacks list_dir: 3,
                      file_info: 3,
                      make_dir: 3,
                      del_dir: 3,
                      delete: 3,
                      rename: 4,
                      read_file: 3,
                      write_file: 4,
                      read_file_range: 4,
                      read_file_range: 5,
                      begin_write: 2,
                      begin_write: 3,
                      write_chunk: 4,
                      write_chunk: 5,
                      finish_write: 2,
                      finish_write: 3,
                      abort_write: 2,
                      abort_write: 3

  # Helper functions for building file_info tuples

  @doc """
  Build a file_info tuple for a regular file.

  ## Parameters

  - `size` - File size in bytes
  - `mtime` - Modification time as Erlang datetime tuple `{{Y,M,D},{H,M,S}}`
  - `access` - Access mode, one of `:read`, `:write`, `:read_write`

  ## File Info Tuple Structure

  The tuple matches Erlang's `#file_info{}` record:

      {:file_info,
        size,           # File size in bytes
        type,           # :regular | :directory | :symlink | etc.
        access,         # :read | :write | :read_write | :none
        atime,          # Last access time {{Y,M,D},{H,M,S}}
        mtime,          # Last modification time
        ctime,          # Creation/change time
        mode,           # Unix permission bits (33188 = 0o100644 = regular file, rw-r--r--)
        links,          # Number of hard links
        major_device,   # Major device number (0 for regular files)
        minor_device,   # Minor device number (0 for regular files)
        inode,          # Inode number (random for virtual filesystems)
        uid,            # Owner user ID
        gid}            # Owner group ID

  ## Examples

      iex> {:file_info, 12, :regular, :read_write, {{2024, 1, 1}, {0, 0, 0}}, _, _, _, _, _, _, _, _, _} =
      ...>   Sftpd.Backend.file_info(12, {{2024, 1, 1}, {0, 0, 0}})
  """
  @spec file_info(non_neg_integer(), :calendar.datetime(), :read | :write | :read_write) ::
          file_info()
  def file_info(size, mtime, access \\ :read_write) do
    # 33188 = 0o100644 = regular file with rw-r--r-- permissions
    {:file_info, size, :regular, access, mtime, mtime, mtime, 33188, 1, 0, 0,
     :rand.uniform(32767), 1, 1}
  end

  @doc """
  Build a file_info tuple for a directory.

  Returns a directory with mode 16877 (0o40755 = directory with rwxr-xr-x permissions).
  """
  @spec directory_info() :: file_info()
  def directory_info do
    timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()

    # 16877 = 0o40755 = directory with rwxr-xr-x permissions
    # 4096 = typical directory size on Unix filesystems
    {:file_info, 4096, :directory, :read, timestamp, timestamp, timestamp, 16877, 2, 0, 0, 0, 1,
     1}
  end

  @doc """
  Return true if the path refers to the root directory.

  Handles all common root path representations used by SFTP clients.

  ## Examples

      iex> Sftpd.Backend.root_path?(~c"/")
      true

      iex> Sftpd.Backend.root_path?(~c"/nested")
      false
  """
  @spec root_path?(path()) :: boolean()
  def root_path?(path), do: path in [~c"/", ~c"/.", ~c"/..", ~c"..", ~c".", ~c""]

  @doc """
  Normalize an SFTP path to a string without leading slash.

  Useful for backends that use string keys (like S3).

  ## Examples

      iex> Sftpd.Backend.normalize_path(~c"/folder/file.txt")
      "folder/file.txt"

      iex> Sftpd.Backend.normalize_path("already/normalized")
      "already/normalized"
  """
  @spec normalize_path(path() | String.t()) :: String.t()
  def normalize_path(path) do
    path |> to_string() |> String.trim_leading("/")
  end

  @doc """
  Return true when a module backend implements the given optional callback.

  Process-based backends use the legacy callback contract only.
  """
  @type genserver_backend ::
          {:genserver, GenServer.server()} | {:genserver, GenServer.server(), keyword()}

  @spec supports_callback?(module() | genserver_backend(), atom(), arity()) :: boolean()
  def supports_callback?({:genserver, _server}, _function, _arity), do: false
  def supports_callback?({:genserver, _server, _opts}, _function, _arity), do: false

  def supports_callback?(module, function, arity) when is_atom(module) do
    exports?(module, function, arity) or exports?(module, function, arity + 1)
  end

  # Backend dispatch helpers

  @doc false
  def call({:genserver, server}, operation, args) do
    # Drop the backend_state (last arg) — genserver manages its own state
    call_args = List.delete_at(args, -1)
    GenServer.call(server, List.to_tuple([operation | call_args]))
  end

  def call({:genserver, server, _opts}, operation, args) do
    call({:genserver, server}, operation, args)
  end

  def call(module, operation, args) when is_atom(module) do
    apply(module, operation, args)
  end

  @doc false
  def call({:genserver, server}, operation, args, session) do
    call({:genserver, server}, operation, args, session, 5_000)
  end

  def call({:genserver, server, opts}, operation, args, session) do
    call({:genserver, server, opts}, operation, args, session, 5_000)
  end

  def call(module, operation, args, session) when is_atom(module) do
    call(module, operation, args, session, 5_000)
  end

  @doc false
  def call({:genserver, server}, operation, args, _session, timeout) do
    call_args = List.delete_at(args, -1)
    GenServer.call(server, List.to_tuple([operation | call_args]), timeout)
  end

  def call({:genserver, server, opts}, operation, args, session, timeout) do
    if Keyword.get(opts, :session, false) do
      call_args = List.delete_at(args, -1)
      GenServer.call(server, List.to_tuple([operation | call_args ++ [session]]), timeout)
    else
      call({:genserver, server}, operation, args, session, timeout)
    end
  end

  def call(module, operation, args, session, _timeout) when is_atom(module) do
    session_aware_args = insert_session_before_backend_state(args, session)

    if exports?(module, operation, length(session_aware_args)) do
      apply(module, operation, session_aware_args)
    else
      apply(module, operation, args)
    end
  end

  defp insert_session_before_backend_state(args, session) do
    case Enum.split(args, -1) do
      {call_args, [backend_state]} -> call_args ++ [session, backend_state]
      {call_args, []} -> call_args ++ [session]
    end
  end

  defp exports?(module, function, arity) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> function_exported?(module, function, arity)
      {:error, _reason} -> false
    end
  end
end
