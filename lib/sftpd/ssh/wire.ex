defmodule Sftpd.SSH.Wire do
  @moduledoc false

  import Bitwise

  @spec string(iodata()) :: iodata()
  def string(data) do
    len = IO.iodata_length(data)
    [<<len::32>>, data]
  end

  @spec name_list([binary()]) :: iodata()
  def name_list(names), do: names |> Enum.join(",") |> string()

  @spec boolean(boolean()) :: <<_::8>>
  def boolean(true), do: <<1>>
  def boolean(false), do: <<0>>

  @spec mpint(non_neg_integer() | binary()) :: iodata()
  def mpint(0), do: <<0::32>>

  def mpint(integer) when is_integer(integer) and integer > 0 do
    bytes = :binary.encode_unsigned(integer)

    if (:binary.first(bytes) &&& 0x80) != 0 do
      string(<<0, bytes::binary>>)
    else
      string(bytes)
    end
  end

  def mpint(bytes) when is_binary(bytes) do
    bytes = strip_leading_zeroes(bytes)

    cond do
      bytes == <<>> ->
        <<0::32>>

      (:binary.first(bytes) &&& 0x80) != 0 ->
        string(<<0, bytes::binary>>)

      true ->
        string(bytes)
    end
  end

  @spec take_string(binary()) :: {:ok, binary(), binary()} | :error
  def take_string(<<len::32, rest::binary>>) when byte_size(rest) >= len do
    <<value::binary-size(^len), rest::binary>> = rest
    {:ok, value, rest}
  end

  def take_string(_), do: :error

  @spec take_name_list(binary()) :: {:ok, [binary()], binary()} | :error
  def take_name_list(data) do
    with {:ok, names, rest} <- take_string(data) do
      names =
        case names do
          "" -> []
          _ -> String.split(names, ",")
        end

      {:ok, names, rest}
    end
  end

  @spec take_boolean(binary()) :: {:ok, boolean(), binary()} | :error
  def take_boolean(<<0, rest::binary>>), do: {:ok, false, rest}
  def take_boolean(<<_, rest::binary>>), do: {:ok, true, rest}
  def take_boolean(_), do: :error

  @spec take_mpint(binary()) :: {:ok, non_neg_integer(), binary()} | :error
  def take_mpint(data) do
    with {:ok, bytes, rest} <- take_string(data) do
      {:ok, decode_mpint(bytes), rest}
    end
  end

  @spec decode_mpint(binary()) :: non_neg_integer()
  def decode_mpint(<<>>), do: 0
  def decode_mpint(<<0, rest::binary>>), do: decode_mpint(rest)
  def decode_mpint(bytes), do: :binary.decode_unsigned(bytes)

  @spec strip_packet_length(iodata()) :: binary()
  def strip_packet_length(iodata) do
    <<len::32, payload::binary-size(len)>> = IO.iodata_to_binary(iodata)
    payload
  end

  defp strip_leading_zeroes(<<0, rest::binary>>), do: strip_leading_zeroes(rest)
  defp strip_leading_zeroes(bytes), do: bytes
end
