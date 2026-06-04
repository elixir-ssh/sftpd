defmodule SftpdPerfBench.Auth do
  @behaviour Sftpd.Auth

  def authenticate_password("user", "password", _peer, _opts), do: {:ok, %{}}
  def authenticate_password(_username, _password, _peer, _opts), do: :error

  def authorize_public_key("key-user", public_key, opts) do
    if Sftpd.Auth.fingerprint(public_key) == Keyword.fetch!(opts, :fingerprint) do
      {:ok, %{}}
    else
      :error
    end
  end

  def authorize_public_key(_username, _public_key, _opts), do: :error
end

defmodule SftpdPerfBench do
  @openssh_sftp_block_size 256 * 1024 - 64

  @client_opts [
    silently_accept_hosts: true,
    user: ~c"user",
    password: ~c"password",
    user_interaction: false,
    preferred_algorithms: [
      cipher: [:"aes256-gcm@openssh.com"]
    ]
  ]

  def main(argv) do
    opts = parse_args(argv)
    size = Keyword.fetch!(opts, :size)
    chunk = Keyword.fetch!(opts, :chunk)
    requests = Keyword.fetch!(opts, :requests)
    port = Keyword.fetch!(opts, :port)
    delay_ms = Keyword.fetch!(opts, :delay_ms)
    full? = Keyword.fetch!(opts, :full?)

    tmp = Path.join(System.tmp_dir!(), "sftpd_perf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    local_file = Path.join(tmp, "payload.bin")
    openssh_key = Path.join(tmp, "id_ed25519")
    write_sparse_payload(local_file, size)
    make_client_key!(openssh_key)
    fingerprint = public_key_fingerprint!(openssh_key <> ".pub")

    system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

    {:ok, ref} =
      Sftpd.start_server(
        port: port,
        backend: SftpdPerfBench.DelayedBackend,
        backend_opts: [delay_ms: delay_ms],
        auth: {SftpdPerfBench.Auth, fingerprint: fingerprint},
        system_dir: system_dir,
        max_sessions: 8
      )

    Process.sleep(250)

    try do
      IO.puts(
        "size=#{size} chunk=#{chunk} requests=#{requests} port=#{port} delay_ms=#{delay_ms} cipher=aes256-gcm@openssh.com"
      )

      if full? do
        run_transfer("otp write_file", size, fn ->
          with_client(port, fn channel ->
            data = File.read!(local_file)
            :ok = :ssh_sftp.write_file(channel, ~c"/otp-write-file.bin", data)
          end)
        end)

        run_transfer("otp awrite pipeline", size, fn ->
          with_client(port, fn channel ->
            async_upload(channel, ~c"/otp-awrite.bin", local_file, chunk, requests)
          end)
        end)
      end

      run_transfer("openssh sftp put", size, fn ->
        openssh_put!(port, openssh_key, local_file, tmp, chunk, requests)
      end)

      if full? do
        run_transfer("otp read_file", size, fn ->
          with_client(port, fn channel ->
            {:ok, _data} = :ssh_sftp.read_file(channel, ~c"/openssh-put.bin")
          end)
        end)

        run_transfer("otp aread pipeline", size, fn ->
          with_client(port, fn channel ->
            async_download(channel, ~c"/openssh-put.bin", chunk, requests)
          end)
        end)
      end

      run_transfer("openssh sftp get", size, fn ->
        openssh_get!(port, openssh_key, tmp, chunk, requests)
      end)
    after
      Sftpd.stop_server(ref)
      File.rm_rf(tmp)
    end
  end

  defp parse_args(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          size: :integer,
          chunk: :integer,
          requests: :integer,
          port: :integer,
          delay_ms: :integer,
          full: :boolean
        ]
      )

    [
      size: Keyword.get(opts, :size, 64 * 1024 * 1024),
      chunk: Keyword.get(opts, :chunk, @openssh_sftp_block_size),
      requests: Keyword.get(opts, :requests, 64),
      port: Keyword.get(opts, :port, 29_222),
      delay_ms: Keyword.get(opts, :delay_ms, 0),
      full?: Keyword.get(opts, :full, false)
    ]
  end

  defp write_sparse_payload(path, 0), do: File.write!(path, <<>>)

  defp write_sparse_payload(path, size) do
    {:ok, fd} = :file.open(String.to_charlist(path), [:write, :binary])
    {:ok, _pos} = :file.position(fd, {:bof, size - 1})
    :ok = :file.write(fd, <<0>>)
    :ok = :file.close(fd)
  end

  defp make_client_key!(path) do
    {_, 0} =
      System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path],
        stderr_to_stdout: true
      )
  end

  defp public_key_fingerprint!(pub_path) do
    {:ok, public_key} = pub_path |> File.read!() |> Sftpd.Auth.decode_authorized_key()
    Sftpd.Auth.fingerprint(public_key)
  end

  defp with_client(port, fun) do
    {:ok, conn} = :ssh.connect(~c"127.0.0.1", port, @client_opts)
    {:ok, channel} = :ssh_sftp.start_channel(conn)

    try do
      fun.(channel)
    after
      :ssh_sftp.stop_channel(channel)
      :ssh.close(conn)
    end
  end

  defp async_upload(channel, remote_path, local_file, chunk_size, max_requests) do
    {:ok, handle} = :ssh_sftp.open(channel, remote_path, [:write, :binary])

    try do
      File.open!(local_file, [:read, :binary], fn file ->
        pump_async_writes(channel, handle, file, chunk_size, max_requests, 0, :queue.new())
      end)
    after
      :ok = :ssh_sftp.close(channel, handle)
    end
  end

  defp async_download(channel, remote_path, chunk_size, max_requests) do
    {:ok, info} = :ssh_sftp.read_file_info(channel, remote_path)
    size = elem(info, 1)
    {:ok, handle} = :ssh_sftp.open(channel, remote_path, [:read, :binary])

    try do
      async_read_loop(channel, handle, chunk_size, max_requests, 0, :queue.new(), 0, size)
    after
      :ok = :ssh_sftp.close(channel, handle)
    end
  end

  defp async_read_loop(channel, handle, chunk_size, max_requests, in_flight, queue, bytes, size) do
    cond do
      bytes + in_flight * chunk_size < size and in_flight < max_requests ->
        len = min(chunk_size, size - bytes - in_flight * chunk_size)

        case :ssh_sftp.aread(channel, handle, len) do
          {:async, req_id} ->
            async_read_loop(
              channel,
              handle,
              chunk_size,
              max_requests,
              in_flight + 1,
              :queue.in(req_id, queue),
              bytes,
              size
            )

          {:error, reason} ->
            raise "async read failed: #{inspect(reason)}"
        end

      in_flight == 0 ->
        bytes

      true ->
        {req_id, queue} = out!(queue)

        case await_async_read_reply(req_id) do
          {:ok, data} ->
            async_read_loop(
              channel,
              handle,
              chunk_size,
              max_requests,
              in_flight - 1,
              queue,
              bytes + byte_size(data),
              size
            )

          :eof ->
            drain_async_reads(in_flight - 1, queue, bytes)
        end
    end
  end

  defp drain_async_reads(0, _queue, bytes), do: bytes

  defp drain_async_reads(in_flight, queue, bytes) do
    {req_id, queue} = out!(queue)

    case await_async_read_reply(req_id) do
      {:ok, data} -> drain_async_reads(in_flight - 1, queue, bytes + byte_size(data))
      :eof -> drain_async_reads(in_flight - 1, queue, bytes)
    end
  end

  defp pump_async_writes(channel, handle, file, chunk_size, max_requests, in_flight, queue) do
    cond do
      in_flight < max_requests ->
        case IO.binread(file, chunk_size) do
          :eof ->
            drain_async_writes(in_flight, queue)

          data ->
            {:async, req_id} = :ssh_sftp.awrite(channel, handle, data)

            pump_async_writes(
              channel,
              handle,
              file,
              chunk_size,
              max_requests,
              in_flight + 1,
              :queue.in(req_id, queue)
            )
        end

      true ->
        {req_id, queue} = out!(queue)
        await_async_reply(req_id)
        pump_async_writes(channel, handle, file, chunk_size, max_requests, in_flight - 1, queue)
    end
  end

  defp drain_async_writes(0, _queue), do: :ok

  defp drain_async_writes(in_flight, queue) do
    {req_id, queue} = out!(queue)
    await_async_reply(req_id)
    drain_async_writes(in_flight - 1, queue)
  end

  defp out!(queue) do
    {{:value, req_id}, queue} = :queue.out(queue)
    {req_id, queue}
  end

  defp await_async_reply(req_id) do
    receive do
      {:async_reply, ^req_id, :ok} ->
        :ok

      {:async_reply, ^req_id, {:error, reason}} ->
        raise "async write failed: #{inspect(reason)}"
    after
      30_000 ->
        raise "timed out waiting for async write #{inspect(req_id)}"
    end
  end

  defp await_async_read_reply(req_id) do
    receive do
      {:async_reply, ^req_id, {:ok, data}} ->
        {:ok, data}

      {:async_reply, ^req_id, :eof} ->
        :eof

      {:async_reply, ^req_id, {:error, reason}} ->
        raise "async read failed: #{inspect(reason)}"
    after
      30_000 ->
        raise "timed out waiting for async read #{inspect(req_id)}"
    end
  end

  defp openssh_put!(port, key_path, local_file, tmp, chunk, requests) do
    batch = Path.join(tmp, "batch.txt")
    File.write!(batch, "put #{local_file} /openssh-put.bin\n")

    args = [
      "-q",
      "-B",
      Integer.to_string(chunk),
      "-R",
      Integer.to_string(requests),
      "-b",
      batch,
      "-P",
      Integer.to_string(port),
      "-c",
      "aes256-gcm@openssh.com",
      "-i",
      key_path,
      "-o",
      "BatchMode=yes",
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "key-user@127.0.0.1"
    ]

    case System.cmd("sftp", args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, status} ->
        raise "sftp exited #{status}: #{out}"
    end
  end

  defp openssh_get!(port, key_path, tmp, chunk, requests) do
    batch = Path.join(tmp, "get-batch.txt")
    out = "/dev/null"
    File.write!(batch, "get /openssh-put.bin #{out}\n")

    args = [
      "-q",
      "-B",
      Integer.to_string(chunk),
      "-R",
      Integer.to_string(requests),
      "-b",
      batch,
      "-P",
      Integer.to_string(port),
      "-c",
      "aes256-gcm@openssh.com",
      "-i",
      key_path,
      "-o",
      "BatchMode=yes",
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "key-user@127.0.0.1"
    ]

    case System.cmd("sftp", args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, status} ->
        raise "sftp exited #{status}: #{out}"
    end
  end

  defp run_transfer(name, bytes, fun) do
    {micros, result} = :timer.tc(fun)
    seconds = micros / 1_000_000
    mib = bytes / 1024 / 1024
    throughput = mib / seconds

    IO.puts("#{name}: #{Float.round(seconds, 3)}s #{Float.round(throughput, 1)} MiB/s")

    result
  end
