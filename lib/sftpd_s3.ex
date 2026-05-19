defmodule SftpdS3 do
  @moduledoc """
  Legacy module for backwards compatibility.

  This module is deprecated. Use `Sftpd` instead.

  ## Migration

  Replace:

      SftpdS3.start_server(port, system_dir: "path/to/ssh_keys", bucket: "your-bucket")

  With:

      Sftpd.start_server(
        port: port,
        backend: Sftpd.Backends.S3,
        backend_opts: [bucket: "your-bucket", prefix: "tenant-a/"],
        users: [{"user", "password"}],
        system_dir: "path/to/ssh_keys"
      )
  """

  @doc """
  Start a test SFTP server with default S3 settings.

  Deprecated: Use `Sftpd.start_server/1` instead.

  ## Options

  - `:system_dir` - Directory containing SSH host keys (required)
  - `:username` - SFTP username (default: from config or "user")
  - `:password` - SFTP password (default: from config or "password")
  - `:bucket` - S3 bucket name (default: from config)
  - `:prefix` - Optional S3 key prefix
  - `:aws_client` - Optional ExAws-compatible client module
  """
  @deprecated "Use Sftpd.start_server/1 instead"
  @spec start_server(non_neg_integer(), keyword()) :: {:ok, :ssh.daemon_ref()} | {:error, term()}
  def start_server(port \\ 22, opts \\ []) do
    system_dir = Keyword.fetch!(opts, :system_dir)
    bucket = Keyword.get(opts, :bucket, Application.get_env(:sftpd, :bucket))
    prefix = Keyword.get(opts, :prefix, "")
    aws_client = Keyword.get(opts, :aws_client, ExAws)
    username = Keyword.get(opts, :username, Application.get_env(:sftpd, :username, "user"))
    password = Keyword.get(opts, :password, Application.get_env(:sftpd, :password, "password"))

    Sftpd.start_server(
      port: port,
      backend: Sftpd.Backends.S3,
      backend_opts: [bucket: bucket, prefix: prefix, aws_client: aws_client],
      users: [{username, password}],
      system_dir: system_dir
    )
  end

  @doc """
  Stop an SFTP server.

  Deprecated: Use `Sftpd.stop_server/1` instead.
  """
  @deprecated "Use Sftpd.stop_server/1 instead"
  @spec stop_server(:ssh.daemon_ref()) :: :ok | {:error, term()}
  def stop_server(ref) do
    Sftpd.stop_server(ref)
  end
end
