defmodule Sftpd.SFTP.SerializedPacketTest do
  use ExUnit.Case, async: true

  alias Sftpd.SFTP.SerializedPacket

  test "wraps ordinary iodata and computes size when omitted" do
    assert %SerializedPacket{kind: :iodata, iodata: ["ab", "cd"], size: 4} =
             SerializedPacket.iodata(["ab", "cd"])

    assert %SerializedPacket{kind: :iodata, iodata: "abc", size: 99} =
             SerializedPacket.iodata("abc", 99)
  end

  test "wraps split data packets and computes size when omitted" do
    assert %SerializedPacket{kind: :data, header: "head", data: ["body"], size: 8} =
             SerializedPacket.data("head", ["body"])

    assert %SerializedPacket{kind: :data, header: "h", data: "d", size: 77} =
             SerializedPacket.data("h", "d", 77)
  end
end
