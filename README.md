# Sftpd

A pluggable SFTP server for Elixir with memory, custom, and optional S3
backends.

`Sftpd` wraps Erlang's `:ssh_sftpd` subsystem and lets you plug storage behind
it through a small backend behaviour. It ships with:

- an in-memory backend for development and tests
- an optional S3 backend with range reads and multipart streaming writes
- password and public-key auth callbacks that return per-session context
- telemetry hooks around server lifecycle and SFTP operations

## Installation

Version notes for this package:

- verified minimum Elixir: `~> 1.14`
- verified minimum OTP for CI: `26`
- current pinned development environment: Erlang/OTP 29.0
- current pinned development environment: Elixir 1.20.0-rc.5 on OTP 29

The package requirement is declared in `mix.exs`. The development environment
is pinned in `.tool-versions`.

```elixir
def deps do
  [
    {:sftpd, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Start with in-memory backend (great for development)
{:ok, ref} = Sftpd.start_server(
  port: 2222,
  backend: Sftpd.Backends.Memory,
  backend_opts: [],
  auth: {:passwords, [{"dev", "dev"}]},
  system_dir: "/path/to/ssh_host_keys"
)

# Connect with: sftp -P 2222 dev@localhost
```

## Guides

- `GETTING_STARTED.md` for a step-by-step setup guide
- `PHOENIX.md` for supervised Phoenix setup with app auth and S3
- `BACKENDS.md` for backend architecture and built-in backend tradeoffs
- `CUSTOM_BACKENDS.md` for implementing your own backend
- `TELEMETRY.md` for emitted events, metadata, and examples

## Key Concepts

- `Sftpd.start_server/1` starts an SSH daemon configured with an SFTP
  file-handler
- `Sftpd.child_spec/1` lets Phoenix and other OTP apps supervise the server
- `Sftpd.Auth` defines password and public-key auth callbacks
- `Sftpd.Backend` defines the storage contract
- `Sftpd.Backends.Memory` is the fastest local setup path
- `Sftpd.Backends.S3` is the built-in persistent backend
- `Sftpd.Telemetry` documents the instrumentation surface

## Choosing a Backend

| Need | Use |
| --- | --- |
| Tests, demos, and local development | `Sftpd.Backends.Memory` |
| Amazon S3, MinIO, or another S3-compatible store | `Sftpd.Backends.S3` |
| A local disk folder | A custom folder backend |
| A shared process, cache, queue, or connection pool | `{:genserver, name_or_pid}` |
| Async ingestion after upload | Store synchronously in the backend, then enqueue a Broadway job |

See `BACKENDS.md` for backend tradeoffs and `CUSTOM_BACKENDS.md` for folder,
GenServer, supervision, and post-write processing examples.

## Erlang/OTP 29 Note

OTP 29 no longer enables SFTP implicitly for SSH daemons and also disables
shell and exec services by default. `Sftpd.start_server/1` already passes the
required SFTP subsystem configuration, so applications using this package do
not need to configure OTP SSH subsystems themselves.

## Backends

### Memory Backend

Stores files in memory. Useful for development and testing without external dependencies.

```elixir
Sftpd.start_server(
  port: 2222,
  backend: Sftpd.Backends.Memory,
  backend_opts: [],
  auth: {:passwords, [{"user", "pass"}]},
  system_dir: "/path/to/ssh_host_keys"
)
```

### S3 Backend

Stores files in Amazon S3 or S3-compatible storage such as MinIO.
The built-in S3 backend now uses range reads, paginated delimiter-based
directory listings, and multipart streaming writes for better large-file
performance.

The S3 backend is optional. Core users can depend on `:sftpd` without ExAws.
Applications that use `Sftpd.Backends.S3` must add the S3 dependency set:

```elixir
def deps do
  [
    {:sftpd, "~> 0.1.0"},
    {:ex_aws, "~> 2.0"},
    {:ex_aws_s3, "~> 2.0"},
    {:hackney, "~> 1.9"},
    {:sweet_xml, "~> 0.7"},
    {:jason, "~> 1.3"},
    {:configparser_ex, "~> 4.0"}
  ]
end
```

Without those dependencies, `Sftpd.Backends.S3.init/1` returns
`{:error, :missing_s3_dependency}`.

