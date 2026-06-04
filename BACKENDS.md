# Backends

`Sftpd.Backend` is a handle-first storage contract. Backends own open file and
directory state, and transports call them with binary SFTP paths plus explicit
read/write offsets. Backends normalize paths for their own storage keys.

## Built-In Backends

### `Sftpd.Backends.Memory`

The memory backend stores files in an `Agent` and implements the full
handle-first backend contract. It is intended for development, tests, and
benchmarking the SSH/SFTP hot path without external storage.

### `Sftpd.Backends.Benchmark`

The benchmark backend records uploaded file sizes and returns zero-filled
download ranges. It avoids allocating full file contents so benchmarks focus on
SSH/SFTP framing and transport overhead.

### `Sftpd.Backends.S3`

The S3 backend maps SFTP operations onto Amazon S3 or S3-compatible object
storage. It implements the handle-first contract with ranged reads and
multipart writes behind backend-owned handles.

Directory listings come from S3 LIST operations. Listed entries carry generic
attrs; call `file_attrs/3` for a specific path when exact object metadata is
needed.

## Callback Shape

Backends implement:

- `init/1`
- `open_read/3` and `read_at/4`
- `open_write/4`, `write_at/4`, `finish_write/2`, and `abort_write/2`
- `open_dir/3`, `read_dir/2`, and `close_dir/2`
- `file_attrs/3`
- `make_dir/4`, `del_dir/3`, `delete/3`, and `rename/4`

See `Sftpd.Backend` for exact types and helper functions.

## Transport Support

Both `transport: :otp` and `transport: :elixir` use this same backend
contract. The OTP transport adapts the handle API to `:ssh_sftpd_file_api`;
the pure-Elixir transport calls it from the SFTP v3 dispatcher directly.
