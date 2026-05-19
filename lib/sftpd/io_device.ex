defmodule Sftpd.IODevice do
  @moduledoc """
  GenServer that manages SFTP file handles.

  Reads use backend range callbacks when available. Writes are persisted to a
  local temp file immediately and optionally mirrored to backend streaming
  callbacks for lower memory usage on large transfers.
  """

  use GenServer

  require Logger

  alias Sftpd.Backend

  @default_open_timeout 30_000
  @stream_chunk_size 5 * 1024 * 1024

  @type mode :: :read | :write
  @type read_strategy :: :range | :buffered
  @type write_strategy :: :legacy | :streaming | :streaming_replay

  @doc """
  Start an IODevice process (not linked to caller).
  """
  @spec start(map()) :: GenServer.on_start()
  def start(opts) do
    open_timeout = Map.get(opts, :open_timeout, @default_open_timeout)

    with {:ok, pid} <- GenServer.start(__MODULE__, opts) do
      await_open_result(pid, open_timeout)
    end
  end

  defp await_open_result(pid, open_timeout) do
    case GenServer.call(pid, :open_result, open_timeout) do
      :ok -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, {:timeout, _call} ->
      Logger.error(
        "Timed out waiting #{open_timeout}ms for IODevice #{inspect(pid)} to open; terminating it"
      )

      terminate_timed_out_open(pid)
      {:error, :timeout}
  end

  defp terminate_timed_out_open(pid) do
    state = timed_out_open_state(pid)

    case stop_timed_out_open(pid) do
      :ok ->
        :ok

      :noproc ->
        :ok

      :timeout ->
        cleanup_timed_out_open(state)
        kill_timed_out_open(pid)
    end
  end

  defp stop_timed_out_open(pid) do
    GenServer.stop(pid, :shutdown, 1_000)
    :ok
  catch
    :exit, {:noproc, _call} ->
      :noproc

    :exit, {:timeout, _call} ->
      :timeout
  end

  defp timed_out_open_state(pid) do
    :sys.get_state(pid, 100)
  catch
    :exit, _reason -> nil
  end

  defp cleanup_timed_out_open(%{mode: :write} = state) do
    cleanup_open_worker(state)
    cleanup_unfinished(state)
  end

  defp cleanup_timed_out_open(state) when is_map(state) do
    cleanup_open_worker(state)
  end

  defp cleanup_timed_out_open(_state), do: :ok

  defp kill_timed_out_open(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(ref, [:flush])
    end
  end

  @impl GenServer
  def init(%{path: path, mode: mode, backend: backend, backend_state: backend_state}) do
    {:ok,
     %{
       path: path,
       mode: mode,
       backend: backend,
       backend_state: backend_state,
       position: 0,
       size: 0,
       finalized?: false,
       open_status: :pending,
       open_waiters: []
     }, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(
        :open,
        %{path: path, mode: :read, backend: backend, backend_state: backend_state} = state
      ) do
    worker =
      start_open_worker(fn ->
        open_read_device(path, backend, backend_state)
      end)

    {:noreply, Map.put(state, :open_worker, worker)}
  end

  def handle_continue(
        :open,
        %{path: path, mode: :write, backend: backend, backend_state: backend_state} = state
      ) do
    case open_temp_file() do
      {:ok, temp_path, temp_fd} ->
        state =
          state
          |> Map.put(:temp_path, temp_path)
          |> Map.put(:temp_fd, temp_fd)

        if streaming_write_supported?(backend) do
          worker =
            start_open_worker(fn ->
              open_streaming_write(path, backend, backend_state)
            end)

          {:noreply, Map.put(state, :open_worker, worker)}
        else
          {:noreply, complete_open({:ok, %{write_strategy: :legacy}}, state)}
        end

      {:error, reason} ->
        Logger.error("Failed to create temp file for #{inspect(path)}: #{inspect(reason)}")
        {:noreply, complete_open({:error, reason}, state)}
    end
  end

  @impl GenServer
  def handle_call(:open_result, from, %{open_status: :pending, open_waiters: waiters} = state) do
    {:noreply, %{state | open_waiters: [from | waiters]}}
  end

  def handle_call(:open_result, _from, %{open_status: {:error, reason}} = state) do
    {:stop, :normal, {:error, reason}, state}
  end

  def handle_call(:open_result, _from, %{open_status: :ok} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:position, offset}, _from, state) do
    case position_from_offset(state, offset) do
      {:ok, new_position} ->
        {:reply, {:ok, new_position}, %{state | position: new_position}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read, _length}, _from, %{error: reason} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call(
        {:read, _length},
        _from,
        %{read_strategy: :buffered, size: size, position: pos} = state
      )
      when pos >= size do
    {:reply, :eof, state}
  end

  def handle_call(
        {:read, length},
        _from,
        %{read_strategy: :buffered, content: content, size: size, position: pos} = state
      ) do
    bytes_to_read = min(length, size - pos)
    data = binary_part(content, pos, bytes_to_read)
    {:reply, {:ok, data}, %{state | position: pos + bytes_to_read}}
  end

  def handle_call(
        {:read, length},
        _from,
        %{
          read_strategy: :range,
          path: path,
          position: pos,
          backend: backend,
          backend_state: backend_state
        } = state
      ) do
    case Backend.call(backend, :read_file_range, [path, pos, length, backend_state]) do
      {:ok, data} when byte_size(data) > 0 ->
        bytes_read = byte_size(data)
        {:reply, {:ok, data}, %{state | position: pos + bytes_read}}

      {:ok, <<>>} ->
        {:reply, :eof, state}

      :eof ->
        {:reply, :eof, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, state) do
    {reply, state} = finalize(state)
    {:stop, :normal, reply, %{state | finalized?: true}}
  end

  def handle_call({:write, _data}, _from, %{error: reason} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:write, _data, _bytes}, _from, %{error: reason} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:write, data, bytes}, _from, %{mode: :write} = state) do
    handle_write(data, bytes, state)
  end

  def handle_call({:write, data}, _from, %{mode: :write} = state) do
    handle_write(data, IO.iodata_length(data), state)
  end

  defp handle_write(data, bytes, state) do
    with :ok <- persist_to_tempfile(state.temp_fd, state.position, data),
         {:ok, state} <- maybe_stream_write(state, data, bytes) do
      new_size = max(state.size, state.position + bytes)
      {:reply, :ok, %{state | position: state.position + bytes, size: new_size}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, Map.put(state, :error, reason)}
    end
  end

  @impl GenServer
  def handle_info(
        {:open_result, worker, {:error, _reason} = result},
        %{open_worker: worker, open_waiters: waiters} = state
      ) do
    state = complete_open(result, state)

    if waiters == [] do
      {:noreply, state}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info({:open_result, worker, result}, %{open_worker: worker} = state) do
    {:noreply, complete_open(result, state)}
  end

  def handle_info({:open_result, _worker, _result}, state) do
    {:noreply, state}
  end

  def handle_info({:file_request, _, _ref, :close}, state) do
    {_reply, state} = finalize(state)
    {:stop, :normal, %{state | finalized?: true}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{finalized?: true}), do: :ok

  def terminate(_reason, %{mode: :write} = state) do
    cleanup_open_worker(state)
    cleanup_unfinished(state)
  end

  def terminate(_reason, state) do
    cleanup_open_worker(state)
  end

  defp start_open_worker(fun) do
    parent = self()

    spawn(fn ->
      send(parent, {:open_result, self(), run_open_worker(fun)})
    end)
  end

  defp run_open_worker(fun) do
    fun.()
  rescue
    exception ->
      Logger.error("IODevice open worker failed: #{Exception.message(exception)}")
      {:error, :eio}
  catch
    kind, reason ->
      Logger.error("IODevice open worker exited: #{inspect({kind, reason})}")
      {:error, :eio}
  end

  defp open_read_device(path, backend, backend_state) do
    if Backend.supports_callback?(backend, :read_file_range, 4) do
      case Backend.call(backend, :file_info, [path, backend_state]) do
        {:ok, file_info} ->
          {:ok, %{read_strategy: :range, size: extract_file_size(file_info)}}

        {:error, reason} ->
          Logger.warning("Failed to stat file #{inspect(path)}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      case Backend.call(backend, :read_file, [path, backend_state]) do
        {:ok, content} ->
          {:ok, %{read_strategy: :buffered, content: content, size: byte_size(content)}}

        {:error, reason} ->
          Logger.warning("Failed to read file #{inspect(path)}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp open_streaming_write(path, backend, backend_state) do
    case Backend.call(backend, :begin_write, [path, backend_state]) do
      {:ok, writer_handle} ->
        {:ok, %{write_strategy: :streaming, writer_handle: writer_handle, stream_offset: 0}}

      {:error, reason} ->
        Logger.error(
          "Failed to initialize streaming write for #{inspect(path)}: #{inspect(reason)}"
        )

        {:ok, %{write_strategy: :streaming_replay}}
    end
  end

  defp complete_open({:ok, updates}, state) do
    reply_open_waiters(state, :ok)

    state
    |> Map.merge(updates)
    |> Map.put(:open_status, :ok)
    |> Map.put(:open_waiters, [])
    |> Map.delete(:open_worker)
  end

  defp complete_open({:error, reason}, state) do
    reply_open_waiters(state, {:error, reason})

    state
    |> Map.put(:open_status, {:error, reason})
    |> Map.put(:open_waiters, [])
    |> Map.delete(:open_worker)
  end

  defp reply_open_waiters(%{open_waiters: waiters}, reply) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
  end

  defp cleanup_open_worker(%{open_worker: worker}) when is_pid(worker) do
    if Process.alive?(worker), do: Process.exit(worker, :kill)
    :ok
  end

  defp cleanup_open_worker(_state), do: :ok

  defp maybe_stream_write(%{write_strategy: :legacy} = state, _data, _bytes), do: {:ok, state}

  defp maybe_stream_write(%{write_strategy: :streaming_replay} = state, _data, _bytes),
    do: {:ok, state}

  defp maybe_stream_write(
         %{write_strategy: :streaming, position: pos, stream_offset: pos} = state,
         data,
         bytes
       ) do
    case Backend.call(state.backend, :write_chunk, [
           state.writer_handle,
           pos,
           data,
           state.backend_state
         ]) do
      {:ok, writer_handle} ->
        {:ok, %{state | writer_handle: writer_handle, stream_offset: pos + bytes}}

      {:error, reason} ->
        Logger.error(
          "Streaming write failed for #{inspect(state.path)} at offset #{pos}: #{inspect(reason)}"
        )

        cleanup_streaming_writer(state)
        {:error, reason}
    end
  end

  defp maybe_stream_write(%{write_strategy: :streaming} = state, _data, _bytes) do
    Logger.warning(
      "Switching #{inspect(state.path)} to temp-file replay mode after non-sequential write at offset #{state.position}"
    )

    cleanup_streaming_writer(state)

    {:ok,
     state
     |> Map.put(:write_strategy, :streaming_replay)
     |> Map.delete(:writer_handle)
     |> Map.delete(:stream_offset)}
  end

  defp finalize(%{mode: :read} = state), do: {:ok, state}

  defp finalize(%{mode: :write, error: reason} = state) do
    cleanup_unfinished(state)
    {{:error, reason}, state}
  end

  defp finalize(%{mode: :write, write_strategy: :legacy} = state) do
    result = finalize_legacy_write(state)
    {format_finalize_reply(result), close_tempfile(state)}
  end

  defp finalize(%{mode: :write, write_strategy: :streaming} = state) do
    result = finalize_streaming_write(state)
    {format_finalize_reply(result), close_tempfile(state)}
  end

  defp finalize(%{mode: :write, write_strategy: :streaming_replay} = state) do
    result = replay_tempfile_to_stream(state)
    {format_finalize_reply(result), close_tempfile(state)}
  end

  defp finalize_streaming_write(
         %{backend: backend, backend_state: backend_state, writer_handle: writer_handle} = state
       ) do
    case Backend.call(backend, :finish_write, [writer_handle, backend_state]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to finalize streaming write for #{inspect(state.path)}: #{inspect(reason)}"
        )

        cleanup_streaming_writer(state)
        {:error, reason}
    end
  end

  defp replay_tempfile_to_stream(%{
         backend: backend,
         backend_state: backend_state,
         path: path,
         temp_fd: temp_fd,
         size: size
       }) do
    with {:ok, writer_handle} <- Backend.call(backend, :begin_write, [path, backend_state]),
         {:ok, writer_handle} <-
           replay_tempfile_chunks(temp_fd, size, writer_handle, backend, backend_state, 0) do
      case Backend.call(backend, :finish_write, [writer_handle, backend_state]) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to replay temp file for #{inspect(path)}: #{inspect(reason)}")
          safe_abort_write(backend, writer_handle, backend_state)
          {:error, reason}
      end
    else
      {:stream_error, writer_handle, reason} ->
        Logger.error("Failed to replay temp file for #{inspect(path)}: #{inspect(reason)}")
        safe_abort_write(backend, writer_handle, backend_state)
        {:error, reason}

      {:error, reason} ->
        Logger.error("Failed to replay temp file for #{inspect(path)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp replay_tempfile_chunks(_temp_fd, size, writer_handle, _backend, _backend_state, offset)
       when offset >= size do
    {:ok, writer_handle}
  end

  defp replay_tempfile_chunks(temp_fd, size, writer_handle, backend, backend_state, offset) do
    bytes_to_read = min(@stream_chunk_size, size - offset)

    with {:ok, data} <- read_temp_chunk(temp_fd, offset, bytes_to_read),
         {:ok, writer_handle} <-
           Backend.call(backend, :write_chunk, [writer_handle, offset, data, backend_state]) do
      replay_tempfile_chunks(
        temp_fd,
        size,
        writer_handle,
        backend,
        backend_state,
        offset + byte_size(data)
      )
    else
      {:error, reason} ->
        {:stream_error, writer_handle, reason}
    end
  end

  defp finalize_legacy_write(
         %{backend: backend, backend_state: backend_state, path: path, temp_path: temp_path} =
           state
       ) do
    close_fd(state.temp_fd)

    with {:ok, content} <- File.read(temp_path),
         :ok <- Backend.call(backend, :write_file, [path, content, backend_state]) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to finalize legacy write for #{inspect(path)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp cleanup_unfinished(%{write_strategy: :streaming} = state) do
    cleanup_streaming_writer(state)
    close_tempfile(state)
    :ok
  end

  defp cleanup_unfinished(state) do
    close_tempfile(state)
    :ok
  end

  defp cleanup_streaming_writer(%{
         backend: backend,
         writer_handle: writer_handle,
         backend_state: backend_state
       }) do
    safe_abort_write(backend, writer_handle, backend_state)
  end

  defp safe_abort_write(backend, writer_handle, backend_state) do
    case Backend.call(backend, :abort_write, [writer_handle, backend_state]) do
      :ok ->
        :ok

      other ->
        Logger.warning("Failed to abort streaming write: #{inspect(other)}")
        :ok
    end
  end

  defp close_tempfile(state) do
    close_fd(Map.get(state, :temp_fd))

    case Map.get(state, :temp_path) do
      nil -> state
      temp_path -> remove_temp_file(temp_path)
    end

    state
    |> Map.delete(:temp_fd)
    |> Map.delete(:temp_path)
  end

  defp remove_temp_file(temp_path) do
    case File.rm(temp_path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to remove temp file #{inspect(temp_path)}: #{inspect(reason)}")
        :ok
    end
  end

  defp close_fd(nil), do: :ok

  defp close_fd(fd) do
    case :file.close(fd) do
      :ok -> :ok
      {:error, :terminated} -> :ok
      {:error, :badarg} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp open_temp_file do
    open_temp_file(System.tmp_dir!(), 10)
  end

  defp open_temp_file(_tmp_dir, 0), do: {:error, :eexist}

  defp open_temp_file(tmp_dir, attempts_remaining) do
    temp_path =
      Path.join(tmp_dir, "sftpd-#{random_temp_suffix()}.tmp")

    case :file.open(String.to_charlist(temp_path), [:binary, :raw, :read, :write, :exclusive]) do
      {:ok, fd} ->
        case :file.change_mode(String.to_charlist(temp_path), 0o600) do
          :ok ->
            {:ok, temp_path, fd}

          {:error, reason} ->
            close_fd(fd)
            File.rm(temp_path)
            {:error, reason}
        end

      {:error, :eexist} ->
        open_temp_file(tmp_dir, attempts_remaining - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp random_temp_suffix do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp persist_to_tempfile(temp_fd, position, data) do
    case :file.pwrite(temp_fd, position, data) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp streaming_write_supported?(backend) do
    Enum.all?(
      [
        {:begin_write, 2},
        {:write_chunk, 4},
        {:finish_write, 2},
        {:abort_write, 2}
      ],
      fn {function, arity} -> Backend.supports_callback?(backend, function, arity) end
    )
  end

  defp read_temp_chunk(temp_fd, offset, length) do
    case :file.pread(temp_fd, offset, length) do
      {:ok, data} -> {:ok, data}
      :eof -> {:error, :eof}
      {:error, reason} -> {:error, reason}
    end
  end

  defp position_from_offset(%{mode: :write}, {:eof, _offset}), do: {:error, :einval}
  defp position_from_offset(%{size: size}, {:eof, offset}), do: validate_position(size + offset)
  defp position_from_offset(_state, {:bof, offset}), do: validate_position(offset)

  defp position_from_offset(%{position: current_position}, {:cur, offset}),
    do: validate_position(current_position + offset)

  defp position_from_offset(_state, offset) when is_integer(offset), do: validate_position(offset)
  defp position_from_offset(_state, _offset), do: {:error, :einval}

  defp validate_position(position) when position >= 0, do: {:ok, position}
  defp validate_position(_position), do: {:error, :einval}

  defp extract_file_size({:file_info, size, _, _, _, _, _, _, _, _, _, _, _, _}), do: size

  defp format_finalize_reply(:ok), do: :ok
  defp format_finalize_reply({:error, reason}), do: {:error, reason}
end
