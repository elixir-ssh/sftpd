defmodule Sftpd.SSH.ServerTest do
  use ExUnit.Case, async: true

  alias Sftpd.SFTP.SerializedPacket
  alias Sftpd.SSH.Server

  test "splits oversized iodata responses without flattening chunks" do
    channel = %{client_channel: 7, client_max_packet: 4}
    data = ["ab", ["cd"], "ef"]
    response = SerializedPacket.iodata(data)

    payloads = Server.__test_sftp_response_payloads__(channel, [response])

    assert [
             [<<94, 7::32>>, [<<4::32>>, ["ab", ["cd"]]]],
             [<<94, 7::32>>, [<<2::32>>, ["ef"]]]
           ] = payloads

    assert "abcdef" = joined_channel_data(payloads)
  end

  test "splits oversized SFTP data responses without flattening file data" do
    channel = %{client_channel: 7, client_max_packet: 12}
    header = <<1, 2, 3, 4, 5, 6, 7, 8, 9>>
    data = ["abc", ["def"]]
    response = SerializedPacket.data(header, data)

    payloads = Server.__test_sftp_response_payloads__(channel, [response])

    assert [
             [<<94, 7::32>>, [<<12::32>>, [^header, ["abc"]]]],
             [<<94, 7::32>>, [<<3::32>>, [["def"]]]]
           ] = payloads

    assert joined_channel_data(payloads) == header <> "abcdef"
  end

  defp joined_channel_data(payloads) do
    payloads
    |> Enum.map(fn payload ->
      <<94, 7::32, len::32, data::binary-size(len)>> = IO.iodata_to_binary(payload)
      data
    end)
    |> IO.iodata_to_binary()
  end
end
