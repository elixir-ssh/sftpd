defmodule Sftpd.SSH.SFTPBridgeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.SFTP.SerializedPacket
  alias Sftpd.SSH.SFTPBridge

  property "splitting responses by window preserves total response bytes" do
    check all(
            first <- binary(min_length: 1, max_length: 32),
            second <- binary(max_length: 32),
            window <- integer(0..64)
          ) do
      responses = [SerializedPacket.iodata(first), SerializedPacket.iodata(second)]
      total = IO.iodata_length([first, second])
      {ready, pending, bytes} = SFTPBridge.split_responses_for_window(responses, window)

      assert bytes == min(total, window)
      assert packet_bytes(ready) == bytes
      assert packet_bytes(ready ++ pending) == total
    end
  end

  property "fused window payloads match split then payload encoding" do
    check all(
            first <- binary(min_length: 1, max_length: 64),
            second <- binary(max_length: 64),
            window <- integer(0..128),
            max_packet <- integer(1..64)
          ) do
      channel = %{client_channel: 7, client_window: window, client_max_packet: max_packet}
      responses = [SerializedPacket.iodata(first), SerializedPacket.iodata(second)]

      {ready, pending, bytes} = SFTPBridge.split_responses_for_window(responses, window)
      expected_payloads = SFTPBridge.response_payloads(channel, ready)

      {payloads, fused_pending, fused_bytes} = SFTPBridge.payloads_for_window(channel, responses)

      assert fused_bytes == bytes
      assert packet_bytes(fused_pending) == packet_bytes(pending)
      assert IO.iodata_to_binary(payloads) == IO.iodata_to_binary(expected_payloads)
    end
  end

  test "response payloads split data packets without flattening file data" do
    channel = %{client_channel: 7, client_max_packet: 12}
    header = "header..."
    data = ["abc", ["def"]]
    response = SerializedPacket.data(header, data)

    payloads = SFTPBridge.response_payloads(channel, [response])

    assert [
             [<<94, 7::32, 12::32>>, [^header, ["abc"]]],
             [<<94, 7::32, 3::32>>, [["def"]]]
           ] = payloads
  end

  test "response payloads split binary data packets from the original binary" do
    channel = %{client_channel: 7, client_max_packet: 12}
    header = "header..."
    data = "abcdef"
    response = SerializedPacket.data(header, data)

    payloads = SFTPBridge.response_payloads(channel, [response])

    assert [
             [<<94, 7::32, 12::32>>, [^header, "abc"]],
             [<<94, 7::32, 3::32>>, "def"]
           ] = payloads
  end

  test "near-window detection triggers before the window is exhausted" do
    channel = %{client_window: 10, client_max_packet: 4}

    refute SFTPBridge.responses_near_window?(channel, [])
    refute SFTPBridge.responses_near_window?(channel, [SerializedPacket.iodata("abc")])
    assert SFTPBridge.responses_near_window?(channel, [SerializedPacket.iodata("abcdef")])
  end

  property "near-window detection by accumulated size matches response list detection" do
    check all(
            first <- binary(max_length: 32),
            second <- binary(max_length: 32),
            window <- integer(0..64),
            max_packet <- integer(1..64)
          ) do
      channel = %{client_window: window, client_max_packet: max_packet}
      responses = [SerializedPacket.iodata(first), SerializedPacket.data("hdr", second)]
      size = Enum.reduce(responses, 0, fn response, total -> total + response_size(response) end)

      assert SFTPBridge.responses_near_window_size?(channel, size) ==
               SFTPBridge.responses_near_window?(channel, responses)
    end
  end

  test "response window size uses serialized packet sizes without flattening iodata" do
    assert SFTPBridge.response_window_size(SerializedPacket.iodata(["ab", ["cd"]])) == 4
    assert SFTPBridge.response_window_size(SerializedPacket.data("header", ["body"])) == 10
    assert SFTPBridge.response_window_size({:iodata, ["split", ["data"]], 9}) == 9
  end

  defp packet_bytes(responses) do
    Enum.reduce(responses, 0, fn response, total -> total + response_size(response) end)
  end

  defp response_size(%SerializedPacket{size: size}), do: size
  defp response_size({:iodata, _iodata, size}), do: size
end
