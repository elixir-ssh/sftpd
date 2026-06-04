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

  test "decodes empty name-lists and rejects truncated strings" do
    assert {:ok, [], "tail"} = Wire.take_name_list(<<0::32, "tail">>)
    assert :error = Wire.take_string(<<0, 0, 0, 4, "ab">>)
    assert :error = Wire.take_name_list(<<0, 0, 0, 4, "ab">>)
  end

  test "encodes and decodes booleans" do
    assert <<1>> = Wire.boolean(true)
    assert <<0>> = Wire.boolean(false)
    assert {:ok, true, "tail"} = Wire.take_boolean(<<42, "tail">>)
    assert {:ok, false, "tail"} = Wire.take_boolean(<<0, "tail">>)
    assert :error = Wire.take_boolean("")
  end

  test "encodes mpints with sign padding when high bit is set" do
    assert <<0, 0, 0, 2, 0, 128>> = IO.iodata_to_binary(Wire.mpint(128))
    assert {:ok, 128, ""} = Wire.take_mpint(IO.iodata_to_binary(Wire.mpint(128)))
  end

  test "encodes mpints without sign padding when high bit is clear" do
    assert <<0, 0, 0, 1, 127>> = IO.iodata_to_binary(Wire.mpint(127))
    assert {:ok, 127, "tail"} = Wire.take_mpint(<<0, 0, 0, 1, 127, "tail">>)
  end

  test "encodes zero mpint as empty string" do
    assert <<0, 0, 0, 0>> = IO.iodata_to_binary(Wire.mpint(0))
    assert {:ok, 0, ""} = Wire.take_mpint(<<0, 0, 0, 0>>)
  end

  test "normalizes binary mpints before encoding" do
    assert <<0, 0, 0, 0>> = IO.iodata_to_binary(Wire.mpint(<<0, 0>>))
    assert <<0, 0, 0, 1, 1>> = IO.iodata_to_binary(Wire.mpint(<<0, 1>>))
    assert <<0, 0, 0, 2, 0, 128>> = IO.iodata_to_binary(Wire.mpint(<<0, 128>>))
  end

  test "strips SSH packet length from iodata" do
    assert "payload" = Wire.strip_packet_length([<<7::32>>, ["pay", "load"]])
  end
end
