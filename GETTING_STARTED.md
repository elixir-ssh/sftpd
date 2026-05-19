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
    {:sftpd, "~> 0.2.0"}
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
  port: 4566
```

## 7. Add telemetry if you want instrumentation

Telemetry support is optional. If your application wants to attach handlers and
does not already depend on `:telemetry`, add it explicitly:

```elixir
def deps do
  [
    {:telemetry, ">= 0.4.3 and < 2.0.0"},
    {:sftpd, "~> 0.2.0"}
  ]
end
```

See `TELEMETRY.md` for the full event reference.

## 8. Build your own backend

If neither built-in backend fits your storage model:

- read `BACKENDS.md` for backend architecture and tradeoffs
- read `CUSTOM_BACKENDS.md` for implementation guidance
- implement the `Sftpd.Backend` behaviour

## Notes and Caveats

- `Sftpd` wraps Erlang's `:ssh_sftpd` implementation
- OTP's stock SFTP server always reports close success to the client, even if
  final close-time backend flushing fails
- backends should return POSIX-style error atoms such as `:enoent` and `:eio`
- the S3 backend models directories using `.keep` marker objects
