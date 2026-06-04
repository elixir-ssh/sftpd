# Backends

`Sftpd.Backend` is a handle-first storage contract. Backends own open file and
directory state, and transports call them with normalized binary paths plus
explicit read/write offsets.

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

The S3 backend is still present as legacy storage code, but it is not migrated
to the handle-first contract in this milestone. Use the memory backend for the
pure-Elixir transport until S3 is rewritten around backend-owned handles.

## Callback Shape

Backends implement:

- `init/1`
- `open_read/3` and `read_at/4`
- `open_write/4`, `write_at/4`, `finish_write/2`, and `abort_write/2`
- `open_dir/3`, `read_dir/2`, and `close_dir/2`
- `file_attrs/3`
- `make_dir/4`, `del_dir/3`, `delete/3`, and `rename/4`

See `Sftpd.Backend` for exact types and helper functions.
