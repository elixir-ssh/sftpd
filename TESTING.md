# Sftpd Testing Guide

## Quick Test

Run the default automated test suite. Integration tests are excluded by default
so this does not require MinIO:

```bash
mix test
```

Run the consumer compatibility checks:

```bash
mix test --only consumer_project
```

## Manual Testing Options

### Elixir Test Script

Run the manual Elixir test script that tests upload/download operations:

```bash
MIX_ENV=test mix run test_manual.exs
```

This script will:
- Start an SFTP server
- Connect an SFTP client
- Create a directory
- Upload a file
- Download and verify the file
- Clean up

### Shell Script With Real SFTP Client

Run the bash script that uses the system `sftp` command:

```bash
./test_sftp.sh
```

This requires the OpenSSH `sftp` command-line tool.

### Interactive Testing

1. Start the SFTP server:

```elixir
MIX_ENV=test iex -S mix
iex> system_dir = Sftpd.Test.SSHKeys.generate_system_dir()
iex> Sftpd.start_server(
...>   port: 2222,
...>   backend: Sftpd.Backends.S3,
...>   backend_opts: [bucket: "sftpd-test-bucket"],
...>   auth: {:passwords, [{"user", "password"}]},
...>   system_dir: system_dir
...> )
```

2. In another terminal, connect with an SFTP client:

```bash
sftp -P 2222 user@localhost
# Password: password
```

3. Try SFTP commands:
```
sftp> ls
sftp> mkdir test
sftp> cd test
sftp> put local_file.txt
sftp> get local_file.txt downloaded.txt
sftp> rm local_file.txt
sftp> cd ..
sftp> rmdir test
sftp> quit
```

## Configuration

The integration tests use MinIO on `localhost:9000`. The Nix dev shell includes
the MinIO server and client, so Docker is optional.

Without Docker:

```bash
export MINIO_ROOT_USER=minioadmin
export MINIO_ROOT_PASSWORD=minioadmin
mkdir -p .minio-data
minio server .minio-data
```

Run the server in a separate terminal, then run:

```bash
mix test --only integration
```

With Docker:

```bash
docker compose up -d minio
mix test --only integration
docker compose down
```

Default settings:

- Bucket: `sftpd-test-bucket`
- S3 endpoint: `http://localhost:9000`
- AWS access key: `minioadmin`
- AWS secret key: `minioadmin`
- SFTP Port: `2222` (or `2223` for manual scripts)
- Username: `user`
- Password: `password`

## OTP 29 SSH Behavior

OTP 29 requires SFTP daemons to opt into the SFTP subsystem explicitly.
The public `Sftpd.start_server/1` path does that with
`:ssh_sftpd.subsystem_spec/1`, so tests should start servers through `Sftpd`
unless they are deliberately testing raw OTP SSH behavior.

OTP 29 also leaves SSH shell and exec services disabled by default. The tests
exercise SFTP only and should not assume an interactive Erlang shell or remote
exec channel is available on the test daemon.

## Backend Contract Coverage

The default suite covers the handle-first `Sftpd.Backend` contract through:

- Memory backend callback tests for direct reads, writes, directories, metadata,
  and renames.
- S3 backend tests for ranged reads, multipart writes, directory handles,
  session prefixes, and error normalization.
- OTP file-handler tests for adapting `:ssh_sftpd_file_api` to backend-owned
  handles.
- Pure-Elixir transport tests for SSH negotiation, authentication, SFTP v3
  operations, OpenSSH `sftp` compatibility, and rejection of shell/exec
  requests.
- Benchmark backend tests for size-tracking uploads and zero-filled ranged
  downloads.

Integration tests add MinIO-backed S3 coverage through the public server API.
