# Sftpd

A pluggable SFTP server for Elixir with memory, custom, and optional S3
backends.

`Sftpd` provides an SFTP-only SSH daemon with pluggable storage. The default
transport uses Erlang's
`:ssh_sftpd` subsystem; `transport: :elixir` opts into the experimental
pure-Elixir SSH/SFTP transport. It ships with:

- an in-memory backend for development and tests
- an optional S3 backend with range reads and multipart streaming writes
- password and public-key auth callbacks that return per-session context
- telemetry hooks around server lifecycle and SFTP operations

## Installation

Runtime targets:

- package requirement: Elixir `~> 1.14`
- verified minimum runtime: Elixir 1.14.5 on OTP 26
- pinned development runtime: OTP 29.0 with Elixir 1.20.0-rc.5

```elixir
def deps do
  [
    {:sftpd, "~> 0.2.0"}
  ]
end
```

## Quick Start

```elixir
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

- [Getting Started](GETTING_STARTED.md) for a step-by-step setup guide
- [Phoenix Setup](PHOENIX.md) for supervised Phoenix setup with app auth and S3
- [Backends](BACKENDS.md) for backend architecture and built-in backend tradeoffs
- [Custom Backends](CUSTOM_BACKENDS.md) for implementing your own backend
- [Telemetry](TELEMETRY.md) for emitted events, metadata, and examples

## Key Concepts

- `Sftpd.start_server/1` starts an SFTP-only SSH daemon
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
| A shared cache, queue, or connection pool | A custom `Sftpd.Backend` module |
| Async ingestion after upload | Store synchronously in the backend, then enqueue a Broadway job |

See [Backends](BACKENDS.md) for backend tradeoffs and
[Custom Backends](CUSTOM_BACKENDS.md) for folder, supervision, and
post-write processing examples.

## Next Steps

- Adding SFTP to a Phoenix app? Start with [Phoenix Setup](PHOENIX.md).
- Choosing storage? Read [Backends](BACKENDS.md).
- Implementing your own storage layer? Read [Custom Backends](CUSTOM_BACKENDS.md).
- Wiring observability? Read [Telemetry](TELEMETRY.md).

## Backends

### Memory Backend

Stores files in memory. Useful for development and tests.

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

Stores files in Amazon S3 or S3-compatible storage such as MinIO. It uses range
reads, delimiter-based directory listings, and multipart writes.

The S3 backend is optional. Core users can depend on `:sftpd` without ExAws.
Applications that use `Sftpd.Backends.S3` must add the S3 dependency set:

```elixir
def deps do
  [
    {:sftpd, "~> 0.2.0"},
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
- `:aws_client` - optional ExAws-compatible client module, mainly useful for
  tests or custom request adapters

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

### Handle-First Backend Callbacks

Custom module backends implement handle-first callbacks for efficient large-file
transfers:

```elixir
# open_read(path, session, state) -> {:ok, read_handle} | {:error, reason}
# read_at(read_handle, offset, len, state) -> {:ok, iodata} | :eof | {:error, reason}
# open_write(path, attrs, session, state) -> {:ok, writer_handle} | {:error, reason}
# write_at(writer_handle, offset, chunk, state) -> {:ok, writer_handle} | {:error, reason}
# finish_write(writer_handle, state) -> :ok | {:error, reason}
# abort_write(writer_handle, state) -> :ok
```

These callbacks let the OTP file-handler adapter and the pure-Elixir transport
operate on backend-owned handles without loading whole files into memory on open
or routing hot-path file IO through per-file processes. See `Sftpd.Backend` for
the exact callback contracts.

The pure-Elixir transport validates the same `Sftpd.Backend` callback set at
startup. The built-in OTP transport and pure-Elixir transport therefore use the
same backend modules; only the SSH/SFTP framing layer changes.

Note that OTP's built-in `:ssh_sftpd` implementation always reports success for
close operations, even if final close-time flushing fails. Write errors are
therefore surfaced during active writes whenever possible, while close-only
failures are logged server-side.

Backend open, read, write, and close work runs through backend-owned handles.
Long-running backend operations should enforce their own timeouts.

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

See the full telemetry event reference in [Telemetry](TELEMETRY.md) or
`Sftpd.Telemetry`.

### Custom Backends

Implement the `Sftpd.Backend` behaviour to create custom storage backends.
See [Backends](BACKENDS.md) for backend overview and
[Custom Backends](CUSTOM_BACKENDS.md) for a full authoring guide.

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

Full documentation is available at
[HexDocs](https://hexdocs.pm/sftpd).

## Erlang/OTP 29 Note

OTP 29 no longer enables SFTP implicitly for SSH daemons and also disables
shell and exec services by default. `Sftpd.start_server/1` already passes the
required SFTP subsystem configuration, so applications using this package do
not need to configure OTP SSH subsystems themselves.

## License

Apache 2.0
