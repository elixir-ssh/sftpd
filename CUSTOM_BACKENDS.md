# Custom Backends

Custom backends implement `Sftpd.Backend`, the handle-first storage contract
used by both the OTP file-handler adapter and the pure-Elixir SSH/SFTP
transport.

## Minimal Shape

```elixir
defmodule MyApp.Backend do
  @behaviour Sftpd.Backend

  @impl true
  def init(opts), do: {:ok, %{root: Keyword.fetch!(opts, :root)}}

  @impl true
  def open_read(_path, _session, _state), do: {:error, :enoent}

  @impl true
  def read_at(_handle, _offset, _len, _state), do: :eof

  @impl true
  def open_write(path, _attrs, _session, _state), do: {:ok, %{path: path, chunks: []}}

  @impl true
  def write_at(handle, _offset, _data, _state), do: {:ok, handle}

  @impl true
  def finish_write(_handle, _state), do: :ok

  @impl true
  def abort_write(_handle, _state), do: :ok

  @impl true
  def open_dir(_path, _session, _state), do: {:ok, %{entries: [], read?: false}}

  @impl true
  def read_dir(%{read?: false} = handle, _state),
    do: {:ok, handle.entries, %{handle | read?: true}}

  def read_dir(%{read?: true}, _state), do: :eof

  @impl true
  def close_dir(_handle, _state), do: :ok

  @impl true
  def file_attrs(_path, _session, _state), do: {:error, :enoent}

  @impl true
  def make_dir(_path, _attrs, _session, _state), do: :ok

  @impl true
  def del_dir(_path, _session, _state), do: :ok

  @impl true
  def delete(_path, _session, _state), do: :ok

  @impl true
  def rename(_src, _dst, _session, _state), do: :ok
end
```

Callback paths are binary SFTP paths. Use `Sftpd.Backend.normalize_path/1` and
`Sftpd.Backend.root_path?/1` when adapting them to storage keys.
Backends own the opaque handles returned from `open_read/3`, `open_write/4`,
and `open_dir/3`; transports pass those handles back to the corresponding
read, write, finish, abort, and close callbacks.

`file_attrs/3` returns a map. The common keys are:

- `:type`, either `:regular` or `:directory`
- `:size`
- `:permissions`
- `:uid`
- `:gid`
- `:atime`
- `:mtime`

Use `Sftpd.Backend.attrs_from_file_info/1` if you already have Erlang
`file_info` tuples.

## Performance Notes

- Return existing binaries or iodata from `read_at/4`; avoid concatenating large
  responses just to satisfy the callback.
- Keep write handles as backend-owned state and flush incrementally from
  `write_at/4` when the backend can do so.
- `finish_write/2` is where close-time materialization belongs. The OTP
  transport cannot reliably report close-time failures to all clients, so
  surface write errors during `write_at/4` whenever possible.
- Directory handles may return entries in batches. `read_dir/2` should return
  `:eof` when the handle is exhausted.
