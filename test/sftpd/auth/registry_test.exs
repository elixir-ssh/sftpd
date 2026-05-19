defmodule Sftpd.Auth.RegistryTest do
  use ExUnit.Case, async: false

  alias Sftpd.Auth.Registry

  test "registry table survives the process that writes a session" do
    connection_manager = idle_process()

    try do
      test_pid = self()

      writer =
        spawn(fn ->
          Registry.put(connection_manager, %{user_id: 123})
          send(test_pid, :written)
        end)

      assert_receive :written
      ref = Process.monitor(writer)
      assert_receive {:DOWN, ^ref, :process, ^writer, _reason}

      assert Registry.fetch(connection_manager) == {:ok, %{user_id: 123}}
    after
      Registry.delete(connection_manager)
      stop_process(connection_manager)
    end
  end

  test "registry removes sessions when connection managers exit" do
    connection_manager = idle_process()

    Registry.put(connection_manager, %{user_id: 456})
    assert Registry.fetch(connection_manager) == {:ok, %{user_id: 456}}

    stop_process(connection_manager)

    assert_eventually(fn ->
      assert Registry.fetch(connection_manager) == :error
    end)
  end

  test "tracking before auth still cleans up later session entries" do
    connection_manager = idle_process()

    Registry.track(connection_manager)
    Registry.put(connection_manager, %{user_id: 789})
    assert Registry.fetch(connection_manager) == {:ok, %{user_id: 789}}

    stop_process(connection_manager)

    assert_eventually(fn ->
      assert Registry.fetch(connection_manager) == :error
    end)
  end

  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
  end

  defp assert_eventually(assertion, attempts_remaining \\ 50)

  defp assert_eventually(assertion, attempts_remaining) when attempts_remaining > 0 do
    try do
      assertion.()
    rescue
      ExUnit.AssertionError ->
        Process.sleep(20)
        assert_eventually(assertion, attempts_remaining - 1)
    end
  end

  defp assert_eventually(assertion, 0), do: assertion.()
end