The same dependency set is documented in `GETTING_STARTED.md` and
`BACKENDS.md`; those guides also cover when to choose S3 instead of Memory or a
custom backend.

```elixir
Sftpd.start_server(
  port: 2222,
  backend: Sftpd.Backends.S3,
  backend_opts: [bucket: "my-bucket", prefix: "tenant-a/"],
  auth: {:passwords, [{"user", "pass"}]},
  system_dir: "/path/to/ssh_host_keys"
)
```

`backend_opts` supports:

- `:bucket` - required S3 bucket name
- `:prefix` - optional static key prefix, or `{:session, key}` to read a prefix
  from the authenticated session map
- `:aws_client` - optional ExAws-compatible client module, mainly useful for tests or custom request adapters

For Phoenix apps, use `Sftpd.child_spec/1` and an auth module:

```elixir
children = [
  {Sftpd,
   port: 2222,
   system_dir: "/run/secrets/sftp_host_keys",
   auth: {MyApp.SftpAuth, []},
   backend: Sftpd.Backends.S3,
   backend_opts: [bucket: "uploads", prefix: {:session, :sftp_prefix}]}
]
```

Your auth callbacks return a session map such as `%{user_id: user.id,
tenant_id: user.tenant_id, sftp_prefix: "tenants/#{user.tenant_id}/"}`. Backend
callbacks receive that map, and the built-in S3 backend can use it to scope
object keys per tenant.

Configure ExAws for your S3 endpoint:

```elixir
# config/config.exs
config :ex_aws,
  access_key_id: "your-key",
  secret_access_key: "your-secret",
  region: "us-east-1"

# For MinIO
config :ex_aws, :s3,
  scheme: "http://",
  host: "localhost",
  port: 9000
```

### Optional Streaming Backend Callbacks

Custom module backends can implement optional callbacks for efficient large-file
transfers:

```elixir
# read_file_range(path, offset, len, state) -> {:ok, binary} | :eof | {:error, reason}
# begin_write(path, state) -> {:ok, writer_handle} | {:error, reason}
# write_chunk(writer_handle, offset, chunk, state) -> {:ok, writer_handle} | {:error, reason}
# finish_write(writer_handle, state) -> :ok | {:error, reason}
# abort_write(writer_handle, state) -> :ok
```

These callbacks let `Sftpd.IODevice` avoid loading whole files into memory on
open and reduce write-side buffering. See `Sftpd.Backend` for the exact
callback contracts.

Note that OTP's built-in `:ssh_sftpd` implementation always reports success for
close operations, even if final close-time flushing fails. Write errors are
therefore surfaced during active writes whenever possible, while close-only
failures are logged server-side.

If you need to bound how long file opens or close-time finalization can block a
session, pass `open_timeout: timeout_in_ms` or `close_timeout: timeout_in_ms` to
`Sftpd.start_server/1`. Both default to `30_000`.

## Telemetry

`Sftpd` emits `:telemetry` events for server lifecycle and SFTP operations.
The package depends on `:telemetry` directly, so applications can attach
handlers without adding another dependency.

```elixir
:telemetry.attach(
  "sftpd-read-logger",
  [:sftpd, :sftp, :read],
  fn _event, measurements, metadata, _config ->
    Logger.info(
      "sftp read io_device=#{inspect(metadata.io_device)} bytes=#{measurements.bytes} result=#{metadata.result}"
    )
  end,
  nil
)
```

See the full telemetry event reference in `TELEMETRY.md` or
`Sftpd.Telemetry`.

### Custom Backends

Implement the `Sftpd.Backend` behaviour to create custom storage backends.
See `BACKENDS.md` for backend overview and `CUSTOM_BACKENDS.md` for a full
authoring guide.

## SSH Host Keys

Generate SSH host keys for your server:

```bash
mkdir -p ssh_keys
ssh-keygen -t rsa -f ssh_keys/ssh_host_rsa_key -N ""
ssh-keygen -t ecdsa -f ssh_keys/ssh_host_ecdsa_key -N ""
ssh-keygen -t ed25519 -f ssh_keys/ssh_host_ed25519_key -N ""
```

Then pass the directory to `system_dir`:

```elixir
Sftpd.start_server(
  # ...
  system_dir: "ssh_keys"
)
```

## Documentation

Full documentation available at [HexDocs](https://hexdocs.pm/sftpd).

## License

Apache 2.0