end

defmodule SftpdPerfBench.DelayedBackend do
  @behaviour Sftpd.Backend

  @keep_marker ".keep"

  def init(opts) do
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    {:ok, %{agent: agent, delay_ms: Keyword.get(opts, :delay_ms, 0)}}
  end

  def list_dir(path, %{agent: agent}) do
    prefix = normalize_prefix(path)

    entries =
      Agent.get(agent, fn files ->
        files
        |> Map.keys()
        |> Enum.reduce(MapSet.new(), fn key, entries ->
          if String.starts_with?(key, prefix) do
            case key |> String.replace_prefix(prefix, "") |> first_path_segment() do
              "" -> entries
              @keep_marker -> entries
              entry -> MapSet.put(entries, entry)
            end
          else
            entries
          end
        end)
        |> MapSet.to_list()
        |> Enum.sort()
        |> Enum.map(&to_charlist/1)
      end)

    {:ok, [~c".", ~c".." | entries]}
  end

  def file_info(path, %{agent: agent}) do
    if root_path?(path) do
      {:ok, Sftpd.Backend.directory_info()}
    else
      key = normalize_path(path)
      dir_prefix = normalize_prefix(path)

      Agent.get(agent, fn files ->
        case Map.get(files, key) do
          %{size: size, mtime: mtime} ->
            {:ok, Sftpd.Backend.file_info(size, NaiveDateTime.to_erl(mtime), :read_write)}

          nil ->
            if Enum.any?(Map.keys(files), &String.starts_with?(&1, dir_prefix)) do
              {:ok, Sftpd.Backend.directory_info()}
            else
              {:error, :enoent}
            end
        end
      end)
    end
  end

  def make_dir(path, %{agent: agent}) do
    key = normalize_prefix(path) <> @keep_marker
    Agent.update(agent, &Map.put(&1, key, %{size: 0, mtime: NaiveDateTime.utc_now()}))
    :ok
  end

  def del_dir(path, %{agent: agent}) do
    key = normalize_prefix(path) <> @keep_marker
    Agent.update(agent, &Map.delete(&1, key))
    :ok
  end

  def delete(path, %{agent: agent}) do
    Agent.update(agent, &Map.delete(&1, normalize_path(path)))
    :ok
  end

  def rename(src, dst, %{agent: agent}) do
    Agent.update(agent, fn files ->
      case Map.pop(files, normalize_path(src)) do
        {nil, files} -> files
        {data, files} -> Map.put(files, normalize_path(dst), data)
      end
    end)

    :ok
  end

  def read_file(path, state) do
    case file_size(path, state) do
      {:ok, size} when size <= 128 * 1024 * 1024 -> {:ok, zeroes(size)}
      {:ok, _size} -> {:error, :enotsup}
      error -> error
    end
  end

  def read_file_range(path, offset, len, state) do
    delay(state)

    case file_size(path, state) do
      {:ok, size} when offset >= size ->
        :eof

      {:ok, size} ->
        bytes = min(len, size - offset)
        {:ok, zeroes(bytes)}

      error ->
        error
    end
  end

  def open_read(path, _session, state) do
    with {:ok, size} <- file_size(path, state) do
      {:ok, %{path: normalize_path(path), size: size}}
    end
  end

  def read_at(%{size: size}, offset, len, state) do
    delay(state)

    cond do
      offset >= size ->
        :eof

      true ->
        {:ok, zeroes(min(len, size - offset))}
    end
  end

  def write_file(path, content, %{agent: agent}) do
    Agent.update(
      agent,
      &Map.put(&1, normalize_path(path), %{
        size: IO.iodata_length(content),
        mtime: NaiveDateTime.utc_now()
      })
    )

    :ok
  end

  def begin_write(path, _state), do: {:ok, %{path: path, size: 0}}

  def open_write(path, _attrs, _session, _state), do: {:ok, %{path: path, size: 0}}

  def write_chunk(handle, offset, chunk, state) do
    delay(state)
    size = max(handle.size, offset + IO.iodata_length(chunk))
    {:ok, %{handle | size: size}}
  end

  def write_at(handle, offset, data, state), do: write_chunk(handle, offset, data, state)

  def finish_write(%{path: path, size: size}, %{agent: agent}) do
    Agent.update(
      agent,
      &Map.put(&1, normalize_path(path), %{size: size, mtime: NaiveDateTime.utc_now()})
    )

    :ok
  end

  def abort_write(_handle, _state), do: :ok

  def open_dir(path, _session, state) do
    with {:ok, names} <- list_dir(path, state) do
      entries =
        Enum.map(names, fn name ->
          child_path = child_path(path, name)

          attrs =
            case file_attrs(child_path, %{}, state) do
              {:ok, attrs} -> attrs
              {:error, _reason} -> %{type: :directory, size: 0, permissions: 0o040755}
            end

          %{name: to_string(name), attrs: attrs}
        end)

      {:ok, %{entries: entries, read?: false}}
    end
  end

  def read_dir(%{read?: true}, _state), do: :eof

  def read_dir(%{entries: entries, read?: false} = handle, _state),
    do: {:ok, entries, %{handle | read?: true}}

  def close_dir(_handle, _state), do: :ok

  def file_attrs(path, _session, state) do
    case file_info(path, state) do
      {:ok, info} -> {:ok, Sftpd.Backend.attrs_from_file_info(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  def make_dir(path, _attrs, _session, state), do: make_dir(path, state)
  def del_dir(path, _session, state), do: del_dir(path, state)
  def delete(path, _session, state), do: delete(path, state)
  def rename(src, dst, _session, state), do: rename(src, dst, state)

  defp file_size(path, %{agent: agent}) do
    Agent.get(agent, fn files ->
      case Map.get(files, normalize_path(path)) do
        %{size: size} -> {:ok, size}
        nil -> {:error, :enoent}
      end
    end)
  end

  defp zeroes(size), do: :binary.copy(<<0>>, size)

  defp child_path(_path, name) when name in [~c".", ~c".."], do: to_string(name)

  defp child_path(path, name) do
    path = normalize_path(path)
    name = to_string(name)

    case path do
      "" -> name
      "/" -> name
      _ -> path <> "/" <> name
    end
  end

  defp delay(%{delay_ms: delay_ms}) when delay_ms > 0, do: Process.sleep(delay_ms)
  defp delay(_state), do: :ok

  defp root_path?(path), do: normalize_path(path) == ""

  defp normalize_path(path) do
    path
    |> to_string()
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
  end

  defp normalize_prefix(path) do
    case normalize_path(path) do
      "" -> ""
      key -> key <> "/"
    end
  end

  defp first_path_segment(path) do
    path
    |> String.split("/", parts: 2)
    |> hd()
  end
end

SftpdPerfBench.main(System.argv())
