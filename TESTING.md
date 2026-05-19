# Sftpd Testing Guide

## Quick Test

Run the automated test suite:
```bash
mix test
```

## Manual Testing Options

### Option 1: Elixir Test Script
Run the manual Elixir test script that tests upload/download operations:
```bash
mix run test_manual.exs
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
iex -S mix
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

The tests use a local S3-compatible service (configured in `config/test.exs`).

Default settings:
- Bucket: `sftpd-test-bucket`
- SFTP Port: `2222` (or `2223` for manual script)
- Username: `user`
- Password: `password`

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
