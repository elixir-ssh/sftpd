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

defmodule SftpdProfile.Backend do
  @behaviour Sftpd.Backend

  @keep_marker ".keep"

  @impl true
  def init(opts) do
    {:ok, agent} = Agent.start_link(fn -> Keyword.get(opts, :files, %{}) end)
    {:ok, %{agent: agent}}
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
    key = normalize_path(path)
    dir_prefix = normalize_prefix(path)

    cond do
      key == "" ->
        {:ok, Sftpd.Backend.directory_info()}

      true ->
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
    Agent.update(agent, &Map.put(&1, normalize_prefix(path) <> @keep_marker, file(0)))
    :ok
  end

  def del_dir(path, %{agent: agent}) do
    Agent.update(agent, &Map.delete(&1, normalize_prefix(path) <> @keep_marker))
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
    case file_size(path, state) do
      {:ok, size} when offset >= size -> :eof
      {:ok, size} -> {:ok, zeroes(min(len, size - offset))}
      error -> error
    end
  end

  @impl true
  def open_read(path, _session, state) do
    with {:ok, size} <- file_size(path, state) do
      {:ok, %{path: normalize_path(path), size: size}}
    end
  end

  @impl true
  def read_at(%{size: size}, offset, len, _state) do
    if offset >= size do
      :eof
    else
      {:ok, zeroes(min(len, size - offset))}
    end
  end

  def write_file(path, content, %{agent: agent}) do
    Agent.update(agent, &Map.put(&1, normalize_path(path), file(IO.iodata_length(content))))
    :ok
  end

  def begin_write(path, _state), do: {:ok, %{path: path, size: 0}}

  @impl true
  def open_write(path, _attrs, _session, _state), do: {:ok, %{path: path, size: 0}}

  def write_chunk(handle, offset, chunk, _state) do
    {:ok, %{handle | size: max(handle.size, offset + IO.iodata_length(chunk))}}
  end

  @impl true
  def write_at(handle, offset, data, state), do: write_chunk(handle, offset, data, state)

  @impl true
  def finish_write(%{path: path, size: size}, %{agent: agent}) do
    Agent.update(agent, &Map.put(&1, normalize_path(path), file(size)))
    :ok
  end

  @impl true
  def abort_write(_handle, _state), do: :ok

  @impl true
  def open_dir(path, _session, state) do
    with {:ok, names} <- list_dir(path, state) do
      {:ok, %{entries: Enum.map(names, &dir_entry(path, &1, state)), read?: false}}
    end
  end

  @impl true
  def read_dir(%{read?: true}, _state), do: :eof

  def read_dir(%{entries: entries, read?: false} = handle, _state),
    do: {:ok, entries, %{handle | read?: true}}

  @impl true
  def close_dir(_handle, _state), do: :ok

  @impl true
  def file_attrs(path, _session, state) do
    case file_info(path, state) do
      {:ok, info} -> {:ok, Sftpd.Backend.attrs_from_file_info(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def make_dir(path, _attrs, _session, state), do: make_dir(path, state)

  @impl true
  def del_dir(path, _session, state), do: del_dir(path, state)

  @impl true
  def delete(path, _session, state), do: delete(path, state)

  @impl true
  def rename(src, dst, _session, state), do: rename(src, dst, state)

  defp dir_entry(path, name, state) do
    child_path = child_path(path, name)

    attrs =
      case file_attrs(child_path, %{}, state) do
        {:ok, attrs} -> attrs
        {:error, _reason} -> %{type: :directory, size: 0, permissions: 0o040755}
      end

    %{name: to_string(name), attrs: attrs}
  end

  defp file_size(path, %{agent: agent}) do
    Agent.get(agent, fn files ->
      case Map.get(files, normalize_path(path)) do
        %{size: size} -> {:ok, size}
        nil -> {:error, :enoent}
      end
    end)
  end

  defp zeroes(size), do: :binary.copy(<<0>>, size)
  defp file(size), do: %{size: size, mtime: NaiveDateTime.utc_now()}
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
    case Code.ensure_loaded(:cprof) do
      {:module, :cprof} ->
        :ok

      {:error, _reason} ->
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
        backend: SftpdProfile.Backend,
        backend_opts: backend_opts,
        auth: {SftpdProfile.Auth, fingerprint: fingerprint},
        system_dir: system_dir,
        max_sessions: 8
      )

    Process.sleep(250)

    try do
      {micros, profile} =
        profile(fn ->
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

  defp profile(fun) do
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

  defp profile_modules do
    Application.load(:sftpd)

    Application.spec(:sftpd, :modules) ++ [SftpdProfile.Backend]
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

    IO.puts("profile=beam_call_count")
    IO.puts("")
    IO.puts("| function | calls |")
    IO.puts("| --- | ---: |")

    profile
    |> Enum.take(Keyword.fetch!(opts, :limit))
    |> Enum.each(fn {{mod, fun, arity}, count} ->
      IO.puts("| `#{inspect(mod)}.#{fun}/#{arity}` | #{count} |")
    end)
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
          limit: :integer
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
      limit: Keyword.get(opts, :limit, 40)
    ]
    |> validate_positive_args!([:size, :chunk, :requests, :limit])
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
