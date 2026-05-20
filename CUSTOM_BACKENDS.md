# Custom Backends

This guide explains how to build your own backend for `Sftpd`.

If you only need a built-in backend, see `BACKENDS.md`. If you want the exact
callback contracts, see `Sftpd.Backend`.

## Backend Model

`Sftpd` asks a backend to present a filesystem-like interface over some storage
system. That storage can be:

- a local service API
- object storage
- a database
- an in-memory structure
- a process that fronts another system

Your backend does not need to be a real filesystem, but it does need to act
like one from the SFTP client's point of view.

## Required Callbacks

Every backend must implement:

- `init/1`
- `list_dir/2`
- `file_info/2`
- `make_dir/2`
- `del_dir/2`
- `delete/2`
- `rename/3`
- `read_file/2`
- `write_file/3`

Those callbacks are enough for a working backend, even if the underlying
implementation is simplistic.

## Minimal Example

```elixir
defmodule MyApp.ExampleBackend do
  @behaviour Sftpd.Backend

  @impl true
  def init(opts) do
    {:ok, %{root: Keyword.fetch!(opts, :root)}}
  end

  @impl true
  def list_dir(_path, _state) do
    {:ok, [~c".", ~c".."]}
  end

  @impl true
  def file_info(_path, _state) do
    {:error, :enoent}
  end

  @impl true
  def make_dir(_path, _state), do: :ok

  @impl true
  def del_dir(_path, _state), do: :ok

  @impl true
  def delete(_path, _state), do: :ok

  @impl true
  def rename(_src, _dst, _state), do: :ok

  @impl true
  def read_file(_path, _state), do: {:error, :enoent}

  @impl true
  def write_file(_path, _content, _state), do: :ok
end
```

## Returning File Metadata

`file_info/2` must return Erlang-style file metadata tuples. In practice you
should use the helpers in `Sftpd.Backend` instead of constructing them by hand:

- `Sftpd.Backend.file_info/3`
- `Sftpd.Backend.directory_info/0`

Example:

```elixir
{:ok, Sftpd.Backend.file_info(byte_size(content), NaiveDateTime.to_erl(mtime))}
```

For root-like paths, make sure you return directory metadata rather than
`{:error, :enoent}`.

## Path Handling

SFTP paths arrive as charlists. Common helpers:

- `Sftpd.Backend.root_path?/1`
- `Sftpd.Backend.normalize_path/1`

`normalize_path/1` is especially useful for key-based stores such as S3-like
systems because it removes the leading `/`.

## Example: Local Folder Backend

This example maps SFTP paths into a single root directory on local disk. The
important part is the `local_path/2` helper: it normalizes SFTP charlist paths,
rejects `..` traversal, and uses a path-relative containment check that also
works when the configured root is `/`. This example does not resolve symlink
targets; if users can create symlinks inside the root, disallow symlinks or add
real-path validation before using this pattern for untrusted writes.

```elixir
defmodule MyApp.LocalFolderBackend do
  @behaviour Sftpd.Backend

  alias Sftpd.Backend

  @impl true
  def init(opts) do
    root = opts |> Keyword.fetch!(:root) |> Path.expand()
    File.mkdir_p!(root)
    {:ok, %{root: root}}
  end

  @impl true
  def list_dir(path, state) do
    with {:ok, local} <- local_path(path, state),
         {:ok, entries} <- File.ls(local) do
      {:ok, [~c".", ~c".." | Enum.map(entries, &String.to_charlist/1)]}
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  @impl true
  def file_info(path, state) do
    with {:ok, local} <- local_path(path, state),
         {:ok, stat} <- File.stat(local) do
      {:ok, stat_to_file_info(stat)}
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  @impl true
  def make_dir(path, state) do
    with {:ok, local} <- local_path(path, state),
         :ok <- File.mkdir(local) do
      :ok
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  @impl true
  def del_dir(path, state) do
    with {:ok, local} <- local_path(path, state),
         :ok <- File.rmdir(local) do
      :ok
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  @impl true
  def delete(path, state) do
    with {:ok, local} <- local_path(path, state),
         :ok <- File.rm(local) do
      :ok
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  @impl true
  def rename(src, dst, state) do
    with {:ok, src_local} <- local_path(src, state),
         {:ok, dst_local} <- local_path(dst, state),
         :ok <- File.rename(src_local, dst_local) do
      :ok
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  @impl true
  def read_file(path, state) do
    with {:ok, local} <- local_path(path, state),
         {:ok, content} <- File.read(local) do
      {:ok, content}
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  @impl true
  def write_file(path, content, state) do
    with {:ok, local} <- local_path(path, state),
         :ok <- File.mkdir_p(Path.dirname(local)),
         :ok <- File.write(local, content) do
      :ok
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  defp local_path(path, %{root: root}) do
    parts =
      path
      |> Backend.normalize_path()
      |> Path.split()
      |> Enum.reject(&(&1 in ["", "."]))

    if ".." in parts do
      {:error, :eacces}
    else
      candidate = Path.expand(Path.join([root | parts]))

      if contained_in_root?(candidate, root) do
        {:ok, candidate}
      else
        {:error, :eacces}
      end
    end
  end

  defp contained_in_root?(candidate, root) do
    relative = Path.relative_to(candidate, root)

    candidate == root or
      (Path.type(relative) == :relative and
         relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  defp stat_to_file_info(%File.Stat{type: :directory}) do
    Backend.directory_info()
  end

  defp stat_to_file_info(%File.Stat{size: size, mtime: mtime}) do
    Backend.file_info(size, mtime)
  end

  defp map_error(:enoent), do: :enoent
  defp map_error(:eacces), do: :eacces
  defp map_error(:enotdir), do: :enoent
  defp map_error(:eexist), do: :eexist
  defp map_error(:enotempty), do: :eexist
  defp map_error(_reason), do: :eio
end
```

