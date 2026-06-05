defmodule Sftpd.SSH.WireTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.SSH.Wire

  property "encodes and decodes SSH strings without copying through lists" do
    check all(
            head <- binary(max_length: 64),
            tail <- binary(max_length: 64)
          ) do
      data = [head, tail]
      expected = IO.iodata_to_binary(data)

      encoded = IO.iodata_to_binary(Wire.string(data))

      assert {:ok, ^expected, ""} = Wire.take_string(encoded)
    end
  end

  property "encodes and decodes name-lists" do
    check all(
            names <- list_of(string(:alphanumeric, min_length: 1, max_length: 16), max_length: 16)
          ) do
      encoded = IO.iodata_to_binary(Wire.name_list(names))

      assert {:ok, ^names, ""} = Wire.take_name_list(encoded)
    end
  end

  test "decodes empty name-lists and rejects truncated strings" do
    assert {:ok, [], "tail"} = Wire.take_name_list(<<0::32, "tail">>)
    assert :error = Wire.take_string(<<0, 0, 0, 4, "ab">>)
    assert :error = Wire.take_name_list(<<0, 0, 0, 4, "ab">>)
  end

  property "encodes and decodes booleans" do
    check all(value <- boolean()) do
      encoded = Wire.boolean(value)

      assert {:ok, ^value, "tail"} = Wire.take_boolean(<<encoded::binary, "tail">>)
    end

    assert {:ok, true, "tail"} = Wire.take_boolean(<<42, "tail">>)
    assert :error = Wire.take_boolean("")
  end

  property "encodes and decodes non-negative mpints" do
    check all(value <- integer(0..0xFFFF_FFFF)) do
      encoded = IO.iodata_to_binary(Wire.mpint(value))

      assert {:ok, ^value, ""} = Wire.take_mpint(encoded)
    end
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
