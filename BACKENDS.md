# Backends

`Sftpd` separates the SFTP server runtime from storage through the
`Sftpd.Backend` behaviour. A backend is responsible for the filesystem-like
operations that SFTP clients expect: listing directories, reading files,
writing files, and reporting metadata.

## Choosing a Backend Style

You can plug in storage in two ways:

- module-based backends
- process-based backends

Module-based backends are the simplest fit for stateless adapters and are what
the built-in backends use. Process-based backends are useful when the storage
layer already has a long-lived process, mutable state, or its own lifecycle.

| Need | Use |
| --- | --- |
| Tests, demos, and local development | `Sftpd.Backends.Memory` |
| Amazon S3, MinIO, or another S3-compatible store | `Sftpd.Backends.S3` |
| A local disk folder | A custom folder backend |
| A shared process, cache, queue, or connection pool | `{:genserver, name_or_pid}` |
| Async ingestion after upload | Store synchronously in the backend, then enqueue a Broadway job |

## Built-In Backends

### `Sftpd.Backends.Memory`

The memory backend stores files in an `Agent` and is intended for:

- development
- tests
- backend experimentation

Properties:

- no external dependencies
- immediate startup
- supports the core `Sftpd.Backend` callbacks
- does not implement the optional streaming callbacks

Example:

```elixir
{:ok, ref} =
  Sftpd.start_server(
    port: 2222,
    backend: Sftpd.Backends.Memory,
    backend_opts: [],
    users: [{"dev", "dev"}],
    system_dir: "ssh_keys"
  )
```

See `Sftpd.Backends.Memory` for API details.

### `Sftpd.Backends.S3`

The S3 backend maps SFTP operations onto object storage and is intended for:

- Amazon S3
- MinIO
- S3-compatible providers

S3 support is optional. Applications that use this backend must also depend on:

- `:ex_aws`
- `:ex_aws_s3`
- `:hackney`
- `:sweet_xml`
- `:jason`
- `:configparser_ex`

If those dependencies are not available, `Sftpd.Backends.S3.init/1` returns
`{:error, :missing_s3_dependency}` instead of failing during compilation.

Properties:

- supports range reads through `read_file_range/4`
- supports multipart streaming writes through the optional streaming callbacks
- uses delimiter-based paginated listings for directory traversal
- models directories with `.keep` marker objects

Example:

```elixir
{:ok, ref} =
  Sftpd.start_server(
    port: 2222,
    backend: Sftpd.Backends.S3,
    backend_opts: [bucket: "my-bucket", prefix: "tenant-a/"],
    users: [{"user", "pass"}],
    system_dir: "ssh_keys"
  )
```

See `Sftpd.Backends.S3` for configuration details and caveats. The Getting
Started guide has the same dependency list in the context of a full server
setup.

## Module-Based Backends

A module backend implements the `Sftpd.Backend` callbacks directly and returns
its own backend state from `init/1`.

Minimal shape:

```elixir
defmodule MyApp.CustomBackend do
  @behaviour Sftpd.Backend

  @impl true
  def init(opts) do
    {:ok, %{root: Keyword.fetch!(opts, :root)}}
  end

  @impl true
  def list_dir(_path, _state), do: {:ok, [~c".", ~c".."]}

  @impl true
  def file_info(_path, _state), do: {:error, :enoent}

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

Use it with:

```elixir
Sftpd.start_server(
  backend: MyApp.CustomBackend,
  backend_opts: [root: "/data"],
  users: [{"user", "pass"}],
  system_dir: "ssh_keys"
)
```

## Process-Based Backends

You can also pass a running GenServer as `{:genserver, server}`. In that mode,
`Sftpd` skips `init/1` and forwards backend operations as `handle_call/3`
messages.

Calls follow this shape:

- `{:list_dir, path}`
- `{:file_info, path}`
- `{:make_dir, path}`
- `{:del_dir, path}`
- `{:delete, path}`
- `{:rename, src, dst}`
- `{:read_file, path}`
- `{:write_file, path, content}`

The reply format must match the `Sftpd.Backend` callback contracts.

## Streaming Support

For large files, module backends can optionally implement:

- `read_file_range/4`
- `begin_write/2`
- `write_chunk/4`
- `finish_write/2`
- `abort_write/2`

When present:

- reads avoid preloading the entire file into memory
- sequential writes can stream directly to the backend
- large S3 uploads can use multipart upload instead of a full-buffer rewrite

If those callbacks are not implemented, `Sftpd` falls back to whole-file
buffering semantics using the required callbacks.

## Metadata and Directory Semantics

Backends are expected to expose filesystem-like results even when the
underlying storage is not a filesystem.

Important conventions:

- `list_dir/2` must include `.` and `..`
- `file_info/2` should distinguish `:regular` from `:directory`
- `root_path?/1` and `normalize_path/1` in `Sftpd.Backend` help normalize SFTP
  paths consistently
- `directory_info/0` and `file_info/3` build compatible Erlang-style metadata

## Error Mapping

Backend functions should return POSIX-style atoms such as:

- `:enoent`
- `:eacces`
- `:einval`
- `:eio`

That keeps behavior predictable across storage implementations and maps cleanly
onto what SFTP clients expect.

## Next Steps

- Read `CUSTOM_BACKENDS.md` for implementation guidance
- See `Sftpd.Backend` for the authoritative callback contracts
- See `TELEMETRY.md` for the emitted telemetry events around backend operations
