defmodule Sftpd.Auth.Registry do
  @moduledoc false

  use GenServer

  @table __MODULE__
  @server __MODULE__

  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    case Process.whereis(@server) do
      nil ->
        case GenServer.start(__MODULE__, [], name: @server) do
          {:ok, _pid} -> :ok
          :ignore -> {:error, :ignore}
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  @spec track(pid() | nil) :: :ok
  def track(connection_manager) when is_pid(connection_manager) do
    ensure_started()
    GenServer.call(@server, {:track, connection_manager})
  end

  def track(_connection_manager), do: :ok

  @spec put(pid(), map()) :: :ok
  def put(connection_manager, session) when is_pid(connection_manager) and is_map(session) do
    ensure_started()
    GenServer.call(@server, {:put, connection_manager, session})
  end

  @spec fetch(pid() | nil) :: {:ok, map()} | :error
  def fetch(connection_manager) when is_pid(connection_manager) do
    ensure_started()

    case :ets.lookup(@table, connection_manager) do
      [{^connection_manager, session}] -> {:ok, session}
      [] -> :error
    end
  end

  def fetch(_connection_manager), do: :error

  @spec delete(pid() | nil) :: :ok
  def delete(connection_manager) when is_pid(connection_manager) do
    ensure_started()
    GenServer.call(@server, {:delete, connection_manager})
  end

  def delete(_connection_manager), do: :ok

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, %{pids: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:track, connection_manager}, _from, state) do
    {:reply, :ok, track_connection(connection_manager, state)}
  end

  def handle_call({:put, connection_manager, session}, _from, state) do
    :ets.insert(@table, {connection_manager, session})
    {:reply, :ok, track_connection(connection_manager, state)}
  end

  def handle_call({:delete, connection_manager}, _from, state) do
    {:reply, :ok, delete_connection(connection_manager, state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, connection_manager, _reason}, state) do
    state =
      case Map.fetch(state.refs, ref) do
        {:ok, ^connection_manager} -> delete_connection(connection_manager, state)
        _other -> state
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp track_connection(connection_manager, state) do
    if Map.has_key?(state.pids, connection_manager) do
      state
    else
      ref = Process.monitor(connection_manager)

      %{
        state
        | pids: Map.put(state.pids, connection_manager, ref),
          refs: Map.put(state.refs, ref, connection_manager)
      }
    end
  end

  defp delete_connection(connection_manager, state) do
    :ets.delete(@table, connection_manager)

    case Map.pop(state.pids, connection_manager) do
      {nil, pids} ->
        %{state | pids: pids}

      {ref, pids} ->
        Process.demonitor(ref, [:flush])
        %{state | pids: pids, refs: Map.delete(state.refs, ref)}
    end
  end
end