Use it like any module backend:

```elixir
Sftpd.start_server(
  port: 2222,
  backend: MyApp.LocalFolderBackend,
  backend_opts: [root: "/srv/my_app/sftp"],
  auth: {:passwords, [{"user", "pass"}]},
  system_dir: "ssh_keys"
)
```

## Directory Listings

`list_dir/2` must return entries as charlists and must include:

- `~c"."`
- `~c".."`

Even if the backing store does not have explicit directory entries, the SFTP
layer expects those names to exist.

## Error Conventions

Prefer POSIX-style atoms:

- `:enoent` for missing files or directories
- `:eacces` for permission failures
- `:einval` for invalid requests
- `:eio` for unexpected storage failures

Using stable error atoms matters because SFTP clients map them to user-visible
status codes.

## Optional Streaming Callbacks

For better large-file performance, module backends can also implement:

- `read_file_range/4`
- `begin_write/2`
- `write_chunk/4`
- `finish_write/2`
- `abort_write/2`

These callbacks are optional, but valuable when:

- whole-file reads are too expensive
- uploads should stream rather than buffer
- multipart writes are supported by the target storage

If you do not implement them, `Sftpd` falls back to the required callbacks.

## Process-Based Backends

If your backend already lives inside a GenServer, you can provide:

```elixir
backend: {:genserver, MyApp.BackendServer, session: true}
```

In that mode, `Sftpd` does not call `init/1`. Instead it sends `handle_call/3`
messages corresponding to the required backend operations.

The default `{:genserver, server}` form preserves the legacy process-backend
message contract. Use `{:genserver, server, session: true}` when the backend
needs authenticated session context in each call.

This is useful when:

- the backend owns pooled connections
- the backend has mutable shared state
- the backend is already part of your supervision tree

Process-based backends use only the required whole-file callback contract. The
optional streaming callbacks are module-backend-only.

Here is a complete in-memory GenServer shape:

```elixir
defmodule MyApp.SftpBackend do
  use GenServer

  alias Sftpd.Backend

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{files: %{}}}
  end

  @impl true
  def handle_call({:list_dir, _path, _session}, _from, state) do
    names =
      state.files
      |> Map.keys()
      |> Enum.map(&Path.basename/1)
      |> Enum.uniq()
      |> Enum.map(&String.to_charlist/1)

    {:reply, {:ok, [~c".", ~c".." | names]}, state}
  end

  def handle_call({:file_info, path, _session}, _from, state) do
    key = Backend.normalize_path(path)

    reply =
      case Map.fetch(state.files, key) do
        {:ok, content} ->
          mtime = NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()
          {:ok, Backend.file_info(byte_size(content), mtime)}

        :error ->
          {:error, :enoent}
      end

    {:reply, reply, state}
  end

  def handle_call({:make_dir, _path, _session}, _from, state), do: {:reply, :ok, state}
  def handle_call({:del_dir, _path, _session}, _from, state), do: {:reply, :ok, state}
  def handle_call({:delete, path, _session}, _from, state) do
    {:reply, :ok, update_in(state.files, &Map.delete(&1, Backend.normalize_path(path)))}
  end

  def handle_call({:rename, src, dst, _session}, _from, state) do
    src_key = Backend.normalize_path(src)
    dst_key = Backend.normalize_path(dst)

    case Map.pop(state.files, src_key) do
      {nil, files} -> {:reply, {:error, :enoent}, %{state | files: files}}
      {content, files} -> {:reply, :ok, %{state | files: Map.put(files, dst_key, content)}}
    end
  end

  def handle_call({:read_file, path, _session}, _from, state) do
    reply =
      case Map.fetch(state.files, Backend.normalize_path(path)) do
        {:ok, content} -> {:ok, content}
        :error -> {:error, :enoent}
      end

    {:reply, reply, state}
  end

  def handle_call({:write_file, path, content, _session}, _from, state) do
    key = Backend.normalize_path(path)
    {:reply, :ok, put_in(state.files[key], content)}
  end
end
```

