# Sftpd Testing Guide

## Quick Test

Run the default automated test suite. Integration tests are excluded by default
so this does not require MinIO:
```bash
mix test
```

Run the non-integration suite without starting MinIO:
```bash
mix test --exclude consumer_project
```

Run the consumer compatibility checks:
```bash
mix test --only consumer_project
```

## Manual Testing Options

### Option 1: Elixir Test Script
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

### Option 2: Shell Script with Real SFTP Client
Run the bash script that uses the system `sftp` command:
```bash
./test_sftp.sh
```

Note: This requires the `sftp` command-line tool to be installed.

### Option 3: Interactive Testing

1. Start the SFTP server:
```elixir
MIX_ENV=test iex -S mix
iex> system_dir = Sftpd.Test.SSHKeys.generate_system_dir()
iex> Sftpd.start_server(
...>   port: 2222,
...>   backend: Sftpd.Backends.S3,
...>   backend_opts: [bucket: "sftpd-test-bucket"],
...>   users: [{"user", "password"}],
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

The integration tests use MinIO from `docker-compose.yml`:

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

## What Was Fixed

The following critical issues were resolved:

1. **File Upload Support**: Fixed IODevice state initialization to properly handle write operations with S3 multipart upload
2. **Concurrent Operations**: Removed GenServer name collision to allow multiple simultaneous file operations
3. **Error Handling**: Added proper error handling in `is_dir/2` and other functions
4. **Delete Operations**: Implemented S3-based file deletion
5. **Rename Operations**: Implemented S3-based file renaming (copy + delete)
6. **Type Conversions**: Fixed charlist/string conversions throughout Operations module

## Expected Behavior

- ✅ **Upload files** via SFTP to S3
- ✅ **Download files** from S3 via SFTP
- ✅ **List directories** and files
- ✅ **Create/delete directories**
- ✅ **Delete files**
- ✅ **Rename files**
- ✅ **Multiple concurrent operations**
