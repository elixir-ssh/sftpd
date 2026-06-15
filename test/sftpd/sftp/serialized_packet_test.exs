defmodule Sftpd.SFTP.SerializedPacketTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.SFTP.SerializedPacket

  property "wraps ordinary iodata and computes size when omitted" do
    check all(
            head <- binary(max_length: 64),
            tail <- binary(max_length: 64),
            explicit_size <- integer(0..1024)
          ) do
      iodata = [head, tail]
      expected_size = IO.iodata_length(iodata)

      assert %SerializedPacket{kind: :iodata, iodata: ^iodata, size: ^expected_size} =
               SerializedPacket.iodata(iodata)

      assert %SerializedPacket{kind: :iodata, iodata: ^head, size: ^explicit_size} =
               SerializedPacket.iodata(head, explicit_size)
    end
  end

  property "wraps split data packets and computes size when omitted" do
    check all(
            header <- binary(max_length: 64),
            body <- binary(max_length: 64),
            explicit_size <- integer(0..1024)
          ) do
      data = [body]
      expected_size = byte_size(header) + IO.iodata_length(data)

      assert %SerializedPacket{kind: :data, header: ^header, data: ^data, size: ^expected_size} =
               SerializedPacket.data(header, data)

      assert %SerializedPacket{kind: :data, header: ^header, data: ^body, size: ^explicit_size} =
               SerializedPacket.data(header, body, explicit_size)
    end
  end
end
