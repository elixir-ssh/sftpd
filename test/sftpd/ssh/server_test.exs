defmodule Sftpd.SSH.ServerTest do
  use ExUnit.Case, async: true

  alias Sftpd.Backends.Memory
  alias Sftpd.SFTP
  alias Sftpd.SFTP.SerializedPacket
  alias Sftpd.SSH.Server
  alias Sftpd.SSH.Wire

  defmodule AbortBackend do
    @moduledoc false

    def abort_write(%{path: path, test_pid: test_pid}, _state) do
      send(test_pid, {:aborted, path})
      :ok
    end

    def close_dir(%{path: path, test_pid: test_pid}, _state) do
      send(test_pid, {:closed_dir, path})
      :ok
    end
  end

  test "validates the backend contract" do
    assert :ok = Server.__test_validate_backend__(Memory)

    assert {:error, {:unsupported_backend, String}} =
             Server.__test_validate_backend__(String)

    assert {:error, {:unsupported_backend, "not a module"}} =
             Server.__test_validate_backend__("not a module")
  end

  test "unsupported global requests fail when the client wants a reply" do
    request = IO.iodata_to_binary([Wire.string("tcpip-forward"), Wire.boolean(true)])

    assert {:reply, <<82>>} = Server.__test_global_request_reply__(request)

    noreply = IO.iodata_to_binary([Wire.string("tcpip-forward"), Wire.boolean(false)])
    assert :noreply = Server.__test_global_request_reply__(noreply)
    assert :noreply = Server.__test_global_request_reply__(<<0, 0, 0, 4, "bad">>)
  end

  test "cleans up open SFTP handles when encrypted sessions exit" do
    sftp_session =
      AbortBackend
      |> SFTP.Session.new(self(), %{username: "test"})
      |> Map.put(:initialized?, true)
      |> Map.put(:handles, %{
        "write" =>
          {:file, :write, "/pending.txt", %{path: "/pending.txt", test_pid: self()}, nil, 0},
        "dir" => {:dir, %{path: "/open-dir", test_pid: self()}}
      })

    state = %{channels: %{0 => %{sftp_session: sftp_session}}}

    assert %{channels: %{0 => %{sftp_session: %{handles: %{}}}}} =
             Server.__test_cleanup_open_handles__(state)

    assert_receive {:aborted, "/pending.txt"}
    assert_receive {:closed_dir, "/open-dir"}
  end

  test "abort open writes is a no-op before channels are initialized" do
    assert %{auth_session: nil} = Server.__test_cleanup_open_handles__(%{auth_session: nil})
  end

  test "splits oversized iodata responses without flattening chunks" do
    channel = %{client_channel: 7, client_max_packet: 4}
    data = ["ab", ["cd"], "ef"]
    response = SerializedPacket.iodata(data)

    payloads = Server.__test_sftp_response_payloads__(channel, [response])

    assert [
             [<<94, 7::32, 4::32>>, ["ab", ["cd"]]],
             [<<94, 7::32, 2::32>>, ["ef"]]
           ] = payloads

    assert "abcdef" = joined_channel_data(payloads)
  end

  test "packs small SFTP responses into one channel data payload" do
    channel = %{client_channel: 7, client_max_packet: 12}
    responses = [SerializedPacket.iodata("ab"), SerializedPacket.iodata("cd")]

    payloads = Server.__test_sftp_response_payloads__(channel, responses)

    assert [_one_payload] = payloads
    assert joined_channel_data(payloads) == "abcd"
  end

  test "splits oversized SFTP data responses without flattening file data" do
    channel = %{client_channel: 7, client_max_packet: 12}
    header = <<1, 2, 3, 4, 5, 6, 7, 8, 9>>
    data = ["abc", ["def"]]
    response = SerializedPacket.data(header, data)

    payloads = Server.__test_sftp_response_payloads__(channel, [response])

    assert [
             [<<94, 7::32, 12::32>>, [^header, ["abc"]]],
             [<<94, 7::32, 3::32>>, [["def"]]]
           ] = payloads

    assert joined_channel_data(payloads) == header <> "abcdef"
  end

  test "splits SFTP data responses when the header fills the packet" do
    channel = %{client_channel: 7, client_max_packet: 4}
    header = "head"
    data = ["body"]
    response = SerializedPacket.data(header, data)

    payloads = Server.__test_sftp_response_payloads__(channel, [response])

    assert [
             [<<94, 7::32, 4::32>>, "head"],
             [<<94, 7::32, 4::32>>, ["body"]]
           ] = payloads

    assert joined_channel_data(payloads) == "headbody"
  end

  test "splits pending responses at the available channel window" do
    responses = [SerializedPacket.iodata([?a, "bc"]), SerializedPacket.iodata("de")]

    {ready, pending, bytes} = Server.__test_split_responses_for_window__(responses, 1)

    assert [ready_response] = ready
    assert {1, [?a]} = response_iodata(ready_response)
    assert [pending_response, %SerializedPacket{size: 2, iodata: "de"}] = pending
    assert {2, ["bc"]} = response_iodata(pending_response)
    assert bytes == 1
  end

  test "batches window adjust payloads until the batch threshold is reached" do
    assert [] = Server.__test_window_adjust_payloads__(7, 1_048_575)

    assert [<<93, 7::32, 1_048_576::32>>] =
             Server.__test_window_adjust_payloads__(7, 1_048_576)
  end

  test "active channel cache tracks put and delete operations" do
    channel = %{server_channel: 3, client_channel: 7, marker: :cached}
    stale_channel = %{channel | marker: :stale}
    other_channel = %{server_channel: 4, client_channel: 8, marker: :other}

    state =
      %{channels: %{3 => stale_channel}, active_channel_id: 3, active_channel: stale_channel}
      |> Server.__test_cache_channel__(channel)

    assert {:ok, ^channel} = Server.__test_fetch_active_channel__(state, 3)
    assert %{channels: %{3 => ^stale_channel}} = state

    assert %{channels: %{3 => ^channel}} = Server.__test_sync_active_channel__(state)

    state = Server.__test_put_channel__(state, other_channel)

    assert %{
             channels: %{3 => ^channel, 4 => ^other_channel},
             active_channel_id: 4,
             active_channel: ^other_channel
           } = state

    state = Server.__test_delete_channel__(state, 3)

    assert :error = Server.__test_fetch_active_channel__(state, 3)
    assert %{channels: %{4 => ^other_channel}, active_channel_id: 4} = state

    state = Server.__test_delete_channel__(state, 4)

    assert %{channels: %{}, active_channel_id: nil, active_channel: nil} = state
  end

  test "closed buffered drain does not restore a deleted channel" do
    state = %{channels: %{}}

    assert {:continue, ^state} = Server.__test_finish_channel_data_drain__({:closed, state})
  end

  defp joined_channel_data(payloads) do
    payloads
    |> Enum.map(fn payload ->
      <<94, 7::32, len::32, data::binary-size(len)>> = IO.iodata_to_binary(payload)
      data
    end)
    |> IO.iodata_to_binary()
  end

  defp response_iodata(%SerializedPacket{kind: :iodata, size: size, iodata: iodata}) do
    {size, iodata}
  end
end
