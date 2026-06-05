defmodule Sftpd.Backends.S3 do
  @moduledoc """
  S3 storage backend for the SFTP server.

  This backend supports efficient directory listings and optional streaming read
  and write callbacks for large file transfers.

  S3 support is optional at the package level. Applications that use this
  backend must also depend on `:ex_aws`, `:ex_aws_s3`, `:hackney`,
  `:sweet_xml`, `:jason`, and `:configparser_ex`. When those dependencies are
  absent, `init/1` returns `{:error, :missing_s3_dependency}`.

  See the `Backends` extra in HexDocs for package-level backend guidance and
  `Telemetry` for the event reference emitted around S3-backed operations.
  """

  require Logger

  @behaviour Sftpd.Backend

  alias Sftpd.Backend

  @keep_marker ".keep"
  @multipart_part_size 5 * 1024 * 1024
  @max_sparse_write_gap 4 * @multipart_part_size
  @max_materialized_sparse_hole @max_sparse_write_gap

  @typedoc "S3 backend state containing bucket name, optional prefix, and AWS client module"
  @type prefix :: String.t() | {:session, atom()}
  @type state :: %{bucket: String.t(), prefix: prefix(), aws_client: module()}

  @type writer_handle :: %{
          bucket: String.t(),
          key: String.t(),
          upload_id: String.t() | nil,
          next_offset: non_neg_integer(),
          next_part_number: pos_integer(),
          pending_chunks: :queue.queue({non_neg_integer(), binary()}),
          pending_size: non_neg_integer(),
          uploaded_size: non_neg_integer(),
          uploaded_parts: [{pos_integer(), binary()}]
        }

  @doc """
  Initialize the S3 backend.

  Requires the `:bucket` option. `:prefix` scopes all object keys under a
  prefix, and `:aws_client` can override the ExAws-compatible request module.

  Returns `{:error, :missing_bucket}` when `:bucket` is not provided.
  Returns `{:error, :missing_s3_dependency}` when `ExAws.S3` is unavailable,
  which lets core-only applications compile and handle accidental S3
  configuration without adding ExAws.
  """
  @spec init(keyword()) :: {:ok, state()} | {:error, atom()}
  @impl true
  def init(opts) do
    with {:ok, bucket} <- Keyword.fetch(opts, :bucket),
         :ok <- ensure_s3_available() do
      prefix = Keyword.get(opts, :prefix, "")
      aws_client = Keyword.get(opts, :aws_client, ex_aws_module())
      {:ok, %{bucket: bucket, prefix: prefix, aws_client: aws_client}}
    else
      :error -> {:error, :missing_bucket}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_dir(Backend.path(), state()) :: {:ok, [charlist()]} | {:error, atom()}
  def list_dir(path, state), do: list_dir(path, %{}, state)

  @spec list_dir(Backend.path(), Backend.session(), state()) ::
          {:ok, [charlist()]} | {:error, atom()}
  def list_dir(path, session, %{bucket: bucket} = state) do
    prefix = listing_prefix(path, resolved_prefix(state, session))

    case list_entries(bucket, prefix, state, MapSet.new()) do
      {:ok, entries} ->
        {:ok, [~c".", ~c".." | entries]}

      {:error, reason} ->
        Logger.warning("S3 list_dir failed for #{inspect(path)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec file_info(Backend.path(), state()) :: {:ok, Backend.file_info()} | {:error, atom()}
  def file_info(path, state), do: file_info(path, %{}, state)

  @spec file_info(Backend.path(), Backend.session(), state()) ::
          {:ok, Backend.file_info()} | {:error, atom()}
  def file_info(path, session, state) do
    if Backend.root_path?(path) do
      {:ok, Backend.directory_info()}
    else
      key = object_key(path, resolved_prefix(state, session))

      case aws_request(state, s3_op(:head_object, [state.bucket, key])) do
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

  @spec make_dir(Backend.path(), state()) :: :ok | {:error, atom()}
  def make_dir(path, state), do: make_dir(path, %{}, state)
  @spec make_dir(Backend.path(), Backend.session(), state()) :: :ok | {:error, atom()}
  def make_dir(path, session, %{bucket: bucket} = state) do
    key = object_key(path, resolved_prefix(state, session)) <> "/" <> @keep_marker

    case aws_request(state, s3_op(:put_object, [bucket, key, ""])) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @spec del_dir(Backend.path(), state()) :: :ok | {:error, atom()}
  def del_dir(path, state), do: del_dir(path, %{}, state)
  @spec del_dir(Backend.path(), Backend.session(), state()) :: :ok | {:error, atom()}
  @impl true
  def del_dir(path, session, %{bucket: bucket} = state) do
    prefix = listing_prefix(path, resolved_prefix(state, session))
    marker_key = prefix <> @keep_marker

    with :ok <- ensure_empty_directory(bucket, prefix, state),
         {:ok, _} <- aws_request(state, s3_op(:delete_object, [bucket, marker_key])) do
      :ok
    else
      {:error, reason} -> {:error, normalize_error(reason)}
      :enotempty -> {:error, :enotempty}
    end
  end

  @spec delete(Backend.path(), state()) :: :ok | {:error, atom()}
  def delete(path, state), do: delete(path, %{}, state)
  @spec delete(Backend.path(), Backend.session(), state()) :: :ok | {:error, atom()}
  @impl true
  def delete(path, session, %{bucket: bucket} = state) do
    key = object_key(path, resolved_prefix(state, session))

    case aws_request(state, s3_op(:delete_object, [bucket, key])) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @spec rename(Backend.path(), Backend.path(), state()) :: :ok | {:error, atom()}
  def rename(src, dst, state), do: rename(src, dst, %{}, state)

  @spec rename(Backend.path(), Backend.path(), Backend.session(), state()) ::
          :ok | {:error, atom()}
  @impl true
  def rename(src, dst, session, %{bucket: bucket} = state) do
    prefix = resolved_prefix(state, session)
    src_key = object_key(src, prefix)
    dst_key = object_key(dst, prefix)

    with {:ok, _} <-
           aws_request(state, s3_op(:put_object_copy, [bucket, dst_key, bucket, src_key])),
         {:ok, _} <- aws_request(state, s3_op(:delete_object, [bucket, src_key])) do
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

  @spec read_file(Backend.path(), state()) :: {:ok, binary()} | {:error, atom()}
  def read_file(path, state), do: read_file(path, %{}, state)

  @spec read_file(Backend.path(), Backend.session(), state()) ::
          {:ok, binary()} | {:error, atom()}
  def read_file(path, session, %{bucket: bucket} = state) do
    key = object_key(path, resolved_prefix(state, session))

    case aws_request(state, s3_op(:get_object, [bucket, key])) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @spec write_file(Backend.path(), binary(), state()) :: :ok | {:error, atom()}
  def write_file(path, content, state), do: write_file(path, content, %{}, state)
  @spec write_file(Backend.path(), binary(), Backend.session(), state()) :: :ok | {:error, atom()}
  def write_file(path, content, session, %{bucket: bucket} = state) do
    key = object_key(path, resolved_prefix(state, session))

    case aws_request(state, s3_op(:put_object, [bucket, key, content])) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @spec read_file_range(Backend.path(), non_neg_integer(), pos_integer(), state()) ::
          {:ok, binary()} | :eof | {:error, atom()}
  def read_file_range(path, offset, len, state),
    do: read_file_range(path, offset, len, %{}, state)

  @spec read_file_range(
          Backend.path(),
          non_neg_integer(),
          pos_integer(),
          Backend.session(),
          state()
        ) ::
          {:ok, binary()} | :eof | {:error, atom()}
  def read_file_range(path, offset, len, session, %{bucket: bucket} = state) do
    key = object_key(path, resolved_prefix(state, session))
    range = "bytes=#{offset}-#{offset + len - 1}"

    case aws_request(state, s3_op(:get_object, [bucket, key, [range: range]])) do
      {:ok, %{body: body} = response} ->
        normalize_range_response(offset, len, body, Map.get(response, :status_code, 200))

      {:error, {:http_error, 416, _}} ->
        :eof

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  @impl true
  def open_read(path, session, state) do
    case file_attrs(path, session, state) do
      {:ok, %{type: :directory}} ->
        {:error, :eisdir}

      {:ok, attrs} ->
        {:ok, %{path: path, session: session, size: Map.get(attrs, :size, 0)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def read_at(%{path: path, session: session}, offset, len, state) do
    read_file_range(path, offset, len, session, state)
  end

  @impl true
  def open_write(path, _attrs, session, state) do
    begin_write(path, session, state)
  end

  @impl true
  def write_at(writer, offset, data, state) do
    write_chunk(writer, offset, data, state)
  end

  @spec begin_write(Backend.path(), state()) :: {:ok, writer_handle()} | {:error, atom()}
  def begin_write(path, state), do: begin_write(path, %{}, state)

  @spec begin_write(Backend.path(), Backend.session(), state()) ::
          {:ok, writer_handle()} | {:error, atom()}
  def begin_write(path, session, state) do
    key = object_key(path, resolved_prefix(state, session))

    {:ok,
     %{
       bucket: state.bucket,
       key: key,
       upload_id: nil,
       next_offset: 0,
       next_part_number: 1,
       pending_chunks: :queue.new(),
       pending_size: 0,
       uploaded_size: 0,
       uploaded_parts: []
     }}
  end

  @spec write_chunk(writer_handle(), non_neg_integer(), iodata(), state()) ::
          {:ok, writer_handle()} | {:error, atom()}
  def write_chunk(writer, offset, chunk, state) do
    cond do
      offset < Map.get(writer, :uploaded_size, 0) ->
        {:error, :einval}

      offset > writer.next_offset and offset - writer.next_offset > @max_sparse_write_gap ->
        {:error, :einval}

      true ->
        chunk = IO.iodata_to_binary(chunk)
        chunk_size = byte_size(chunk)

        writer = %{
          writer
          | pending_chunks: :queue.in({offset, chunk}, writer.pending_chunks),
            pending_size: writer.pending_size + chunk_size,
            next_offset: max(writer.next_offset, offset + chunk_size)
        }

        flush_full_parts(writer, state)
    end
  end

  @spec finish_write(writer_handle(), state()) :: :ok | {:error, atom()}
  @impl true
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

  @spec abort_write(writer_handle(), state()) :: :ok
  @impl true
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

  @impl true
  def open_dir(path, session, state) do
    with {:ok, names} <- list_dir(path, session, state) do
      entries =
        Enum.map(names, fn name ->
          %{name: to_string(name), attrs: listed_entry_attrs(path, name, session, state)}
        end)

      {:ok, %{entries: entries, read?: false}}
    end
  end

  @impl true
  def read_dir(%{read?: true}, _state), do: :eof

  def read_dir(%{entries: entries, read?: false} = handle, _state) do
    {:ok, entries, %{handle | read?: true}}
  end

  @impl true
  def close_dir(_handle, _state), do: :ok

  @impl true
  def file_attrs(path, session, state) do
    case file_info(path, session, state) do
      {:ok, info} -> {:ok, Backend.attrs_from_file_info(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def make_dir(path, _attrs, session, state), do: make_dir(path, session, state)

  defp listed_entry_attrs(_path, name, _session, _state) when name in [~c".", ~c"..", ".", ".."],
    do: %{type: :directory, size: 0, permissions: 0o040755}

  defp listed_entry_attrs(path, name, session, state) do
    case path |> child_path(name) |> file_info(session, state) do
      {:ok, info} -> Backend.attrs_from_file_info(info)
      {:error, _reason} -> %{type: :regular, size: 0, permissions: 0o100644}
    end
  end

  defp ensure_multipart_started(%{upload_id: nil} = writer, state) do
    case aws_request(state, s3_op(:initiate_multipart_upload, [writer.bucket, writer.key])) do
      {:ok, %{body: %{upload_id: upload_id}}} ->
        {:ok, %{writer | upload_id: upload_id}}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp ensure_multipart_started(writer, _state), do: {:ok, writer}

  defp flush_full_parts(writer, state) do
    uploaded_size = Map.get(writer, :uploaded_size, 0)

    if writer.next_offset - uploaded_size < @multipart_part_size or
         not range_covered?(writer.pending_chunks, uploaded_size, @multipart_part_size) do
      {:ok, writer}
    else
      flush_full_part(writer, state)
    end
  end

  defp flush_full_part(writer, state) do
    with {:ok, writer} <- ensure_multipart_started(writer, state) do
      uploaded_size = Map.get(writer, :uploaded_size, 0)
      part = pending_body(writer.pending_chunks, uploaded_size, @multipart_part_size)

      {pending_chunks, pending_size} =
        discard_pending_before(writer.pending_chunks, uploaded_size + @multipart_part_size)

      writer = %{
        writer
        | pending_chunks: pending_chunks,
          pending_size: pending_size
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

  defp maybe_upload_final_part(writer, state) do
    uploaded_size = Map.get(writer, :uploaded_size, 0)

    if writer.next_offset == uploaded_size do
      {:ok, writer}
    else
      with {:ok, part} <-
             checked_pending_body(
               writer.pending_chunks,
               uploaded_size,
               writer.next_offset - uploaded_size
             ) do
        writer = %{writer | pending_chunks: :queue.new(), pending_size: 0}
        upload_part(writer, part, state)
      end
    end
  end

  defp upload_part(writer, chunk, state) do
    op =
      s3_op(:upload_part, [
        writer.bucket,
        writer.key,
        writer.upload_id,
        writer.next_part_number,
        chunk
      ])

    case aws_request(state, op) do
      {:ok, %{headers: headers}} ->
        with {:ok, etag} <- extract_etag(headers) do
          {:ok,
           writer
           |> Map.put(:next_part_number, writer.next_part_number + 1)
           |> Map.put(:uploaded_size, Map.get(writer, :uploaded_size, 0) + byte_size(chunk))
           |> Map.put(:uploaded_parts, [{writer.next_part_number, etag} | writer.uploaded_parts])}
        end

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp complete_multipart(writer, state) do
    parts = Enum.sort_by(writer.uploaded_parts, &elem(&1, 0))

    case aws_request(
           state,
           s3_op(:complete_multipart_upload, [writer.bucket, writer.key, writer.upload_id, parts])
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp put_small_object(writer, state) do
    with {:ok, body} <- checked_pending_body(writer) do
      case aws_request(state, s3_op(:put_object, [writer.bucket, writer.key, body])) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, normalize_error(reason)}
      end
    end
  end

  defp checked_pending_body(%{pending_chunks: pending_chunks, next_offset: next_offset}) do
    checked_pending_body(pending_chunks, 0, next_offset)
  end

  defp checked_pending_body(pending_chunks, start_offset, len) do
    if sparse_hole_size(pending_chunks, start_offset, len) > @max_materialized_sparse_hole do
      {:error, :einval}
    else
      {:ok, pending_body(pending_chunks, start_offset, len)}
    end
  end

  defp pending_body(pending_chunks, start_offset, len) do
    pending_chunks
    |> :queue.to_list()
    |> Enum.map(&normalize_pending_chunk/1)
    |> Enum.reduce(zeroes(len), fn {chunk_offset, chunk}, body ->
      overlay_chunk(body, start_offset, len, chunk_offset, chunk)
    end)
  end

  defp overlay_chunk(body, start_offset, len, chunk_offset, chunk) do
    chunk_size = byte_size(chunk)
    range_end = start_offset + len
    overlap_start = max(start_offset, chunk_offset)
    overlap_end = min(range_end, chunk_offset + chunk_size)

    if overlap_start < overlap_end do
      body_offset = overlap_start - start_offset
      chunk_start = overlap_start - chunk_offset
      take = overlap_end - overlap_start

      {prefix, rest} = :erlang.split_binary(body, body_offset)
      {_old, suffix} = :erlang.split_binary(rest, take)

      IO.iodata_to_binary([prefix, binary_part(chunk, chunk_start, take), suffix])
    else
      body
    end
  end

  defp discard_pending_before(pending_chunks, cutoff) do
    pending_chunks
    |> :queue.to_list()
    |> Enum.map(&normalize_pending_chunk/1)
    |> Enum.reduce(:queue.new(), fn {offset, chunk}, queue ->
      chunk_size = byte_size(chunk)
      chunk_end = offset + chunk_size

      cond do
        chunk_end <= cutoff ->
          queue

        offset < cutoff ->
          keep_offset = cutoff - offset
          rest = binary_part(chunk, keep_offset, chunk_size - keep_offset)
          :queue.in({cutoff, rest}, queue)

        true ->
          :queue.in({offset, chunk}, queue)
      end
    end)
    |> then(fn queue -> {queue, pending_queue_size(queue)} end)
  end

  defp normalize_pending_chunk({offset, chunk}), do: {offset, chunk}
  defp normalize_pending_chunk(chunk) when is_binary(chunk), do: {0, chunk}

  defp range_covered?(pending_chunks, start_offset, len) do
    target = start_offset + len

    pending_chunks
    |> :queue.to_list()
    |> Enum.map(&normalize_pending_chunk/1)
    |> Enum.sort_by(fn {offset, _chunk} -> offset end)
    |> Enum.reduce_while(start_offset, fn {offset, chunk}, covered_until ->
      chunk_end = offset + byte_size(chunk)

      cond do
        covered_until >= target ->
          {:halt, covered_until}

        chunk_end <= covered_until ->
          {:cont, covered_until}

        offset <= covered_until ->
          {:cont, chunk_end}

        true ->
          {:halt, covered_until}
      end
    end)
    |> Kernel.>=(target)
  end

  defp sparse_hole_size(pending_chunks, start_offset, len) do
    max(len - covered_size(pending_chunks, start_offset, len), 0)
  end

  defp covered_size(pending_chunks, start_offset, len) do
    range_end = start_offset + len

    pending_chunks
    |> :queue.to_list()
    |> Enum.map(&normalize_pending_chunk/1)
    |> Enum.map(fn {offset, chunk} ->
      {max(offset, start_offset), min(offset + byte_size(chunk), range_end)}
    end)
    |> Enum.reject(fn {from, to} -> from >= to end)
    |> Enum.sort_by(fn {from, _to} -> from end)
    |> Enum.reduce({0, nil}, fn
      {from, to}, {covered, nil} ->
        {covered, {from, to}}

      {from, to}, {covered, {open_from, open_to}} when from <= open_to ->
        {covered, {open_from, max(open_to, to)}}

      {from, to}, {covered, {open_from, open_to}} ->
        {covered + open_to - open_from, {from, to}}
    end)
    |> then(fn
      {covered, nil} -> covered
      {covered, {from, to}} -> covered + to - from
    end)
  end

  defp pending_queue_size(queue) do
    queue
    |> :queue.to_list()
    |> Enum.reduce(0, fn {_offset, chunk}, size -> size + byte_size(chunk) end)
  end

  defp zeroes(0), do: ""
  defp zeroes(size), do: :binary.copy(<<0>>, size)

  defp child_path(path, name) do
    name = to_string(name)

    cond do
      Backend.root_path?(path) -> "/" <> name
      true -> "/" <> Backend.normalize_path(path) <> "/" <> name
    end
  end

  defp abort_multipart(%{upload_id: nil}, _state), do: :ok

  defp abort_multipart(writer, state) do
    case aws_request(
           state,
           s3_op(:abort_multipart_upload, [writer.bucket, writer.key, writer.upload_id])
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp check_directory_exists(bucket, key, state) do
    request = s3_op(:list_objects_v2, [bucket, [prefix: key <> "/", delimiter: "/", max_keys: 1]])

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

  defp ensure_empty_directory(bucket, prefix, state) do
    request = s3_op(:list_objects_v2, [bucket, [prefix: prefix, delimiter: "/", max_keys: 2]])

    case aws_request(state, request) do
      {:ok, response} ->
        body = Map.get(response, :body, %{})

        contents =
          body
          |> Map.get(:contents, [])
          |> Enum.reject(fn %{key: key} -> key == prefix <> @keep_marker end)

        if contents == [] and Map.get(body, :common_prefixes, []) == [] do
          :ok
        else
          :enotempty
        end

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp list_entries(bucket, prefix, state, entries, continuation_token \\ nil)

  defp list_entries(bucket, prefix, state, entries, nil) do
    request = s3_op(:list_objects_v2, [bucket, [prefix: prefix, delimiter: "/"]])
    collect_entries(request, bucket, prefix, state, entries)
  end

  defp list_entries(bucket, prefix, state, entries, continuation_token) do
    request =
      s3_op(:list_objects_v2, [
        bucket,
        [prefix: prefix, delimiter: "/", continuation_token: continuation_token]
      ])

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

  defp resolved_prefix(%{prefix: {:session, key}}, session), do: Map.fetch!(session, key)
  defp resolved_prefix(%{prefix: prefix}, _session), do: prefix

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

  defp ensure_s3_available do
    if Code.ensure_loaded?(s3_module()) do
      :ok
    else
      {:error, :missing_s3_dependency}
    end
  end

  defp ex_aws_module, do: Module.concat([ExAws])
  defp s3_module, do: Module.concat([ExAws, S3])
  defp s3_op(function, args), do: apply(s3_module(), function, args)

  defp normalize_error({:http_error, status, _response}) when status in [404, 416], do: :enoent
  defp normalize_error({:http_error, 403, _response}), do: :eacces
  defp normalize_error({:http_error, status, _response}) when status in [408, 429], do: :eio
  defp normalize_error({:http_error, status, _response}) when status >= 500, do: :eio
  defp normalize_error(:enoent), do: :enoent
  defp normalize_error(:enotempty), do: :enotempty
  defp normalize_error(:eacces), do: :eacces
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

  ## Examples

      iex> Sftpd.Backends.S3.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT")
      {{1994, 11, 6}, {8, 49, 37}}
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
