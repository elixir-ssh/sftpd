# Getting Started

This guide walks through a minimal `Sftpd` setup using the in-memory backend,
then shows how to switch to S3.

## 1. Add the dependency

This guide uses the current pinned development environment:

- Erlang/OTP 29.0
- Elixir 1.20.0-rc.5 on OTP 29

The package itself still declares an older minimum Elixir version in `mix.exs`.
The current verified minimum is Elixir 1.14.5 on OTP 26.

```elixir
def deps do
  [
    {:sftpd, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## 2. Generate SSH host keys

SFTP clients expect the server to present SSH host keys. Create them once and
keep them somewhere your application can read:

```bash
mkdir -p ssh_keys
ssh-keygen -t rsa -f ssh_keys/ssh_host_rsa_key -N ""
ssh-keygen -t ecdsa -f ssh_keys/ssh_host_ecdsa_key -N ""
ssh-keygen -t ed25519 -f ssh_keys/ssh_host_ed25519_key -N ""
```

Pass the containing directory as `system_dir`.

## 3. Start a server with the memory backend

The memory backend is the fastest way to get a working server without any
external services:

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

Important options:

- `:port` controls the SSH listener port
- `:backend` selects the storage implementation
- `:backend_opts` passes backend-specific configuration
- `:users` defines password-authenticated users
- `:system_dir` points at the SSH host key directory
- `:max_sessions` limits concurrent client sessions
- `:close_timeout` bounds close-time finalization time

OTP 29 no longer enables the SFTP subsystem implicitly for SSH daemons.
`Sftpd.start_server/1` supplies the required `:subsystems` option internally,
so the setup above works on both OTP 29 and older supported OTP releases.

OTP 29 also disables remote shell and exec services by default. `Sftpd` is an
SFTP-only wrapper and does not enable those services.

## 4. Connect with an SFTP client

From another terminal:

```bash
sftp -P 2222 dev@localhost
```

Then try a few operations:

```text
put local.txt remote.txt
ls
get remote.txt
rm remote.txt
```

Because the memory backend is ephemeral, data disappears when the server stops.

## 5. Stop the server

```elixir
:ok = Sftpd.stop_server(ref)
```

## 6. Switch to the S3 backend

To persist files in S3-compatible storage, use `Sftpd.Backends.S3`:

The S3 backend is optional. The memory backend and custom backends work with
only `{:sftpd, "~> 0.1.0"}`. Add the S3 dependencies before using
`Sftpd.Backends.S3`:

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

```elixir
{:ok, ref} =
  Sftpd.start_server(
    port: 2222,
    backend: Sftpd.Backends.S3,
    backend_opts: [bucket: "my-bucket", prefix: "tenant-a/"],
    users: [{"dev", "dev"}],
    system_dir: "ssh_keys"
  )
```

S3 backend options:

- `:bucket` is required
- `:prefix` scopes keys within a bucket
- `:aws_client` lets you swap in a compatible client for tests or custom
  adapters

Example ExAws configuration:

```elixir
config :ex_aws,
  access_key_id: "your-key",
  secret_access_key: "your-secret",
  region: "us-east-1"

config :ex_aws, :s3,
  scheme: "http://",
  host: "localhost",
  port: 9000
```

## 7. Add telemetry handlers if you want instrumentation

`Sftpd` depends on `:telemetry` directly. Applications only need to attach
handlers for the events they want to consume.

See `TELEMETRY.md` for the full event reference.

## 8. Build your own backend

If neither built-in backend fits your storage model:

- read `BACKENDS.md` for backend architecture and tradeoffs
- read `CUSTOM_BACKENDS.md` for implementation guidance
- implement the `Sftpd.Backend` behaviour

## Notes and Caveats

- `Sftpd` wraps Erlang's `:ssh_sftpd` implementation and explicitly enables
  the SFTP subsystem required by OTP 29
- OTP 29 disables SSH shell and exec services by default; `Sftpd` does not
  expose or enable those services
- OTP's stock SFTP server always reports close success to the client, even if
  final close-time backend flushing fails
- backends should return POSIX-style error atoms such as `:enoent` and `:eio`
- the S3 backend models directories using `.keep` marker objects
