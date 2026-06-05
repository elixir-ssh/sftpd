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

  test "response payloads split data packets without flattening file data" do
    channel = %{client_channel: 7, client_max_packet: 12}
    header = "header..."
    data = ["abc", ["def"]]
    response = SerializedPacket.data(header, data)

    payloads = SFTPBridge.response_payloads(channel, [response])

    assert [
             [<<94, 7::32>>, [<<12::32>>, [^header, ["abc"]]]],
             [<<94, 7::32>>, [<<3::32>>, [["def"]]]]
           ] = payloads
  end

  test "near-window detection triggers before the window is exhausted" do
    channel = %{client_window: 10, client_max_packet: 4}

    refute SFTPBridge.responses_near_window?(channel, [])
    refute SFTPBridge.responses_near_window?(channel, [SerializedPacket.iodata("abc")])
    assert SFTPBridge.responses_near_window?(channel, [SerializedPacket.iodata("abcdef")])
  end

  defp packet_bytes(responses) do
    Enum.reduce(responses, 0, fn %SerializedPacket{size: size}, total -> total + size end)
  end
end
