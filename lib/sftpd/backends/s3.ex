defmodule Sftpd.Backends.S3 do
  @moduledoc """
  S3 storage backend for the SFTP server.

  This backend supports efficient directory listings and optional streaming read
  and write callbacks for large file transfers.

  See the `Backends` extra in HexDocs for package-level backend guidance and
  `Telemetry` for the event reference emitted around S3-backed operations.
  """

  @behaviour Sftpd.Backend

  require Logger

  alias Sftpd.Backend

  @keep_marker ".keep"
  @multipart_part_size 5 * 1024 * 1024

  @typedoc "S3 backend state containing bucket name, optional prefix, and AWS client module"
  @type state :: %{bucket: String.t(), prefix: String.t(), aws_client: module()}

  @type writer_handle :: %{
          bucket: String.t(),
          key: String.t(),
          upload_id: String.t() | nil,
          next_offset: non_neg_integer(),
          next_part_number: pos_integer(),
          pending_chunks: :queue.queue(binary()),
          pending_size: non_neg_integer(),
          uploaded_parts: [{pos_integer(), binary()}]
        }

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    prefix = Keyword.get(opts, :prefix, "")
    aws_client = Keyword.get(opts, :aws_client, ExAws)
    {:ok, %{bucket: bucket, prefix: prefix, aws_client: aws_client}}
  end

  @impl true
  @spec list_dir(Backend.path(), state()) :: {:ok, [charlist()]} | {:error, atom()}
  def list_dir(path, %{bucket: bucket} = state) do
    prefix = listing_prefix(path, state.prefix)

    case list_entries(bucket, prefix, state, MapSet.new()) do
      {:ok, entries} ->
        {:ok, [~c".", ~c".." | entries]}

      {:error, reason} ->
        Logger.warning("S3 list_dir failed for #{inspect(path)}: #{inspect(reason)}")
        {:ok, [~c".", ~c".."]}
    end
  end

  @impl true
  @spec file_info(Backend.path(), state()) :: {:ok, Backend.file_info()} | {:error, atom()}
  def file_info(path, state) do
    if Backend.root_path?(path) do
      {:ok, Backend.directory_info()}
    else
      key = object_key(path, state.prefix)

      case aws_request(state, ExAws.S3.head_object(state.bucket, key)) do
        {:ok, %{headers: headers}} ->
          {:ok, Backend.file_info(extract_size(headers), extract_mtime(headers), :read_write)}

        {:error, reason} ->
          case normalize_error(reason) do
            :enoent -> check_directory_exists(state.bucket, key, state)
            mapped -> {:error, mapped}
          end
      end
    end
  end

  @impl true
  @spec make_dir(Backend.path(), state()) :: :ok | {:error, atom()}
  def make_dir(path, %{bucket: bucket} = state) do
    key = object_key(path, state.prefix) <> "/" <> @keep_marker

    case aws_request(state, ExAws.S3.put_object(bucket, key, "")) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl true
  @spec del_dir(Backend.path(), state()) :: :ok | {:error, atom()}
  def del_dir(path, %{bucket: bucket} = state) do
    key = object_key(path, state.prefix) <> "/" <> @keep_marker

    case aws_request(state, ExAws.S3.delete_object(bucket, key)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl true
  @spec delete(Backend.path(), state()) :: :ok | {:error, atom()}
  def delete(path, %{bucket: bucket} = state) do
    key = object_key(path, state.prefix)

    case aws_request(state, ExAws.S3.delete_object(bucket, key)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl true
  @spec rename(Backend.path(), Backend.path(), state()) :: :ok | {:error, atom()}
  def rename(src, dst, %{bucket: bucket} = state) do
    src_key = object_key(src, state.prefix)
    dst_key = object_key(dst, state.prefix)

    with {:ok, _} <-
           aws_request(state, ExAws.S3.put_object_copy(bucket, dst_key, bucket, src_key)),
         {:ok, _} <- aws_request(state, ExAws.S3.delete_object(bucket, src_key)) do
      :ok
    else
      {:error, reason} ->
        case normalize_error(reason) do
          :enoent ->
            {:error, :enoent}

          mapped ->
            Logger.error(
              "S3 rename failed for #{inspect(src_key)} -> #{inspect(dst_key)}: #{inspect(reason)}"
            )

            {:error, mapped}
        end
    end
  end

  @impl true
  @spec read_file(Backend.path(), state()) :: {:ok, binary()} | {:error, atom()}
  def read_file(path, %{bucket: bucket} = state) do
    key = object_key(path, state.prefix)

    case aws_request(state, ExAws.S3.get_object(bucket, key)) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl true
  @spec write_file(Backend.path(), binary(), state()) :: :ok | {:error, atom()}
  def write_file(path, content, %{bucket: bucket} = state) do
    key = object_key(path, state.prefix)

    case aws_request(state, ExAws.S3.put_object(bucket, key, content)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl true
  @spec read_file_range(Backend.path(), non_neg_integer(), pos_integer(), state()) ::
          {:ok, binary()} | :eof | {:error, atom()}
  def read_file_range(path, offset, len, %{bucket: bucket} = state) do
    key = object_key(path, state.prefix)
    range = "bytes=#{offset}-#{offset + len - 1}"

    case aws_request(state, ExAws.S3.get_object(bucket, key, range: range)) do
      {:ok, %{body: body} = response} ->
        normalize_range_response(offset, len, body, Map.get(response, :status_code, 200))

      {:error, {:http_error, 416, _}} ->
        :eof

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  @impl true
  @spec begin_write(Backend.path(), state()) :: {:ok, writer_handle()} | {:error, atom()}
  def begin_write(path, state) do
    key = object_key(path, state.prefix)

    {:ok,
     %{
       bucket: state.bucket,
       key: key,
       upload_id: nil,
       next_offset: 0,
       next_part_number: 1,
       pending_chunks: :queue.new(),
       pending_size: 0,
       uploaded_parts: []
     }}
  end

  @impl true
  @spec write_chunk(writer_handle(), non_neg_integer(), iodata(), state()) ::
          {:ok, writer_handle()} | {:error, atom()}
  def write_chunk(%{next_offset: expected_offset}, offset, _chunk, _state)
      when offset != expected_offset do
    {:error, :einval}
  end

  def write_chunk(writer, offset, chunk, state) do
    chunk = IO.iodata_to_binary(chunk)
    chunk_size = byte_size(chunk)

    writer = %{
      writer
      | pending_chunks: :queue.in(chunk, writer.pending_chunks),
        pending_size: writer.pending_size + chunk_size,
        next_offset: offset + chunk_size
    }

    flush_full_parts(writer, state)
  end

  @impl true
  @spec finish_write(writer_handle(), state()) :: :ok | {:error, atom()}
  def finish_write(%{upload_id: nil, uploaded_parts: []} = writer, state) do
    put_small_object(writer, state)
  end

  def finish_write(%{uploaded_parts: []} = writer, state) do
    with :ok <- abort_multipart(writer, state),
         :ok <- put_small_object(writer, state) do
      :ok
    end
  end

  def finish_write(writer, state) do
    with {:ok, writer} <- maybe_upload_final_part(writer, state),
         :ok <- complete_multipart(writer, state) do
      :ok
    end
  end

  @impl true
  @spec abort_write(writer_handle(), state()) :: :ok
  def abort_write(writer, state) do
    case abort_multipart(writer, state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to abort multipart upload for #{inspect(writer.key)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ensure_multipart_started(%{upload_id: nil} = writer, state) do
    case aws_request(state, ExAws.S3.initiate_multipart_upload(writer.bucket, writer.key)) do
      {:ok, %{body: %{upload_id: upload_id}}} ->
        {:ok, %{writer | upload_id: upload_id}}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp ensure_multipart_started(writer, _state), do: {:ok, writer}

  defp flush_full_parts(%{pending_size: size} = writer, _state)
       when size < @multipart_part_size do
    {:ok, writer}
  end

  defp flush_full_parts(writer, state) do
    with {:ok, writer} <- ensure_multipart_started(writer, state) do
      {part, pending_chunks} = take_pending_bytes(writer.pending_chunks, @multipart_part_size)

      writer = %{
        writer
        | pending_chunks: pending_chunks,
          pending_size: writer.pending_size - @multipart_part_size
      }

      case upload_part(writer, part, state) do
        {:ok, writer} ->
          flush_full_parts(writer, state)

        {:error, reason} ->
          abort_write(writer, state)
          {:error, reason}
      end
    end
  end

  defp maybe_upload_final_part(%{pending_size: 0} = writer, _state), do: {:ok, writer}

  defp maybe_upload_final_part(writer, state) do
    {part, pending_chunks} = take_pending_bytes(writer.pending_chunks, writer.pending_size)

    writer = %{writer | pending_chunks: pending_chunks, pending_size: 0}
    upload_part(writer, part, state)
  end

  defp upload_part(writer, chunk, state) do
    op =
      ExAws.S3.upload_part(
        writer.bucket,
        writer.key,
        writer.upload_id,
        writer.next_part_number,
        chunk
      )

    case aws_request(state, op) do
      {:ok, %{headers: headers}} ->
        with {:ok, etag} <- extract_etag(headers) do
          {:ok,
           %{
             writer
             | next_part_number: writer.next_part_number + 1,
               uploaded_parts: [{writer.next_part_number, etag} | writer.uploaded_parts]
           }}
        end

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp complete_multipart(writer, state) do
    parts = Enum.sort_by(writer.uploaded_parts, &elem(&1, 0))

    case aws_request(
           state,
           ExAws.S3.complete_multipart_upload(writer.bucket, writer.key, writer.upload_id, parts)
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp put_small_object(writer, state) do
    case aws_request(state, ExAws.S3.put_object(writer.bucket, writer.key, pending_body(writer))) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp pending_body(%{pending_chunks: pending_chunks}) do
    pending_chunks |> :queue.to_list() |> IO.iodata_to_binary()
  end

  defp take_pending_bytes(pending_chunks, bytes_to_take) do
    take_pending_bytes(pending_chunks, bytes_to_take, [])
  end

  defp take_pending_bytes(pending_chunks, 0, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), pending_chunks}
  end

  defp take_pending_bytes(pending_chunks, bytes_to_take, acc) do
    case :queue.out(pending_chunks) do
      {{:value, chunk}, pending_chunks} ->
        chunk_size = byte_size(chunk)

        cond do
          chunk_size <= bytes_to_take ->
            take_pending_bytes(pending_chunks, bytes_to_take - chunk_size, [chunk | acc])

          true ->
            {part, rest} = :erlang.split_binary(chunk, bytes_to_take)
            pending_chunks = :queue.in_r(rest, pending_chunks)
            {IO.iodata_to_binary(Enum.reverse([part | acc])), pending_chunks}
        end

      {:empty, _pending_chunks} ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), :queue.new()}
    end
  end

  defp abort_multipart(%{upload_id: nil}, _state), do: :ok

  defp abort_multipart(writer, state) do
    case aws_request(
           state,
           ExAws.S3.abort_multipart_upload(writer.bucket, writer.key, writer.upload_id)
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp check_directory_exists(bucket, key, state) do
    request = ExAws.S3.list_objects_v2(bucket, prefix: key <> "/", delimiter: "/", max_keys: 1)

    case aws_request(state, request) do
      {:ok, %{body: body}} ->
        if directory_listing_present?(body) do
          {:ok, Backend.directory_info()}
        else
          {:error, :enoent}
        end

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp list_entries(bucket, prefix, state, entries, continuation_token \\ nil)

  defp list_entries(bucket, prefix, state, entries, nil) do
    request = ExAws.S3.list_objects_v2(bucket, prefix: prefix, delimiter: "/")
    collect_entries(request, bucket, prefix, state, entries)
  end

  defp list_entries(bucket, prefix, state, entries, continuation_token) do
    request =
      ExAws.S3.list_objects_v2(
        bucket,
        prefix: prefix,
        delimiter: "/",
        continuation_token: continuation_token
      )

    collect_entries(request, bucket, prefix, state, entries)
  end

  defp collect_entries(request, bucket, prefix, state, entries) do
    case aws_request(state, request) do
      {:ok, %{body: body}} ->
        entries =
          body
          |> collect_file_entries(prefix, entries)
          |> then(&collect_directory_entries(body, prefix, &1))

        if body[:is_truncated] == "true" and body[:next_continuation_token] not in [nil, ""] do
          list_entries(bucket, prefix, state, entries, body[:next_continuation_token])
        else
          {:ok, entries |> MapSet.to_list() |> Enum.sort() |> Enum.map(&to_charlist/1)}
        end

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp collect_file_entries(body, prefix, entries) do
    Enum.reduce(body[:contents] || [], entries, fn %{key: key}, entries ->
      case strip_entry_prefix(key, prefix) do
        nil -> entries
        entry -> MapSet.put(entries, entry)
      end
    end)
  end

  defp collect_directory_entries(body, prefix, entries) do
    Enum.reduce(body[:common_prefixes] || [], entries, fn %{prefix: entry_prefix}, entries ->
      case entry_prefix |> String.trim_trailing("/") |> strip_entry_prefix(prefix) do
        nil -> entries
        entry -> MapSet.put(entries, entry)
      end
    end)
  end

  defp strip_entry_prefix(entry, prefix) do
    stripped =
      cond do
        prefix == "" -> entry
        String.starts_with?(entry, prefix) -> String.replace_prefix(entry, prefix, "")
        true -> nil
      end

    case stripped do
      nil ->
        nil

      "" ->
        nil

      @keep_marker ->
        nil

      value ->
        if String.contains?(value, "/"), do: nil, else: value
    end
  end

  defp directory_listing_present?(body) do
    (body[:contents] || []) != [] or (body[:common_prefixes] || []) != []
  end

  defp object_key(path, global_prefix), do: global_prefix <> Backend.normalize_path(path)

  defp listing_prefix(path, global_prefix) do
    if Backend.root_path?(path), do: global_prefix, else: object_key(path, global_prefix) <> "/"
  end

  defp extract_mtime(headers) do
    case List.keyfind(headers, "Last-Modified", 0) do
      nil -> NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()
      {_, lm} -> parse_http_date(lm)
    end
  end

  defp extract_size(headers) do
    case List.keyfind(headers, "Content-Length", 0) do
      nil -> 0
      {_, length} -> String.to_integer(length)
    end
  end

  defp extract_etag(headers) do
    case Enum.find(headers, fn {key, _value} -> String.downcase(key) == "etag" end) do
      {_, etag} -> {:ok, etag}
      nil -> {:error, :eio}
    end
  end

  defp aws_request(%{aws_client: client}, op) do
    client.request(op)
  end

  defp normalize_error({:http_error, status, _response}) when status in [404, 416], do: :enoent
  defp normalize_error({:http_error, 403, _response}), do: :eacces
  defp normalize_error({:http_error, status, _response}) when status in [408, 429], do: :eio
  defp normalize_error({:http_error, status, _response}) when status >= 500, do: :eio
  defp normalize_error(:not_found), do: :enoent
  defp normalize_error(:forbidden), do: :eacces
  defp normalize_error(:timeout), do: :eio
  defp normalize_error(:econnrefused), do: :eio
  defp normalize_error(:closed), do: :eio
  defp normalize_error(:socket_closed_remotely), do: :eio
  defp normalize_error(_reason), do: :eio

  defp normalize_range_response(_offset, _len, "", status) when status in [200, 206], do: :eof

  defp normalize_range_response(_offset, len, body, 206) when byte_size(body) <= len,
    do: {:ok, body}

  defp normalize_range_response(0, len, body, 200) when byte_size(body) <= len,
    do: {:ok, body}

  defp normalize_range_response(_offset, _len, _body, _status), do: {:error, :eio}

  @doc """
  Parse an HTTP date string (RFC 1123 format) into an Erlang datetime tuple.

  Returns the current time if parsing fails.
  """
  @spec parse_http_date(String.t()) :: :calendar.datetime()
  def parse_http_date(date_string) do
    case parse_rfc1123(date_string) do
      {:ok, datetime} -> datetime
      {:error, _} -> NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()
    end
  end

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  defp parse_rfc1123(date_string) do
    regex = ~r/\w+, (\d+) (\w+) (\d+) (\d+):(\d+):(\d+) GMT/

    with [_, day, month, year, hour, min, sec] <- Regex.run(regex, date_string),
         {:ok, month_num} <- month_to_number(month) do
      date = {String.to_integer(year), month_num, String.to_integer(day)}
      time = {String.to_integer(hour), String.to_integer(min), String.to_integer(sec)}
      {:ok, {date, time}}
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp month_to_number(month) do
    case Map.fetch(@months, month) do
      {:ok, num} -> {:ok, num}
      :error -> {:error, :invalid_month}
    end
  end
end
