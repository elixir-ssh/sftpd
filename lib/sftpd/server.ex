defmodule Sftpd.Server do
  @moduledoc false

  use GenServer

  @dialyzer {:no_opaque, monitor_daemon: 1}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Sftpd.start_server(opts) do
      {:ok, ref} -> {:ok, %{ref: ref, monitor_ref: monitor_daemon(ref), daemon_down?: false}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, ref, reason},
        %{monitor_ref: monitor_ref, ref: ref} = state
      ) do
    {:stop, daemon_down_reason(reason), %{state | daemon_down?: true}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{daemon_down?: true}), do: :ok

  def terminate(_reason, %{ref: ref}) do
    Sftpd.stop_server(ref)
    :ok
  end

  defp daemon_down_reason(:normal), do: :normal
  defp daemon_down_reason(:shutdown), do: :shutdown
  defp daemon_down_reason(reason), do: {:ssh_daemon_down, reason}

  defp monitor_daemon(ref), do: Process.monitor(ref)
end
