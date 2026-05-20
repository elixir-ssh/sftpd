# Telemetry

`Sftpd` emits `:telemetry` events for server lifecycle and SFTP operations.
The package depends on `:telemetry` directly, so applications can attach
handlers without adding another dependency.

## Installing `Sftpd`

```elixir
def deps do
  [
    {:sftpd, "~> 0.1.0"}
  ]
end
```

## Event Families

`Sftpd` emits three event families:

- `[:sftpd, :server, :start]`
- `[:sftpd, :server, :stop]`
- `[:sftpd, :sftp, operation]`

`operation` is one of:

- `:open`
- `:close`
- `:read`
- `:write`
- `:list_dir`
- `:read_file_info`
- `:read_link_info`
- `:read_link`
- `:rename`
- `:delete`
- `:make_dir`
- `:del_dir`
- `:position`
- `:is_dir`
- `:get_cwd`
- `:make_symlink`
- `:write_file_info`

## Measurements

Every event includes:

- `%{duration: native_time}`

Additional measurements:

- `:read` adds `:bytes`
- `:write` adds `:bytes`

`duration` is measured with `System.monotonic_time/0` native units. Convert it
with `System.convert_time_unit/3` before exporting or logging human-readable
durations.

## Metadata

### Common SFTP Metadata

All `[:sftpd, :sftp, operation]` events include:

- `:backend`
- `:backend_kind`
- `:result`
- `:reason` when an error reason is available

`backend_kind` is one of:

- `:module`
- `:genserver`

For `{:genserver, server}` backends, `:backend` is `inspect(server)` rather
than a module name.

### Result Values

Most operations use:

- `:ok`
- `:error`

Special cases:

- `:read` may emit `:eof`
- `:is_dir` emits `:directory` or `:not_directory`
- exceptions inside `Sftpd.Telemetry.span/4` emit `result: :exception` plus
  `:kind` and `:reason`, then are reraised

### Operation-Specific Metadata

`[:sftpd, :sftp, :open]`

- `:path`
- `:requested_modes`
- `:mode`
- `:open_timeout`

`requested_modes` contains the raw mode list passed into the SFTP file handler.
`mode` is the resolved value `:read` or `:write` after `Sftpd` normalizes it.

`[:sftpd, :sftp, :close]`

- `:io_device`
- `:close_timeout`
- `:close_shutdown_grace`

`[:sftpd, :sftp, :read]`

- `:io_device`
- `:bytes_requested`

The `:read` event does not include `:path`. If you need path-level context for
reads, correlate the `:io_device` back to the earlier `[:sftpd, :sftp, :open]`
event for that handle.

`[:sftpd, :sftp, :write]`

- `:io_device`

`[:sftpd, :sftp, :position]`

- `:io_device`
- `:offset`

`[:sftpd, :sftp, :rename]`

- `:src_path`
- `:dst_path`

Path-based operations such as `:list_dir`, `:read_file_info`, `:read_link_info`,
`:delete`, `:make_dir`, and `:del_dir` add:

- `:path`

### Server Metadata

`[:sftpd, :server, :start]`

- `:port`
- `:max_sessions`
- `:backend`
- `:backend_kind`
- `:result`
- `:server_ref` on success

`[:sftpd, :server, :stop]`

- `:server_ref`
- `:result`

## Examples

Attach a single handler:

```elixir
:telemetry.attach(
  "sftpd-read-logger",
  [:sftpd, :sftp, :read],
  fn _event, measurements, metadata, _config ->
    Logger.info(
      "sftp read io_device=#{inspect(metadata.io_device)} bytes=#{measurements.bytes} result=#{metadata.result}"
    )
  end,
  nil
)
```

Attach one handler to multiple events:

```elixir
:telemetry.attach_many(
  "sftpd-audit",
  [
    [:sftpd, :server, :start],
    [:sftpd, :server, :stop],
    [:sftpd, :sftp, :write],
    [:sftpd, :sftp, :delete]
  ],
  fn event, measurements, metadata, _config ->
    Logger.info("""
    event=#{inspect(event)}
    duration_native=#{measurements.duration}
    result=#{metadata.result}
    backend=#{inspect(metadata.backend)}
    """)
  end,
  nil
)
```

Convert durations before exporting metrics:

```elixir
:telemetry.attach(
  "sftpd-read-metrics",
  [:sftpd, :sftp, :read],
  fn _event, measurements, metadata, _config ->
    duration_us =
      System.convert_time_unit(measurements.duration, :native, :microsecond)

    Logger.info(
      "read io_device=#{inspect(metadata.io_device)} bytes=#{measurements.bytes} duration_us=#{duration_us}"
    )
  end,
  nil
)
```

## Caveats

- OTP's built-in `:ssh_sftpd` implementation always reports close success to
  the client, even if final close-time flushing fails. Telemetry still records
  those server-side close failures, but the client may not see them.
- Telemetry is emitted from `Sftpd` and `Sftpd.FileHandler`, so event timings
  reflect the library's wrapper and backend call boundaries rather than network
  round-trip timings observed by the SFTP client.
- Handlers run in the emitting process, so avoid slow handler work.
