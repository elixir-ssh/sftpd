defmodule Sftpd.Telemetry do
  @moduledoc """
  Telemetry helpers and event conventions for `Sftpd`.

  `Sftpd` depends on the lightweight `:telemetry` library and emits events
  through the shared Erlang/Elixir instrumentation interface.

  See the `Telemetry` extra in HexDocs for the full event reference, payload
  details, examples, and caveats.

  The library emits these events:

  - `[:sftpd, :server, :start]`
  - `[:sftpd, :server, :stop]`
  - `[:sftpd, :sftp, operation]` for `:close`, `:del_dir`, `:delete`, `:get_cwd`,
    `:is_dir`, `:list_dir`, `:make_dir`, `:make_symlink`, `:open`, `:position`,
    `:read`, `:read_file_info`, `:read_link`, `:read_link_info`, `:rename`,
    `:write`, and `:write_file_info`

  Every event includes a `:duration` measurement in native time units.
  Read and write events also include a `:bytes` measurement.

  Common metadata:

  - SFTP operation events include `:backend`, `:backend_kind`, `:result`, and
    `:reason` when an error reason exists
  - `:open` also includes `:path`, `:requested_modes`, and `:mode`
  - `:close` also includes `:io_device`, `:close_timeout`, and
    `:close_shutdown_grace`
  - `:read` also includes `:io_device` and `:bytes_requested`
  - `:write` also includes `:io_device`
  - path-oriented operations include `:path`
  - `:rename` includes `:src_path` and `:dst_path`
  - `:position` includes `:io_device` and `:offset`
  - `:is_dir` uses `:directory` and `:not_directory` result values
  - server lifecycle events include `:backend`, `:backend_kind`, and `:result`,
    plus `:port`/`:max_sessions` on start and `:server_ref` on successful start
    or stop
  """

  @type event_name :: [atom()]
  @type measurements :: map()
  @type metadata :: map()
  @type finalize_fun :: (term(), integer() -> {measurements(), metadata()})

  @doc """
  Execute an event with measurements and metadata.
  """
  @spec execute(event_name(), measurements(), metadata()) :: :ok
  def execute(event_name, measurements, metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end

  @doc """
  Measure a function call, emit a telemetry event, and return the original result.
  """
  @spec span(event_name(), metadata(), (-> term()), finalize_fun()) :: term()
  def span(event_name, metadata, fun, finalize_fun \\ &default_finalize/2) do
    start = System.monotonic_time()

    try do
      result = fun.()
      duration = System.monotonic_time() - start
      {measurements, extra_metadata} = finalize_fun.(result, duration)
      execute(event_name, measurements, Map.merge(metadata, extra_metadata))
      result
    catch
      kind, reason ->
        duration = System.monotonic_time() - start

        execute(
          event_name,
          %{duration: duration},
          Map.merge(metadata, %{result: :exception, kind: kind, reason: reason})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp default_finalize(_result, duration), do: {%{duration: duration}, %{}}
end
