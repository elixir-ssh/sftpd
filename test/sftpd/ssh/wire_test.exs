defmodule Sftpd.SSH.WireTest do
  use ExUnit.Case, async: true

  alias Sftpd.SSH.Wire

  test "encodes and decodes SSH strings without copying through lists" do
    encoded = IO.iodata_to_binary(Wire.string(["he", "llo"]))
    assert {:ok, "hello", ""} = Wire.take_string(encoded)
  end

  test "encodes and decodes name-lists" do
    encoded = IO.iodata_to_binary(Wire.name_list(["a", "b", "c"]))
    assert {:ok, ["a", "b", "c"], ""} = Wire.take_name_list(encoded)
  end

  test "encodes mpints with sign padding when high bit is set" do
    assert <<0, 0, 0, 2, 0, 128>> = IO.iodata_to_binary(Wire.mpint(128))
    assert {:ok, 128, ""} = Wire.take_mpint(IO.iodata_to_binary(Wire.mpint(128)))
  end

  test "encodes zero mpint as empty string" do
    assert <<0, 0, 0, 0>> = IO.iodata_to_binary(Wire.mpint(0))
    assert {:ok, 0, ""} = Wire.take_mpint(<<0, 0, 0, 0>>)
  end
end
