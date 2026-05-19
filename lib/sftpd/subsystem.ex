defmodule Sftpd.Subsystem do
  @moduledoc false

  @behaviour :ssh_daemon_channel

  @connection_manager_key {__MODULE__, :connection_manager}

  @spec subsystem_spec(keyword()) :: {charlist(), {module(), keyword()}}
  def subsystem_spec(options), do: {~c"sftp", {__MODULE__, options}}

  @spec connection_manager() :: pid() | nil
  def connection_manager, do: Process.get(@connection_manager_key)

  @impl true
  def init(options) do
    :ssh_sftpd.init(options)
  end

  @impl true
  def handle_ssh_msg(message, state) do
    :ssh_sftpd.handle_ssh_msg(message, state)
  end

  @impl true
  def handle_msg({:ssh_channel_up, _channel_id, connection_manager} = message, state) do
    Process.put(@connection_manager_key, connection_manager)
    Sftpd.Auth.Registry.track(connection_manager)
    :ssh_sftpd.handle_msg(message, state)
  end

  def handle_msg(message, state) do
    :ssh_sftpd.handle_msg(message, state)
  end

  @impl true
  def terminate(reason, state) do
    # Auth sessions are keyed by the SSH connection manager, not by one SFTP
    # channel. The registry monitors that connection manager and removes the
    # session when the SSH connection exits, so another channel on the same
    # authenticated connection can still reuse the session context.
    :ssh_sftpd.terminate(reason, state)
  end
end
