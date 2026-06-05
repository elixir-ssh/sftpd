defmodule Sftpd.SSH.ServerTest do
  use ExUnit.Case, async: true

  alias Sftpd.SFTP.SerializedPacket
  alias Sftpd.Backends.Memory
  alias Sftpd.SSH.Server

  test "validates the backend contract" do
    assert :ok = Server.__test_validate_backend__(Memory)

    assert {:error, {:unsupported_backend, String}} =
             Server.__test_validate_backend__(String)

    assert {:error, {:unsupported_backend, "not a module"}} =
             Server.__test_validate_backend__("not a module")
  end

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
             [<<94, 7::32>>, [<<12::32>>, [^header, ["abc"]]]],
             [<<94, 7::32>>, [<<3::32>>, [["def"]]]]
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
             [<<94, 7::32>>, [<<4::32>>, "head"]],
             [<<94, 7::32>>, [<<4::32>>, ["body"]]]
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
