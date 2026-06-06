defmodule Sftpd do
  @moduledoc """
  A pluggable SFTP server with support for multiple storage backends.

  Sftpd provides a clean API for starting SFTP-only SSH daemons with
  configurable authentication and storage backends. The default transport wraps
  Erlang's `:ssh_sftpd` module; `transport: :elixir` opts into the
  experimental pure-Elixir SSH/SFTP transport.

  OTP 29 no longer enables the SFTP subsystem implicitly when starting an SSH
  daemon. `Sftpd.start_server/1` passes an explicit SFTP subsystem wrapper to
  `:ssh.daemon/2`, so callers do not need to configure the OTP daemon
  subsystem list themselves.

  OTP 29 also disables shell and exec services by default. `Sftpd` is
  SFTP-only and does not enable remote shell or exec channels.

  ## Quick Start

      # Start an SFTP server with the in-memory backend
      {:ok, ref} = Sftpd.start_server(
        port: 2222,
        backend: Sftpd.Backends.Memory,
        backend_opts: [],
        auth: {:passwords, [{"dev", "dev"}]},
        system_dir: "ssh_keys"
      )

  ## Backends

  Sftpd supports pluggable backends. Built-in backends:

  - `Sftpd.Backends.Memory` - in-memory storage for development and tests
  - `Sftpd.Backends.S3` - optional Amazon S3 or S3-compatible storage

  To create a custom backend, implement the `Sftpd.Backend` behaviour.
  See the HexDocs extras [Backends](backends.html) and
  [Custom Backends](custom_backends.html) for package-level guidance and
  examples. If you need persistent object storage, see the S3 backend docs for
  the optional dependency set required by that backend.

  ## Guides

  Package-level HexDocs extras:

  - [Getting Started](getting_started.html)
  - [Phoenix Setup](phoenix.html)
  - [Backends](backends.html)
  - [Custom Backends](custom_backends.html)
  - [Telemetry](telemetry.html)

  ## Options

  - `:port` - Port to listen on (default: 22)
  - `:backend` - Backend module implementing `Sftpd.Backend` (required)
  - `:backend_opts` - Options passed to `backend.init/1` for module backends (default: [])
    The built-in S3 backend accepts `:bucket`, `:prefix`, and `:aws_client`.
  - `:auth` - Authentication config, either `{:passwords, list}` or `{Module, opts}` (required)
  - `:system_dir` - Directory containing SSH host keys (required)
  - `:max_sessions` - Maximum concurrent sessions (default: 10)
  - `:max_channels` - Maximum SSH channels per pure-Elixir connection (default: 4)
  - `:max_handles` - Maximum SFTP handles per pure-Elixir channel (default: 256)
  - `:transport` - `:otp` for Erlang SSH/SFTP, or `:elixir` for the
    experimental pure-Elixir SSH/SFTP transport (default: `:otp`)
  ## Telemetry

  See `Sftpd.Telemetry` and the `Telemetry` extra in HexDocs for the event
  reference emitted by the server and file-handler layers.

  ## SSH Host Keys

  You need SSH host keys for the server. Generate them with:

      ssh-keygen -t rsa -f ssh_host_rsa_key -N ""
      ssh-keygen -t ecdsa -f ssh_host_ecdsa_key -N ""

  Then set `:system_dir` to the directory containing these keys.
  """

  @default_port 22
  @default_max_sessions 10
  @server_event_prefix [:sftpd, :server]

  @type server_ref :: :ssh.daemon_ref() | {:elixir, pid()}

  @doc """
  Start an SFTP server.

  ## Examples

      # Start with the in-memory backend
      {:ok, ref} = Sftpd.start_server(
        port: 2222,
        backend: Sftpd.Backends.Memory,
        backend_opts: [],
        auth: {:passwords, [{"admin", "secret"}]},
        system_dir: "ssh_keys"
      )

  ## Options

  See module documentation for full list of options.
  """
  @spec start_server(keyword()) :: {:ok, server_ref()} | {:error, term()}
  def start_server(opts) do
    cond do
      Keyword.has_key?(opts, :users) ->
        {:error, {:deprecated_option, :users}}

      Keyword.has_key?(opts, :open_timeout) ->
        {:error, {:deprecated_option, :open_timeout}}

      Keyword.has_key?(opts, :close_timeout) ->
        {:error, {:deprecated_option, :close_timeout}}

      not Keyword.has_key?(opts, :auth) ->
        {:error, {:missing_option, :auth}}

      true ->
        do_start_server(opts)
    end
  end

  defp do_start_server(opts) do
    port = Keyword.get(opts, :port, @default_port)
    backend = Keyword.fetch!(opts, :backend)
    backend_opts = Keyword.get(opts, :backend_opts, [])
    auth = Keyword.fetch!(opts, :auth)
    system_dir = Keyword.fetch!(opts, :system_dir)
    transport = Keyword.get(opts, :transport, :otp)
    max_sessions = Keyword.get(opts, :max_sessions, @default_max_sessions)
    max_channels = Keyword.get(opts, :max_channels)
    max_handles = Keyword.get(opts, :max_handles)

    metadata = %{
      port: port,
      max_sessions: max_sessions,
      backend: backend_name(backend),
      backend_kind: backend_kind(backend)
    }

    Sftpd.Telemetry.span(
      @server_event_prefix ++ [:start],
      metadata,
      fn ->
        with :ok <- Sftpd.Auth.Registry.ensure_started(),
             :ok <- validate_auth(auth),
             {:ok, {backend, backend_state}} <- init_backend(backend, backend_opts) do
          start_transport(transport,
            port: port,
            max_sessions: max_sessions,
            max_channels: max_channels,
            max_handles: max_handles,
            auth: auth,
            system_dir: system_dir,
            backend: backend,
            backend_state: backend_state
          )
        end
      end,
      &server_finalize/2
    )
  end

  defp start_transport(:otp, opts) do
    :ssh.daemon(Keyword.fetch!(opts, :port), [
      {:max_sessions, Keyword.fetch!(opts, :max_sessions)},
      {:pwdfun, Sftpd.Auth.Adapter.password_fun(Keyword.fetch!(opts, :auth))},
      {:key_cb, {Sftpd.Auth.KeyCallback, [auth: Keyword.fetch!(opts, :auth)]}},
      {:system_dir, opts |> Keyword.fetch!(:system_dir) |> to_charlist()},
      {:subsystems,
       [
         Sftpd.Subsystem.subsystem_spec(
           cwd: ~c"/",
           root: ~c"/",
           file_handler: {
             Sftpd.FileHandler,
             %{
               backend: Keyword.fetch!(opts, :backend),
               backend_state: Keyword.fetch!(opts, :backend_state)
             }
           }
         )
       ]}
    ])
  end

  defp start_transport(:elixir, opts) do
    case Sftpd.SSH.Server.start_link(opts) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, {:elixir, pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_transport(transport, _opts), do: {:error, {:invalid_option, {:transport, transport}}}

  @doc """
  Return a child spec for supervising an SFTP server.

  This lets applications start the server directly from a supervision tree:

      children = [
        {Sftpd,
         port: 2222,
         backend: Sftpd.Backends.Memory,
         backend_opts: [],
         auth: {:passwords, [{"dev", "dev"}]},
         system_dir: "ssh_keys"}
      ]
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {Sftpd.Server, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  defp init_backend(module, opts) when is_atom(module) do
    case module.init(opts) do
      {:ok, state} -> {:ok, {module, state}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp init_backend(backend, _opts), do: {:error, {:invalid_option, {:backend, backend}}}

  defp validate_auth(auth) do
    if Sftpd.Auth.Adapter.valid_config?(auth) do
      :ok
    else
      {:error, {:invalid_option, :auth}}
    end
  end

  @doc """
  Stop an SFTP server.

  ## Examples

      {:ok, ref} = Sftpd.start_server(opts)
      :ok = Sftpd.stop_server(ref)
  """
  @spec stop_server(server_ref()) :: :ok | {:error, term()}
  def stop_server(ref) do
    Sftpd.Telemetry.span(
      @server_event_prefix ++ [:stop],
      %{server_ref: ref},
      fn ->
        stop_ref(ref)
      end,
      &stop_finalize/2
    )
  end

  defp stop_ref({:elixir, pid}) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, :shutdown -> :ok
    :exit, {:shutdown, _reason} -> :ok
  end

  defp stop_ref(ref), do: :ssh.stop_daemon(ref)

  defp server_finalize({:ok, ref}, duration),
    do: {%{duration: duration}, %{result: :ok, server_ref: ref}}

  defp server_finalize({:error, reason}, duration),
    do: {%{duration: duration}, %{result: :error, reason: reason}}

  defp stop_finalize(:ok, duration), do: {%{duration: duration}, %{result: :ok}}

  defp stop_finalize({:error, reason}, duration),
    do: {%{duration: duration}, %{result: :error, reason: reason}}

  defp backend_kind(module) when is_atom(module), do: :module
  defp backend_kind(_backend), do: :unknown

  defp backend_name(module) when is_atom(module), do: module
  defp backend_name(backend), do: inspect(backend)
end
