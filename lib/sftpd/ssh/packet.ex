defmodule Sftpd.SSH.Packet do
  @moduledoc false

  defmodule AEADPacket do
    @moduledoc false

    @enforce_keys [:packet_length, :plaintext]
    defstruct [:packet_length, :plaintext]
  end

  @type aead_packet :: %AEADPacket{packet_length: non_neg_integer(), plaintext: iodata()}
  @max_packet_length 1_048_576

  @spec encode_clear(iodata(), pos_integer()) :: iodata()
  def encode_clear(payload, block_size \\ 8) do
    payload_len = IO.iodata_length(payload)
    padding_len = padding_len(payload_len, block_size)
    padding = :crypto.strong_rand_bytes(padding_len)
    packet_len = payload_len + padding_len + 1

    [<<packet_len::32, padding_len>>, payload, padding]
  end

  @spec encode_aead(iodata(), pos_integer()) :: iodata()
  def encode_aead(payload, block_size \\ 16) do
    %AEADPacket{packet_length: packet_len, plaintext: plaintext} =
      encode_aead_packet(payload, block_size)

    [<<packet_len::32>>, plaintext]
  end

  @spec encode_aead_packet(iodata(), pos_integer()) :: aead_packet()
  def encode_aead_packet(payload, block_size \\ 16) do
    payload_len = IO.iodata_length(payload)
    padding_len = aead_padding_len(payload_len, block_size)
    padding = :crypto.strong_rand_bytes(padding_len)
    packet_len = payload_len + padding_len + 1

    %AEADPacket{packet_length: packet_len, plaintext: [<<padding_len>>, payload, padding]}
  end

  @spec decode_clear(binary()) :: {:ok, binary(), binary()} | :more | {:error, :bad_packet}
  def decode_clear(<<packet_len::32, rest::binary>>) do
    cond do
      packet_len > @max_packet_length ->
        {:error, :bad_packet}

      packet_len < 5 ->
        {:error, :bad_packet}

      byte_size(rest) < packet_len ->
        :more

      true ->
        {packet_body, rest} = :erlang.split_binary(rest, packet_len)
        <<padding_len, payload_and_padding::binary>> = packet_body
        payload_len = packet_len - padding_len - 1

        if invalid_padding?(padding_len, payload_len) or
             byte_size(payload_and_padding) < payload_len do
          {:error, :bad_packet}
        else
          {payload, _padding} = :erlang.split_binary(payload_and_padding, payload_len)
          {:ok, payload, rest}
        end
    end
  end

  def decode_clear(_), do: :more

  @spec decode_decrypted(non_neg_integer(), binary()) :: {:ok, binary()} | {:error, :bad_packet}
  def decode_decrypted(packet_len, plaintext) when byte_size(plaintext) == packet_len do
    case plaintext do
      <<padding_len, payload_and_padding::binary>> ->
        payload_len = packet_len - padding_len - 1

        if invalid_padding?(padding_len, payload_len) or
             byte_size(payload_and_padding) < payload_len do
          {:error, :bad_packet}
        else
          {payload, _padding} = :erlang.split_binary(payload_and_padding, payload_len)
          {:ok, payload}
        end

      _ ->
        {:error, :bad_packet}
    end
  end

  def decode_decrypted(_packet_len, _plaintext), do: {:error, :bad_packet}

  @spec message_id(binary()) :: non_neg_integer() | nil
  def message_id(<<id, _rest::binary>>), do: id
  def message_id(_), do: nil

  defp padding_len(payload_len, block_size) do
    minimum = 4
    base = payload_len + 5
    rem = rem(base + minimum, block_size)
    padding = if rem == 0, do: minimum, else: minimum + block_size - rem

    if base + padding < 16 do
      padding + block_size
    else
      padding
    end
  end

  defp aead_padding_len(payload_len, block_size) do
    minimum = 4
    base = payload_len + 1
    rem = rem(base + minimum, block_size)
    padding = if rem == 0, do: minimum, else: minimum + block_size - rem

    if base + padding < block_size do
      padding + block_size
    else
      padding
    end
  end

  defp invalid_padding?(padding_len, payload_len), do: padding_len < 4 or payload_len < 0
end
