defmodule Sftpd.SSH.ServerTest do
  use ExUnit.Case, async: true

  alias Sftpd.Backends.Memory
  alias Sftpd.SFTP
  alias Sftpd.SFTP.SerializedPacket
  alias Sftpd.SSH.{Cipher, Packet, Server}
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

  test "connection workers use larger heap and delayed full sweeps" do
    {:fullsweep_after, original_fullsweep_after} = Process.info(self(), :fullsweep_after)
    {:min_heap_size, original_min_heap_size} = Process.info(self(), :min_heap_size)

    try do
      assert :ok = Server.__test_configure_connection_process__()
      assert {:fullsweep_after, 65_535} = Process.info(self(), :fullsweep_after)
      assert {:min_heap_size, 196_650} = Process.info(self(), :min_heap_size)
    after
      Process.flag(:fullsweep_after, original_fullsweep_after)
      Process.flag(:min_heap_size, original_min_heap_size)
    end
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
    assert [] = Server.__test_window_adjust_payloads__(7, 8_388_607)

    assert [<<93, 7::32, 8_388_608::32>>] =
             Server.__test_window_adjust_payloads__(7, 8_388_608)
  end

  test "flush payloads keep window adjust before channel data" do
    channel = %{client_channel: 7, client_max_packet: 12, recv_window_adjust: 8_388_608}
    response = SerializedPacket.iodata("abc")

    assert [
             <<93, 7::32, 8_388_608::32>>,
             [<<94, 7::32, 3::32>>, "abc"]
           ] = Server.__test_sftp_flush_payloads__(channel, [response], true)
  end

  test "SFTP packet splitter accumulates fragmented packets without exposing partials" do
    first = <<1, 2, 3>>
    second = <<4, 5>>

    assert {:ok, [], %{header: <<0, 0>>} = buffer} =
             Server.__test_split_sftp_packets__("", <<0, 0>>)

    assert {:ok, [], %{packet_length: 3, size: 1} = buffer} =
             Server.__test_split_sftp_packets__(buffer, <<0, 3, 1>>)

    assert {:ok, [^first, ^second], ""} =
             Server.__test_split_sftp_packets__(buffer, <<2, 3, 0, 0, 0, 2, second::binary>>)
  end

  test "SFTP packet splitter preserves fragmented write packets as iodata" do
    first = <<6, 1, 2>>
    second = <<4, 5>>

    assert {:ok, [], %{packet_length: 3} = buffer} =
             Server.__test_split_sftp_packets__("", <<0, 0, 0, 3, 6>>)

    assert {:ok, [fragmented, ^second], ""} =
             Server.__test_split_sftp_packets__(buffer, <<1, 2, 0, 0, 0, 2, second::binary>>)

    assert {:iodata, fragmented_parts, 3} = fragmented
    assert IO.iodata_to_binary(fragmented_parts) == first
  end

  test "SFTP packet splitter rejects oversized packets before buffering payload" do
    oversized = 64 * 1024 * 1024 + 1

    assert {:error, :bad_message} =
             Server.__test_split_sftp_packets__("", <<oversized::32, 1, 2, 3>>)
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

  test "open buffered drain caches receive window updates when no flush is needed" do
    channel = %{
      server_channel: 3,
      client_channel: 7,
      pending_responses: [],
      recv_window_adjust: 10,
      client_window: 1_048_576
    }

    state = %{channels: %{}, active_channel_id: nil, active_channel: nil}

    assert {:continue, state} =
             Server.__test_finish_channel_data_drain__({:open, [], state, channel, 123})

    assert {:ok, %{recv_window_adjust: 133}} = Server.__test_fetch_active_channel__(state, 3)
  end

  test "open buffered drain caches deferred client window updates when no flush is needed" do
    channel = %{
      server_channel: 3,
      client_channel: 7,
      pending_responses: [],
      recv_window_adjust: 0,
      client_window: 12
    }

    state = %{channels: %{}, active_channel_id: nil, active_channel: nil}

    assert {:continue, state} =
             Server.__test_finish_channel_data_drain__({:open, [], state, channel, 0})

    assert {:ok, %{client_window: 12}} = Server.__test_fetch_active_channel__(state, 3)
  end

  test "appends pending responses without changing empty appends" do
    first = SerializedPacket.iodata("a")
    second = SerializedPacket.iodata("b")

    channel = %{pending_responses: []}

    assert ^channel = Server.__test_append_pending_responses__(channel, [])

    assert %{pending_responses: [^first]} =
             Server.__test_append_pending_responses__(channel, [first])

    assert %{pending_responses: [^first, ^second]} =
             %{pending_responses: [first]}
             |> Server.__test_append_pending_responses__([second])
  end

  test "nonblocking encrypted drain preserves empty buffers and consumes available packets" do
    {client, server} = connected_sockets()

    try do
      cipher = cipher_state()
      state = %{buffer: "", c2s_cipher: cipher}

      assert {:none, ^state} =
               Server.__test_recv_buffered_or_available_encrypted_payload__(server, state)

      payload = <<94, 3::32, 1::32, 0>>
      {encrypted, _cipher} = Cipher.encrypt_packet(cipher, Packet.encode_aead_packet(payload))
      :ok = :gen_tcp.send(client, encrypted)

      assert {:ok, ^payload, %{buffer: "", c2s_cipher: next_cipher}} =
               recv_available_until_packet(server, state)

      assert next_cipher.sequence == 1
    after
      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end
  end

  test "encrypted receive preserves extra packets after one blocking receive" do
    {client, server} = connected_sockets()

    try do
      cipher = cipher_state()
      state = %{buffer: "", c2s_cipher: cipher}
      first_payload = <<94, 3::32, 1::32, 0>>
      second_payload = <<93, 3::32, 8::32>>

      {first_encrypted, cipher} =
        Cipher.encrypt_packet(cipher, Packet.encode_aead_packet(first_payload))

      {second_encrypted, _cipher} =
        Cipher.encrypt_packet(cipher, Packet.encode_aead_packet(second_payload))

      :ok = :gen_tcp.send(client, [first_encrypted, second_encrypted])

      assert {:ok, ^first_payload, state} =
               Server.__test_recv_encrypted_payload__(server, state)

      assert state.c2s_cipher.sequence == 1
      assert state.buffer == ""

      assert {:ok, ^second_payload, %{buffer: "", c2s_cipher: next_cipher}} =
               Server.__test_recv_encrypted_payload__(server, state)

      assert next_cipher.sequence == 2
    after
      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end
  end

  test "buffered drain accumulates available window adjustments before flushing" do
    {client, server} = connected_sockets()

    try do
      cipher = cipher_state()

      state = %{
        buffer: "",
        c2s_cipher: cipher,
        channels: %{},
        active_channel_id: nil,
        active_channel: nil
      }

      pending = [SerializedPacket.iodata("abcdef")]

      channel = %{
        server_channel: 3,
        client_channel: 7,
        client_window: 0,
        client_max_packet: 12,
        pending_responses: pending
      }

      {first, cipher} =
        Cipher.encrypt_packet(cipher, Packet.encode_aead_packet(<<93, 3::32, 5::32>>))

      {second, _cipher} =
        Cipher.encrypt_packet(cipher, Packet.encode_aead_packet(<<93, 3::32, 7::32>>))

      :ok = :gen_tcp.send(client, [first, second])

      assert {:open, [], state, channel, 0} =
               drain_available_until_adjusts(server, state, channel)

      assert %{client_window: 12, pending_responses: ^pending} = channel
      assert %{active_channel_id: nil, active_channel: nil} = state
    after
      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end
  end

  test "buffered drain coalesces available pipelined packets before flushing" do
    {client, server} = connected_sockets()

    try do
      cipher = cipher_state()

      state = %{
        buffer: "",
        c2s_cipher: cipher,
        channels: %{},
        active_channel_id: nil,
        active_channel: nil
      }

      pending = [SerializedPacket.iodata("abcdef")]

      channel = %{
        server_channel: 3,
        client_channel: 7,
        client_window: 100,
        client_max_packet: 12,
        pending_responses: pending
      }

      {packet, _cipher} =
        Cipher.encrypt_packet(cipher, Packet.encode_aead_packet(<<93, 3::32, 12::32>>))

      :ok = :gen_tcp.send(client, packet)
      Process.sleep(10)

      responses = [SerializedPacket.iodata("response-data")]

      assert {:open, ^responses, state, channel, 0} =
               Server.__test_drain_buffered_sftp_data__(server, 3, state, channel, responses, 0)

      assert %{client_window: 112, pending_responses: ^pending} = channel
      assert %{active_channel_id: nil, active_channel: nil} = state
    after
      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end
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

  defp response_iodata({:iodata, iodata, size}) do
    {size, iodata}
  end

  defp connected_sockets do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    parent = self()

    _acceptor =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        :ok = :gen_tcp.controlling_process(socket, parent)
        send(parent, {:accepted, socket})
      end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false])
    assert_receive {:accepted, server}, 1_000
    :gen_tcp.close(listen)

    {client, server}
  end

  defp recv_available_until_packet(socket, state, attempts \\ 10)

  defp recv_available_until_packet(_socket, _state, 0),
    do: flunk("encrypted packet not available")

  defp recv_available_until_packet(socket, state, attempts) do
    case Server.__test_recv_buffered_or_available_encrypted_payload__(socket, state) do
      {:none, ^state} ->
        Process.sleep(10)
        recv_available_until_packet(socket, state, attempts - 1)

      result ->
        result
    end
  end

  defp drain_available_until_adjusts(socket, state, channel, attempts \\ 10)

  defp drain_available_until_adjusts(_socket, _state, _channel, 0),
    do: flunk("window adjusts not available")

  defp drain_available_until_adjusts(socket, state, channel, attempts) do
    case Server.__test_drain_buffered_sftp_data__(socket, 3, state, channel, [], 0) do
      {:open, [], _state, %{client_window: 0}, 0} ->
        Process.sleep(10)
        drain_available_until_adjusts(socket, state, channel, attempts - 1)

      result ->
        result
    end
  end

  defp cipher_state do
    Cipher.new(
      "aes256-gcm@openssh.com",
      :client_to_server,
      :binary.copy(<<1>>, 32),
      :binary.copy(<<2>>, 32),
      :binary.copy(<<3>>, 32)
    )
  end
end
