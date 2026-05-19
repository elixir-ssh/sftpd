# CLAUDE.md

## Project Overview

Sftpd is an Elixir library that provides a pluggable SFTP server with support for multiple backends (S3, memory, custom). It implements a file handler for OTP's `:ssh_sftpd` subsystem.

`Sftpd.start_server/1` explicitly configures the SFTP subsystem via
`:ssh_sftpd.subsystem_spec/1`. This matters on OTP 29, where SSH daemons no
longer enable SFTP implicitly. OTP 29 also disables shell and exec services by
default; this project should remain SFTP-only unless the user explicitly asks
for a broader SSH daemon API.

## Architecture

- `lib/sftpd.ex` - Main module, starts the SSH daemon with configurable backend
- `lib/sftpd/backend.ex` - Behaviour definition for storage backends
- `lib/sftpd/file_handler.ex` - Implements `:ssh_sftpd_file_api` behaviour
- `lib/sftpd/io_device.ex` - GenServer managing file handles for read/write operations
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
# Start MinIO first
docker compose up -d minio

# Run tests
mix test
```

Tests use MinIO as the S3 backend. The bucket `sftpd-test-bucket` is used for integration tests.

### Manual Testing

```bash
./test_sftp.sh
# or
mix run test_manual.exs
```

## S3 Constraints

- S3 multipart uploads require minimum 5MB per part
- Small file writes use single-part uploads via the terminate callback
- Directories are virtual (represented by `.keep` marker files)

## Configuration

Set in `config/config.exs` or `config/test.exs`:

- `:bucket` - S3 bucket name
- ExAws configuration for S3 endpoint (MinIO uses `http://localhost:9000`)
