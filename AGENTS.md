# AGENTS.md

## Project Overview

Sftpd is an Elixir library that provides an SFTP-only SSH daemon with
pluggable backends (memory, S3, and custom modules). The default transport uses
OTP's `:ssh_sftpd` subsystem; `transport: :elixir` uses the experimental
pure-Elixir SSH/SFTP implementation.

`Sftpd.start_server/1` explicitly configures the SFTP subsystem via
`:ssh_sftpd.subsystem_spec/1`. This matters on OTP 29, where SSH daemons no
longer enable SFTP implicitly. OTP 29 also disables shell and exec services by
default; this project should remain SFTP-only unless the user explicitly asks
for a broader SSH daemon API.

## Architecture

- `lib/sftpd.ex` - Main module, starts the SSH daemon with configurable backend
- `lib/sftpd/backend.ex` - Behaviour definition for storage backends
- `lib/sftpd/file_handler.ex` - Adapts the handle-first backend API to OTP's `:ssh_sftpd_file_api`
- `lib/sftpd/direct_io_device.ex` - Opaque open-file handles used by the OTP file-handler adapter
- `lib/sftpd/ssh/` - Experimental pure-Elixir SSH transport
- `lib/sftpd/sftp/` - Pure-Elixir SFTP v3 parser and dispatcher
- `lib/sftpd/backends/s3.ex` - S3 storage backend
- `lib/sftpd/backends/memory.ex` - In-memory backend for testing

## Development

### Prerequisites

- Erlang/OTP 29.0
- Elixir 1.20.0-rc.5 on OTP 29
- MinIO for S3 integration tests

### Version Management

**Important:** `.tool-versions` is the single source of truth for the pinned development runtime. `flake.nix` reads that file and derives the matching BEAM package set from it. The current pinned development environment is OTP 29.0 with Elixir 1.20.0-rc.5-otp-29, while the verified minimum support target is Elixir 1.14.5 on OTP 26 and the package requirement remains `~> 1.14`.

When updating SSH/SFTP code or docs, remember the OTP 29 behavior change:
SFTP must be configured through the daemon `:subsystems` option, while shell
and exec are disabled unless explicitly configured.

### Running Tests

```bash
nix develop -c mix test
```

Integration tests use MinIO as the S3 backend. The bucket
`sftpd-test-bucket` is used for integration tests.

```bash
docker compose up -d minio
nix develop -c mix test --only integration
```

### Manual Testing

```bash
./test_sftp.sh
# or
mix run test_manual.exs
```

## S3 Constraints

- S3 multipart uploads require minimum 5MB per part
- Small file writes use single-part uploads when `finish_write/2` closes the
  backend-owned handle
- Directories are virtual (represented by `.keep` marker files)

## Configuration

Set in `config/config.exs` or `config/test.exs`:

- `:bucket` - S3 bucket name
- ExAws configuration for S3 endpoint (MinIO uses `http://localhost:9000`)