Add the backend process to your application supervision tree before starting
the SFTP server:

```elixir
children = [
  MyApp.SftpBackend,
  MyApp.SftpServer
]
```

Then point `Sftpd` at the registered process:

```elixir
Sftpd.start_server(
  port: 2222,
  backend: {:genserver, MyApp.SftpBackend, session: true},
  auth: {:passwords, [{"user", "pass"}]},
  system_dir: "ssh_keys"
)
```

Backend calls are synchronous from the SFTP client's perspective. If a
`GenServer.call/3` blocks, the client operation blocks too.

## Post-Write Processing with Broadway

Use Broadway for follow-up processing after the backend has durably accepted a
file. Do not use it as the synchronous storage acknowledgement path unless the
client can safely treat a queued message as durable storage.

```elixir
def handle_call({:write_file, path, content, _session}, _from, state) do
  :ok = MyStorage.put(path, content)

  Broadway.producer_names(MyApp.SftpIngestBroadway)
  |> Enum.each(fn producer ->
    message = %Broadway.Message{data: %{path: path}}
    Broadway.push_messages(producer, [message])
  end)

  {:reply, :ok, state}
end
```

The storage write happens before the reply. Broadway is then responsible for
post-upload work such as parsing, indexing, thumbnails, notifications, or
moving the file into a longer pipeline.

## Running Under Supervision

`Sftpd.child_spec/1` starts and stops the SSH daemon under your application
supervisor:

```elixir
children = [
  {Sftpd,
   port: 2222,
   backend: Sftpd.Backends.Memory,
   backend_opts: [],
   auth: {:passwords, [{"user", "pass"}]},
   system_dir: "ssh_keys"}
]
```

## Authentication

Use `auth: {:passwords, [{"username", "password"}]}` for local development.
For production, pass `auth: {MyApp.SftpAuth, opts}` and implement
`Sftpd.Auth`.

Auth callbacks return a session map. Module callbacks can opt into that context
by implementing session-aware arities, for example:

```elixir
def list_dir(path, %{tenant_id: tenant_id}, state) do
  list_tenant_dir(tenant_id, path, state)
end
```

Process backends receive the session as the final tuple element, such as
`{:read_file, path, session}`.

## Known Semantics and Limitations

- SFTP paths are charlists.
- Non-streaming backends read and write whole files through the required
  callbacks.
- Process-based backends use synchronous `GenServer.call/3`.
- Process-based backends do not use optional streaming callbacks.
- OTP's stock SFTP server reports close success to the client even when a
  close-time backend flush fails, so close-only failures are logged server-side.

## Testing Recommendations

At minimum, test:

- root listing behavior
- missing path behavior
- file metadata shape
- write then read round-trips
- rename semantics
- directory creation and deletion

If you implement streaming callbacks, also test:

- sequential reads through `read_file_range/4`
- sequential writes through `write_chunk/4`
- finalization and abort paths
- non-sequential write fallback behavior if relevant

## Telemetry

Backend activity is visible through `Sftpd` telemetry events emitted around
server lifecycle and SFTP file-handler operations. See `TELEMETRY.md` for the
event catalog and metadata.

## Next Steps

- See `Sftpd.Backend` for the exact callback contracts
- See `BACKENDS.md` for tradeoffs between built-in and custom backends
- See `Sftpd.Backends.Memory` for a simple reference implementation
- See `Sftpd.Backends.S3` for a streaming-capable reference implementation
