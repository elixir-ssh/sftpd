defmodule SftpdProfile.Auth do
  @behaviour Sftpd.Auth

  @impl true
  def authenticate_password("user", "password", _peer, _opts), do: {:ok, %{}}

  def authenticate_password(_username, _password, _peer, _opts), do: :error

  @impl true
  def authorize_public_key("key-user", public_key, opts) do
    if Sftpd.Auth.fingerprint(public_key) == Keyword.fetch!(opts, :fingerprint) do
      {:ok, %{}}
    else
      :error
    end
  end

  def authorize_public_key(_username, _public_key, _opts), do: :error
end

defmodule SftpdProfile do
  @openssh_sftp_block_size 256 * 1024 - 64

  def main(argv) do
    Logger.configure(level: logger_level())
    ensure_tools_code_path!()

    opts = parse_args(argv)
    tmp = Path.join(System.tmp_dir!(), "sftpd_profile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    key_path = Path.join(tmp, "id_ed25519")
    make_client_key!(key_path)
    fingerprint = public_key_fingerprint!(key_path <> ".pub")
    system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

    try do
      run(opts, tmp, key_path, fingerprint, system_dir)
    after
      File.rm_rf(tmp)
    end
  end

  defp logger_level do
    if System.get_env("SFTPD_PROFILE_VERBOSE") == "1", do: :debug, else: :info
  end

  defp ensure_tools_code_path! do
    if Code.ensure_loaded?(:cprof) and Code.ensure_loaded?(:eprof) do
      :ok
    else
      tools_ebin =
        :code.root_dir()
        |> to_string()
        |> Path.join("lib/tools-*/ebin")
        |> Path.wildcard()
        |> List.first()

      if is_nil(tools_ebin) do
        raise "could not find OTP tools ebin under #{:code.root_dir()}"
      end

      true = :code.add_pathz(String.to_charlist(tools_ebin))
      {:module, :cprof} = Code.ensure_loaded(:cprof)
      {:module, :eprof} = Code.ensure_loaded(:eprof)
      :ok
    end
  end

  defp run(opts, tmp, key_path, fingerprint, system_dir) do
    direction = Keyword.fetch!(opts, :direction)
    size = Keyword.fetch!(opts, :size)
    port = Keyword.fetch!(opts, :port)

    local_file = Path.join(tmp, "payload.bin")
    if direction == :upload, do: write_sparse_payload(local_file, size)

    backend_opts =
      case direction do
        :download ->
          [files: %{"openssh-get.bin" => %{size: size, mtime: NaiveDateTime.utc_now()}}]

        :upload ->
          [files: %{}]
      end

    {:ok, ref} =
      Sftpd.start_server(
        transport: :elixir,
        port: port,
        backend: Sftpd.Backends.Benchmark,
        backend_opts: backend_opts,
        auth: {SftpdProfile.Auth, fingerprint: fingerprint},
        system_dir: system_dir,
        max_sessions: 8
      )

    Process.sleep(250)

    try do
      {micros, profile} =
        profile(opts, fn ->
          case direction do
            :download -> openssh_get!(port, key_path, tmp, opts)
            :upload -> openssh_put!(port, key_path, local_file, tmp, opts)
          end
        end)

      print_report(opts, micros, profile)
    after
      Sftpd.stop_server(ref)
    end
  end

  defp profile(opts, fun) do
    case Keyword.fetch!(opts, :profiler) do
      :cprof -> profile_cprof(fun)
      :eprof -> profile_eprof(fun)
    end
  end

  defp profile_cprof(fun) do
    modules = profile_modules()
    stop_cprof(modules)
    start_cprof(modules)

    try do
      {micros, result} =
        :timer.tc(fn ->
          fun.()
        end)

      :cprof.pause()
      profile = read_cprof(modules)
      :ok = result

      {micros, profile}
    after
      stop_cprof(modules)
    end
  end

  defp profile_eprof(fun) do
    register_profile_owner!()
    :eprof.start()

    task =
      Task.async(fn ->
        {micros, result} = :timer.tc(fun)
        {micros, result}
      end)

    try do
      connection = await_profile_connection(task)
      :eprof.start_profiling([connection])
      {micros, :ok} = Task.await(task, :infinity)
      :eprof.stop_profiling()
      {micros, :eprof}
    after
      stop_eprof()
      unregister_profile_owner()
    end
  end

  defp register_profile_owner! do
    if Process.whereis(:sftpd_profile_owner) do
      raise "process already registered as :sftpd_profile_owner"
    end

    Process.register(self(), :sftpd_profile_owner)
  end

  defp unregister_profile_owner do
    if Process.whereis(:sftpd_profile_owner) == self() do
      Process.unregister(:sftpd_profile_owner)
    end
  end

  defp await_profile_connection(task) do
    receive do
      {:sftpd_connection, pid} ->
        pid
    after
      5_000 ->
        Task.shutdown(task, :brutal_kill)
        raise "timed out waiting for profiled SFTP connection"
    end
  end

  defp stop_eprof do
    :eprof.stop_profiling()
  catch
    :exit, _ -> :ok
  after
    :eprof.analyze(:total)
    :eprof.stop()
  end

  defp profile_modules do
    Application.load(:sftpd)

    Application.spec(:sftpd, :modules)
  end

  defp start_cprof(modules) do
    Enum.each(modules, &:cprof.start/1)
  end

  defp stop_cprof(modules) do
    Enum.each(modules, &:cprof.stop/1)
  end

  defp read_cprof(modules) do
    modules
    |> Enum.flat_map(fn mod ->
      {_mod, _total, functions} = :cprof.analyse(mod, 1)
      functions
    end)
    |> Enum.filter(fn {_counter, count} -> count > 0 end)
    |> Enum.sort_by(fn {_counter, count} -> count end, :desc)
  end

  defp print_report(opts, micros, profile) do
    size = Keyword.fetch!(opts, :size)
    direction = Keyword.fetch!(opts, :direction)
    seconds = micros / 1_000_000
    mib = size / 1024 / 1024
    throughput = mib / seconds

    IO.puts("direction=#{direction}")
    IO.puts("size_bytes=#{size}")
    IO.puts("elapsed_seconds=#{Float.round(seconds, 3)}")
    IO.puts("throughput_mib_s=#{Float.round(throughput, 1)}")
    IO.puts("chunk=#{Keyword.fetch!(opts, :chunk)}")
    IO.puts("requests=#{Keyword.fetch!(opts, :requests)}")
    IO.puts("cipher=aes256-gcm@openssh.com")
    IO.puts("")

    print_profile(opts, profile)
  end

  defp print_profile(opts, profile) do
    case Keyword.fetch!(opts, :profiler) do
      :cprof ->
        IO.puts("profile=beam_call_count")
        IO.puts("")
        IO.puts("| function | calls |")
        IO.puts("| --- | ---: |")

        profile
        |> Enum.take(Keyword.fetch!(opts, :limit))
        |> Enum.each(fn {{mod, fun, arity}, count} ->
          IO.puts("| `#{inspect(mod)}.#{fun}/#{arity}` | #{count} |")
        end)

      :eprof ->
        IO.puts("profile=beam_time")
        IO.puts("profile_output=above")
    end
  end

  defp parse_args(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          size: :integer,
          direction: :string,
          chunk: :integer,
          requests: :integer,
          port: :integer,
          limit: :integer,
          profiler: :string
        ]
      )

    if invalid != [], do: raise(ArgumentError, "invalid args: #{inspect(invalid)}")

    direction =
      case Keyword.get(opts, :direction, "download") do
        "download" ->
          :download

        "upload" ->
          :upload

        other ->
          raise ArgumentError, "direction must be download or upload, got #{inspect(other)}"
      end

    [
      size: Keyword.get(opts, :size, 64 * 1024 * 1024),
      direction: direction,
      chunk: Keyword.get(opts, :chunk, @openssh_sftp_block_size),
      requests: Keyword.get(opts, :requests, 64),
      port: Keyword.get(opts, :port, 29_222),
      limit: Keyword.get(opts, :limit, 40),
      profiler: parse_profiler(Keyword.get(opts, :profiler, "cprof"))
    ]
    |> validate_positive_args!([:size, :chunk, :requests, :limit])
  end

  defp parse_profiler("cprof"), do: :cprof
  defp parse_profiler("eprof"), do: :eprof

  defp parse_profiler(other) do
    raise ArgumentError, "profiler must be cprof or eprof, got #{inspect(other)}"
  end

  defp validate_positive_args!(opts, keys) do
    Enum.each(keys, fn key ->
      value = Keyword.fetch!(opts, key)
      if value <= 0, do: raise(ArgumentError, "#{key} must be > 0")
    end)

    opts
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

  defp openssh_put!(port, key_path, local_file, tmp, opts) do
    batch = Path.join(tmp, "put-batch.txt")
    File.write!(batch, "put #{local_file} /openssh-put.bin\n")
    run_sftp!(port, key_path, batch, opts)
  end

  defp openssh_get!(port, key_path, tmp, opts) do
    batch = Path.join(tmp, "get-batch.txt")
    File.write!(batch, "get /openssh-get.bin /dev/null\n")
    run_sftp!(port, key_path, batch, opts)
  end

  defp run_sftp!(port, key_path, batch, opts) do
    args =
      verbose_args() ++
        [
          "-B",
          opts |> Keyword.fetch!(:chunk) |> Integer.to_string(),
          "-R",
          opts |> Keyword.fetch!(:requests) |> Integer.to_string(),
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
          "IdentitiesOnly=yes",
          "-o",
          "StrictHostKeyChecking=no",
          "-o",
          "UserKnownHostsFile=/dev/null",
          "key-user@127.0.0.1"
        ]

    case System.cmd("sftp", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> raise "sftp exited #{status}: #{out}"
    end
  end

  defp verbose_args do
    if System.get_env("SFTPD_PROFILE_VERBOSE") == "1", do: ["-vvv"], else: ["-q"]
  end
end

SftpdProfile.main(System.argv())
