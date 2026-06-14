defmodule Sftpd.SSH.SFTPBridge do
  @moduledoc false

  alias Sftpd.SFTP.SerializedPacket

  @type payload_channel :: %{
          required(:client_channel) => non_neg_integer(),
          required(:client_max_packet) => pos_integer(),
          optional(atom()) => term()
        }

  @type window_channel :: %{
          required(:client_window) => non_neg_integer(),
          required(:client_max_packet) => pos_integer(),
          optional(atom()) => term()
        }

  @type response_part :: SerializedPacket.t() | {:iodata, iodata(), non_neg_integer()}
  @type window_split :: {[response_part()], [response_part()], non_neg_integer()}

  @spec responses_near_window?(window_channel(), [SerializedPacket.t()]) :: boolean()
  def responses_near_window?(_channel, []), do: false

  def responses_near_window?(channel, responses) do
    responses_window_size(responses) >=
      max(channel.client_window - channel.client_max_packet, 0)
  end

  @spec split_responses_for_window([response_part()], integer()) :: window_split()
  def split_responses_for_window(responses, window) do
    split_responses_for_window(responses, max(window, 0), [], 0)
  end

  @spec response_payloads(payload_channel(), [response_part()]) :: [iodata()]
  def response_payloads(channel, responses) when is_list(responses) do
    max_packet = max(1, channel.client_max_packet)
    client_channel = channel.client_channel

    {payloads, parts, size} =
      Enum.reduce(responses, {[], [], 0}, fn response, {payloads, parts, size} ->
        {response_size, response_data} = response_iodata(response)

        cond do
          response_size > max_packet ->
            payloads = flush_channel_data_payload(payloads, client_channel, parts, size)
            payloads = Enum.reverse(response_split_payloads(channel, response), payloads)
            {payloads, [], 0}

          size == 0 and response_size <= max_packet ->
            {payloads, response_data, response_size}

          size + response_size <= max_packet ->
            {payloads, [parts, response_data], size + response_size}

          true ->
            payloads = flush_channel_data_payload(payloads, client_channel, parts, size)
            {payloads, response_data, response_size}
        end
      end)

    payloads
    |> flush_channel_data_payload(client_channel, parts, size)
    |> Enum.reverse()
  end

  @spec payloads_for_window(window_channel(), [response_part()]) ::
          {[iodata()], [response_part()], non_neg_integer()}
  def payloads_for_window(channel, responses) when is_list(responses) do
    max_packet = max(1, channel.client_max_packet)
    window = max(channel.client_window, 0)

    {payloads, pending, bytes, parts, size} =
      payloads_for_window(
        responses,
        window,
        channel.client_channel,
        max_packet,
        [],
        [],
        0,
        0
      )

    payloads =
      payloads
      |> flush_channel_data_payload(channel.client_channel, parts, size)
      |> Enum.reverse()

    {payloads, pending, bytes}
  end

  defp split_responses_for_window([], _window, ready, bytes) do
    {Enum.reverse(ready), [], bytes}
  end

  defp split_responses_for_window([response | rest] = responses, window, ready, bytes) do
    {response_size, response_data} = response_iodata(response)
    remaining_window = window - bytes

    cond do
      remaining_window <= 0 ->
        {Enum.reverse(ready), responses, bytes}

      response_size <= remaining_window ->
        split_responses_for_window(rest, window, [response | ready], bytes + response_size)

      true ->
        {prefix, suffix} = split_iodata(response_data, remaining_window)

        ready = [{:iodata, prefix, remaining_window} | ready]
        pending = [{:iodata, suffix, response_size - remaining_window} | rest]

        {Enum.reverse(ready), pending, window}
    end
  end

  defp payloads_for_window(
         [],
         _window,
         _client_channel,
         _max_packet,
         payloads,
         parts,
         size,
         bytes
       ) do
    {payloads, [], bytes, parts, size}
  end

  defp payloads_for_window(
         [response | rest] = responses,
         window,
         client_channel,
         max_packet,
         payloads,
         parts,
         size,
         bytes
       ) do
    {response_size, response_data} = response_iodata(response)
    remaining_window = window - bytes

    cond do
      remaining_window <= 0 ->
        {payloads, responses, bytes, parts, size}

      response_size <= remaining_window ->
        {payloads, parts, size} =
          add_channel_response_payload(
            payloads,
            parts,
            size,
            client_channel,
            max_packet,
            response_data,
            response_size
          )

        payloads_for_window(
          rest,
          window,
          client_channel,
          max_packet,
          payloads,
          parts,
          size,
          bytes + response_size
        )

      true ->
        {prefix, suffix} = split_iodata(response_data, remaining_window)

        {payloads, parts, size} =
          add_channel_response_payload(
            payloads,
            parts,
            size,
            client_channel,
            max_packet,
            prefix,
            remaining_window
          )

        pending = [{:iodata, suffix, response_size - remaining_window} | rest]
        {payloads, pending, window, parts, size}
    end
  end

  defp add_channel_response_payload(
         payloads,
         parts,
         size,
         client_channel,
         max_packet,
         response_data,
         response_size
       ) do
    cond do
      response_size > max_packet ->
        payloads = flush_channel_data_payload(payloads, client_channel, parts, size)

        payloads =
          Enum.reverse(
            channel_data_payloads(client_channel, response_data, max_packet, response_size, []),
            payloads
          )

        {payloads, [], 0}

      size == 0 and response_size <= max_packet ->
        {payloads, response_data, response_size}

      size + response_size <= max_packet ->
        {payloads, [parts, response_data], size + response_size}

      true ->
        payloads = flush_channel_data_payload(payloads, client_channel, parts, size)
        {payloads, response_data, response_size}
    end
  end

  defp split_iodata(iodata, bytes) when bytes <= 0, do: {"", iodata}

  defp split_iodata(iodata, bytes) do
    split_iodata(iodata, bytes, [])
  end

  defp split_iodata(iodata, 0, prefix), do: {Enum.reverse(prefix), iodata}

  defp split_iodata([], _bytes, prefix), do: {Enum.reverse(prefix), []}

  defp split_iodata([part | rest], bytes, prefix) do
    part_size = iodata_size(part)

    cond do
      part_size < bytes ->
        split_iodata(rest, bytes - part_size, [part | prefix])

      part_size == bytes ->
        {Enum.reverse([part | prefix]), rest}

      true ->
        {part_prefix, part_suffix} = split_iodata(part, bytes)
        {Enum.reverse([part_prefix | prefix]), [part_suffix | rest]}
    end
  end

  defp split_iodata(data, bytes, prefix) when is_binary(data) do
    size = byte_size(data)

    cond do
      bytes >= size ->
        {Enum.reverse([data | prefix]), ""}

      true ->
        {head, tail} = :erlang.split_binary(data, bytes)
        {Enum.reverse([head | prefix]), tail}
    end
  end

  defp split_iodata(byte, bytes, prefix) when is_integer(byte) do
    if bytes >= 1 do
      {Enum.reverse([byte | prefix]), []}
    else
      {Enum.reverse(prefix), byte}
    end
  end

  defp iodata_size(data) when is_binary(data), do: byte_size(data)
  defp iodata_size(data) when is_list(data), do: IO.iodata_length(data)
  defp iodata_size(data) when is_integer(data), do: 1

  defp responses_window_size(responses) do
    Enum.reduce(responses, 0, fn response, size ->
      {response_size, _response_data} = response_iodata(response)
      size + response_size
    end)
  end

  defp flush_channel_data_payload(payloads, _client_channel, _parts, 0), do: payloads

  defp flush_channel_data_payload(payloads, client_channel, parts, size) do
    [channel_data_payload(client_channel, parts, size) | payloads]
  end

  defp response_iodata(%SerializedPacket{kind: :iodata, iodata: data, size: size}) do
    {size, data}
  end

  defp response_iodata({:iodata, data, size}), do: {size, data}

  defp response_iodata(%SerializedPacket{
         kind: :data,
         header: header,
         data: data,
         size: size
       }) do
    {size, [header, data]}
  end

  defp response_split_payloads(channel, %SerializedPacket{kind: :iodata, iodata: data}) do
    max_packet = max(1, channel.client_max_packet)
    channel_data_payloads(channel.client_channel, data, max_packet, IO.iodata_length(data), [])
  end

  defp response_split_payloads(channel, {:iodata, data, size}) do
    max_packet = max(1, channel.client_max_packet)
    channel_data_payloads(channel.client_channel, data, max_packet, size, [])
  end

  defp response_split_payloads(
         channel,
         %SerializedPacket{kind: :data, header: header, data: data}
       ) do
    channel_data_pair_payloads(channel, header, data)
  end

  defp channel_data_payloads(_client_channel, "", _max_packet, acc), do: Enum.reverse(acc)

  defp channel_data_payloads(client_channel, data, max_packet, acc) do
    bytes = min(byte_size(data), max_packet)
    {chunk, rest} = :erlang.split_binary(data, bytes)
    payload = channel_data_payload(client_channel, chunk, bytes)
    channel_data_payloads(client_channel, rest, max_packet, [payload | acc])
  end

  defp channel_data_payloads(_client_channel, _data, _max_packet, 0, acc),
    do: Enum.reverse(acc)

  defp channel_data_payloads(client_channel, data, max_packet, data_size, acc) do
    bytes = min(data_size, max_packet)
    {chunk, rest} = split_iodata(data, bytes)
    payload = channel_data_payload(client_channel, chunk, bytes)
    channel_data_payloads(client_channel, rest, max_packet, data_size - bytes, [payload | acc])
  end

  defp channel_data_payload(client_channel, data, size) do
    [<<94, client_channel::32, size::32>>, data]
  end

  defp channel_data_pair_payloads(channel, header, data) do
    max_packet = max(1, channel.client_max_packet)
    client_channel = channel.client_channel
    header_size = byte_size(header)

    cond do
      header_size >= max_packet ->
        channel_data_payloads(client_channel, header, max_packet, []) ++
          channel_data_payloads(client_channel, data, max_packet, IO.iodata_length(data), [])

      true ->
        channel_data_pair_payloads(client_channel, header, data, max_packet)
    end
  end

  defp channel_data_pair_payloads(client_channel, header, data, max_packet)
       when is_binary(data) do
    first_data_size = min(byte_size(data), max_packet - byte_size(header))
    {first_data, rest} = :erlang.split_binary(data, first_data_size)

    first_payload =
      channel_data_payload(
        client_channel,
        [header, first_data],
        byte_size(header) + first_data_size
      )

    [first_payload | channel_data_payloads(client_channel, rest, max_packet, [])]
  end

  defp channel_data_pair_payloads(client_channel, header, data, max_packet) do
    first_data_size = min(IO.iodata_length(data), max_packet - byte_size(header))
    {first_data, rest} = split_iodata(data, first_data_size)

    first_payload =
      channel_data_payload(
        client_channel,
        [header, first_data],
        byte_size(header) + first_data_size
      )

    [
      first_payload
      | channel_data_payloads(
          client_channel,
          rest,
          max_packet,
          IO.iodata_length(data) - first_data_size,
          []
        )
    ]
  end
end
