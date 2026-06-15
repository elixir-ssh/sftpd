defmodule Sftpd.Backends.Memory do
  @moduledoc """
  In-memory storage backend for testing and development.

  This backend stores all files in memory using an Agent. It's useful for:
  - Testing without external dependencies (no S3-compatible service needed)
  - Development and experimentation
  - As a reference implementation for custom backends

  ## Usage

      {:ok, ref} = Sftpd.start_server(
        port: 2222,
        backend: Sftpd.Backends.Memory,
        backend_opts: [],
        auth: {:passwords, [{"user", "pass"}]},
        system_dir: "path/to/ssh_keys"
      )

  ## State Structure

  The backend maintains a map of paths to file data:

      %{
        "path/to/file.txt" => %{content: "...", mtime: ~N[...]},
        "path/to/dir/.keep" => %{content: "", mtime: ~N[...]}
      }

  Directories are represented by `.keep` marker files (like S3).

  ## Examples

      iex> {:ok, state} = Sftpd.Backends.Memory.init(
      ...>   files: %{"hello.txt" => %{content: "hi", mtime: ~N[2024-01-01 00:00:00]}}
      ...> )
      iex> Sftpd.Backends.Memory.list_dir(~c"/", state)
      {:ok, [~c".", ~c"..", ~c"hello.txt"]}

      iex> {:ok, state} = Sftpd.Backends.Memory.init([])
      iex> :ok = Sftpd.Backends.Memory.write_file(~c"/notes.txt", "hello", state)
      iex> Sftpd.Backends.Memory.read_file(~c"/notes.txt", state)
      {:ok, "hello"}

  See the `Backends` and `Custom Backends` extras in HexDocs for how this
  backend fits into the wider package model.
  """

  @behaviour Sftpd.Backend

  alias Sftpd.Backend

  # Marker file used to represent empty directories (matching S3 convention)
  @keep_marker ".keep"

  @typedoc "Memory backend state containing the Agent process"
  @type state :: %{agent: pid()}

  @typedoc "File data stored in memory"
  @type file_data ::
          %{content: binary(), mtime: NaiveDateTime.t()}
          | %{
              chunks: %{non_neg_integer() => binary()},
              offsets: [non_neg_integer()],
              offset_index: tuple(),
              size: non_neg_integer(),
              mtime: NaiveDateTime.t()
            }
  @type read_handle :: %{path: Backend.path(), file: file_data()} | %{content: binary()}
  @type write_handle :: %{
          path: Backend.path(),
          chunks: [{non_neg_integer(), binary()}],
          ordered?: boolean(),
          last_end: non_neg_integer() | nil
        }
  @type dir_handle :: %{entries: [Backend.entry()], read?: boolean()}

  @spec init(keyword()) :: {:ok, state()}
  @impl true
  def init(opts) do
    initial_files = Keyword.get(opts, :files, %{})
    {:ok, agent} = Agent.start_link(fn -> initial_files end)
    {:ok, %{agent: agent}}
  end

  @spec list_dir(Backend.path(), state()) :: {:ok, [charlist()]}
  def list_dir(path, %{agent: agent}) do
    prefix = normalize_prefix(path)

    entries =
      Agent.get(agent, fn files ->
        files
        |> Map.keys()
        |> Enum.reduce(MapSet.new(), fn key, entries ->
          if String.starts_with?(key, prefix) do
            case key |> trim_prefix(prefix) |> first_path_segment() do
              "" -> entries
              @keep_marker -> entries
              entry -> MapSet.put(entries, entry)
            end
          else
            entries
          end
        end)
        |> MapSet.to_list()
        |> Enum.sort()
        |> Enum.map(&to_charlist/1)
      end)

    {:ok, [~c".", ~c".." | entries]}
  end

  defp trim_prefix(str, ""), do: str
  defp trim_prefix(str, prefix), do: String.replace_prefix(str, prefix, "")
  @spec file_info(Backend.path(), state()) :: {:ok, Backend.file_info()} | {:error, atom()}
  def file_info(path, %{agent: agent}) do
    if Backend.root_path?(path) do
      {:ok, Backend.directory_info()}
    else
      key = Backend.normalize_path(path)
      dir_prefix = normalize_prefix(path)

      Agent.get(agent, fn files ->
        case Map.get(files, key) do
          %{mtime: mtime} = file_data ->
            {:ok,
             Backend.file_info(file_size(file_data), NaiveDateTime.to_erl(mtime), :read_write)}

          nil ->
            if directory_exists?(files, dir_prefix) do
              {:ok, Backend.directory_info()}
            else
              {:error, :enoent}
            end
        end
      end)
    end
  end

  @spec make_dir(Backend.path(), state()) :: :ok
  def make_dir(path, %{agent: agent}) do
    key = normalize_prefix(path) <> @keep_marker

    Agent.update(agent, fn files ->
      Map.put(files, key, %{content: "", mtime: NaiveDateTime.utc_now()})
    end)

    :ok
  end

  @spec del_dir(Backend.path(), state()) :: :ok | {:error, :eexist}
  def del_dir(path, %{agent: agent}) do
    prefix = normalize_prefix(path)
    keep_marker_key = prefix <> @keep_marker

    Agent.get_and_update(agent, fn files ->
      if non_marker_child_exists?(files, prefix) do
        {{:error, :eexist}, files}
      else
        {:ok, Map.delete(files, keep_marker_key)}
      end
    end)
  end

  @spec delete(Backend.path(), state()) :: :ok
  def delete(path, %{agent: agent}) do
    key = copied_normalized_path(path)

    Agent.update(agent, fn files ->
      Map.delete(files, key)
    end)

    :ok
  end

  @spec rename(Backend.path(), Backend.path(), state()) :: :ok
  def rename(src, dst, %{agent: agent}) do
    src_key = Backend.normalize_path(src)
    dst_key = Backend.normalize_path(dst)

    Agent.update(agent, fn files ->
      case Map.pop(files, src_key) do
        {nil, files} -> files
        {data, files} -> Map.put(files, dst_key, data)
      end
    end)

    :ok
  end

  @spec read_file(Backend.path(), state()) :: {:ok, binary()} | {:error, :enoent}
  def read_file(path, %{agent: agent}) do
    key = Backend.normalize_path(path)

    Agent.get(agent, fn files ->
      case Map.get(files, key) do
        file_data when is_map(file_data) -> {:ok, materialize_file_data(file_data)}
        nil -> {:error, :enoent}
      end
    end)
  end

  @spec write_file(Backend.path(), binary(), state()) :: :ok
  def write_file(path, content, %{agent: agent}) do
    key = copied_normalized_path(path)
    content = IO.iodata_to_binary(content)

    Agent.update(agent, fn files ->
      Map.put(files, key, %{content: content, mtime: NaiveDateTime.utc_now()})
    end)

    :ok
  end

  @spec open_read(Backend.path(), Backend.session(), state()) ::
          {:ok, read_handle()} | {:error, :enoent}
  @impl true
  def open_read(path, _session, %{agent: agent}) do
    key = copied_normalized_path(path)

    Agent.get(agent, fn files ->
      case Map.get(files, key) do
        nil -> {:error, :enoent}
        file_data -> {:ok, %{path: key, file: file_data}}
      end
    end)
  end

  @spec read_at(read_handle(), non_neg_integer(), pos_integer(), state()) ::
          {:ok, binary()} | :eof
  @impl true
  def read_at(%{file: file_data}, offset, len, _state) do
    read_file_data_at(file_data, offset, len)
  end

  def read_at(%{content: content}, offset, len, _state) do
    read_content_at(content, offset, len)
  end

  @spec read_file_range(Backend.path(), non_neg_integer(), pos_integer(), state()) ::
          {:ok, binary()} | :eof | {:error, :enoent}
  def read_file_range(path, offset, len, state) do
    with {:ok, handle} <- open_read(path, %{}, state) do
      read_at(handle, offset, len, state)
    end
  end

  defp read_content_at(content, offset, len) do
    cond do
      offset >= byte_size(content) ->
        :eof

      true ->
        bytes = min(len, byte_size(content) - offset)
        {:ok, binary_part(content, offset, bytes)}
    end
  end

  @spec open_write(Backend.path(), Backend.attrs(), Backend.session(), state()) ::
          {:ok, write_handle()}
  @impl true
  def open_write(path, _attrs, _session, _state) do
    {:ok, %{path: copied_normalized_path(path), chunks: [], ordered?: true, last_end: nil}}
  end

  @spec write_at(write_handle(), non_neg_integer(), iodata(), state()) :: {:ok, write_handle()}
  @impl true
  def write_at(%{chunks: chunks} = handle, offset, data, _state) do
    data = chunk_binary(data)
    last_end = offset + byte_size(data)

    {:ok,
     %{
       handle
       | chunks: [{offset, data} | chunks],
         ordered?: ordered_write?(handle, offset),
         last_end: last_end
     }}
  end

  @spec begin_write(Backend.path(), state()) :: {:ok, write_handle()}
  def begin_write(path, state), do: open_write(path, %{}, %{}, state)

  @spec write_chunk(write_handle(), non_neg_integer(), iodata(), state()) ::
          {:ok, write_handle()}
  def write_chunk(handle, offset, data, state), do: write_at(handle, offset, data, state)

  @spec finish_write(write_handle(), state()) :: :ok
  @impl true
  def finish_write(%{path: path, chunks: chunks, ordered?: ordered?}, %{agent: agent}) do
    file_data = chunks_to_file_data(chunks, ordered?)

    Agent.update(agent, fn files ->
      Map.put(files, path, file_data)
    end)

    :ok
  end

  @spec abort_write(write_handle(), state()) :: :ok
  @impl true
  def abort_write(_handle, _state), do: :ok

  @spec open_dir(Backend.path(), Backend.session(), state()) :: {:ok, dir_handle()}
  @impl true
  def open_dir(path, _session, state) do
    {:ok, entries} = fast_list_dir(path, state)
    {:ok, %{entries: entries, read?: false}}
  end

  @spec read_dir(dir_handle(), state()) :: {:ok, [Backend.entry()], dir_handle()} | :eof
  @impl true
  def read_dir(%{read?: true}, _state), do: :eof

  def read_dir(%{entries: entries, read?: false} = handle, _state) do
    {:ok, entries, %{handle | read?: true}}
  end

  @spec close_dir(dir_handle(), state()) :: :ok
  @impl true
  def close_dir(_handle, _state), do: :ok

  @spec file_attrs(Backend.path(), Backend.session(), state()) ::
          {:ok, Backend.attrs()} | {:error, atom()}
  @impl true
  def file_attrs(path, _session, state) do
    case file_info(path, state) do
      {:ok, info} -> {:ok, Backend.attrs_from_file_info(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec make_dir(Backend.path(), Backend.attrs(), Backend.session(), state()) :: :ok
  @impl true
  def make_dir(path, _attrs, _session, state), do: make_dir(path, state)

  @spec del_dir(Backend.path(), Backend.session(), state()) :: :ok | {:error, :eexist}
  @impl true
  def del_dir(path, _session, state), do: del_dir(path, state)

  @spec delete(Backend.path(), Backend.session(), state()) :: :ok
  @impl true
  def delete(path, _session, state), do: delete(path, state)

  @spec rename(Backend.path(), Backend.path(), Backend.session(), state()) :: :ok
  @impl true
  def rename(src, dst, _session, state), do: rename(src, dst, state)

  # Helpers

  defp fast_list_dir(path, state) do
    with {:ok, names} <- list_dir(path, state) do
      entries =
        Enum.map(names, fn name ->
          child_path = child_path(path, name)

          attrs =
            case file_attrs(child_path, %{}, state) do
              {:ok, attrs} -> attrs
              {:error, _reason} -> %{type: :directory, size: 0, permissions: 0o040755}
            end

          %{name: to_string(name), attrs: attrs}
        end)

      {:ok, entries}
    end
  end

  defp child_path(_path, name) when name in [~c".", ~c".."], do: to_string(name)

  defp child_path(path, name) do
    path = copied_normalized_path(path)
    name = to_string(name)

    case path do
      "" -> name
      "/" -> name
      _ -> path <> "/" <> name
    end
  end

  defp ordered_write?(%{ordered?: false}, _offset), do: false
  defp ordered_write?(%{last_end: nil}, _offset), do: true
  defp ordered_write?(%{last_end: last_end}, offset), do: offset >= last_end

  defp chunks_to_file_data(chunks, true), do: indexed_chunks_to_file_data(Enum.reverse(chunks))

  defp chunks_to_file_data(chunks, false) do
    chunks
    |> Enum.sort_by(fn {offset, _data} -> offset end)
    |> sorted_chunks_to_file_data(chunks)
  end

  defp sorted_chunks_to_file_data(sorted_chunks, original_chunks) do
    if overlapping_chunks?(sorted_chunks) do
      %{
        content: materialize_overlapping_chunks(Enum.reverse(original_chunks)),
        mtime: NaiveDateTime.utc_now()
      }
    else
      indexed_chunks_to_file_data(sorted_chunks)
    end
  end

  defp indexed_chunks_to_file_data(sorted_chunks) do
    offsets = Enum.map(sorted_chunks, fn {offset, _data} -> offset end)
    chunks = Map.new(sorted_chunks)
    size = indexed_size(sorted_chunks)

    %{
      chunks: chunks,
      offsets: offsets,
      offset_index: List.to_tuple(offsets),
      size: size,
      mtime: NaiveDateTime.utc_now()
    }
  end

  defp indexed_size([]), do: 0

  defp indexed_size(chunks) do
    chunks
    |> List.last()
    |> then(fn {offset, data} -> offset + byte_size(data) end)
  end

  defp file_size(%{content: content}), do: byte_size(content)
  defp file_size(%{size: size}), do: size

  defp materialize_file_data(%{content: content}), do: content

  defp materialize_file_data(%{offsets: offsets, size: size} = file_data) do
    case offsets do
      [] -> ""
      _ -> materialize_indexed_file(file_data, 0, size)
    end
  end

  defp read_file_data_at(%{content: content}, offset, len),
    do: read_content_at(content, offset, len)

  defp read_file_data_at(%{size: size} = file_data, offset, len) do
    cond do
      offset >= size ->
        :eof

      true ->
        bytes = min(len, size - offset)
        {:ok, read_indexed_range(file_data, offset, bytes)}
    end
  end

  defp read_indexed_range(%{chunks: chunks} = file_data, offset, len) do
    case Map.get(chunks, offset) do
      chunk when is_binary(chunk) and byte_size(chunk) == len ->
        chunk

      chunk when is_binary(chunk) and byte_size(chunk) > len ->
        binary_part(chunk, 0, len)

      _ ->
        materialize_indexed_range(file_data, offset, offset + len)
    end
  end

  defp materialize_indexed_range(
         %{chunks: chunks, offset_index: offset_index},
         start_offset,
         end_offset
       ) do
    start_index = previous_offset_index(offset_index, start_offset)
    materialize_indexed_tuple(chunks, offset_index, start_offset, end_offset, start_index)
  end

  defp materialize_indexed_range(%{offsets: offsets} = file_data, start_offset, end_offset) do
    start_index =
      offsets
      |> Enum.find_index(fn offset -> offset >= start_offset end)
      |> then(fn
        nil -> max(length(offsets) - 1, 0)
        index -> max(index - 1, 0)
      end)

    materialize_indexed_file(file_data, start_offset, end_offset, start_index)
  end

  defp materialize_indexed_file(%{chunks: chunks, offsets: offsets}, start_offset, end_offset) do
    materialize_indexed_file(%{chunks: chunks, offsets: offsets}, start_offset, end_offset, 0)
  end

  defp materialize_indexed_file(
         %{chunks: chunks, offsets: offsets},
         start_offset,
         end_offset,
         start_index
       ) do
    offsets
    |> Enum.drop(start_index)
    |> Enum.reduce_while({[], start_offset}, fn chunk_offset, {parts, position} ->
      chunk = Map.fetch!(chunks, chunk_offset)
      chunk_end = chunk_offset + byte_size(chunk)

      cond do
        chunk_end <= start_offset ->
          {:cont, {parts, position}}

        chunk_offset >= end_offset ->
          {:halt, {parts, position}}

        true ->
          gap =
            if chunk_offset > position do
              :binary.copy(<<0>>, min(chunk_offset, end_offset) - position)
            else
              []
            end

          take_start = max(position, chunk_offset)
          take_end = min(chunk_end, end_offset)
          take_size = max(0, take_end - take_start)
          chunk_part = binary_part(chunk, take_start - chunk_offset, take_size)

          {:cont, {[parts, gap, chunk_part], take_end}}
      end
    end)
    |> then(fn {parts, position} ->
      tail_gap =
        if position < end_offset do
          :binary.copy(<<0>>, end_offset - position)
        else
          []
        end

      IO.iodata_to_binary([parts, tail_gap])
    end)
  end

  defp materialize_indexed_tuple(chunks, offset_index, start_offset, end_offset, start_index) do
    offset_index
    |> reduce_offsets_from(start_index, {[], start_offset}, fn chunk_offset, {parts, position} ->
      chunk = Map.fetch!(chunks, chunk_offset)
      chunk_end = chunk_offset + byte_size(chunk)

      cond do
        chunk_end <= start_offset ->
          {:cont, {parts, position}}

        chunk_offset >= end_offset ->
          {:halt, {parts, position}}

        true ->
          gap =
            if chunk_offset > position do
              :binary.copy(<<0>>, min(chunk_offset, end_offset) - position)
            else
              []
            end

          take_start = max(position, chunk_offset)
          take_end = min(chunk_end, end_offset)
          take_size = max(0, take_end - take_start)
          chunk_part = binary_part(chunk, take_start - chunk_offset, take_size)

          {:cont, {[parts, gap, chunk_part], take_end}}
      end
    end)
    |> then(fn {parts, position} ->
      tail_gap =
        if position < end_offset do
          :binary.copy(<<0>>, end_offset - position)
        else
          []
        end

      IO.iodata_to_binary([parts, tail_gap])
    end)
  end

  defp reduce_offsets_from(offset_index, index, acc, fun) when index < tuple_size(offset_index) do
    case fun.(elem(offset_index, index), acc) do
      {:cont, acc} -> reduce_offsets_from(offset_index, index + 1, acc, fun)
      {:halt, acc} -> acc
    end
  end

  defp reduce_offsets_from(_offset_index, _index, acc, _fun), do: acc

  defp previous_offset_index(offset_index, offset) do
    size = tuple_size(offset_index)

    cond do
      size == 0 -> 0
      true -> previous_offset_index(offset_index, offset, 0, size - 1, 0)
    end
  end

  defp previous_offset_index(offset_index, offset, low, high, best) when low <= high do
    mid = div(low + high, 2)

    if elem(offset_index, mid) <= offset do
      previous_offset_index(offset_index, offset, mid + 1, high, mid)
    else
      previous_offset_index(offset_index, offset, low, mid - 1, best)
    end
  end

  defp previous_offset_index(_offset_index, _offset, _low, _high, best), do: best

  defp overlapping_chunks?(chunks) do
    chunks
    |> Enum.reduce_while(0, fn {offset, data}, position ->
      if offset < position do
        {:halt, true}
      else
        {:cont, offset + byte_size(data)}
      end
    end) == true
  end

  defp materialize_overlapping_chunks(chunks) do
    chunks
    |> Enum.reduce(<<>>, fn {offset, data}, acc ->
      acc =
        if offset > byte_size(acc) do
          acc <> :binary.copy(<<0>>, offset - byte_size(acc))
        else
          acc
        end

      prefix = binary_part(acc, 0, min(offset, byte_size(acc)))
      suffix_offset = min(offset + byte_size(data), byte_size(acc))
      suffix = binary_part(acc, suffix_offset, byte_size(acc) - suffix_offset)
      prefix <> data <> suffix
    end)
  end

  defp chunk_binary(data) when is_binary(data), do: data
  defp chunk_binary(data), do: IO.iodata_to_binary(data)

  defp copied_normalized_path(path), do: path |> Backend.normalize_path() |> :binary.copy()

  defp normalize_prefix(path) do
    if Backend.root_path?(path) do
      ""
    else
      key =
        path
        |> Backend.normalize_path()
        |> String.trim_trailing("/")

      if key == "", do: "", else: key <> "/"
    end
  end

  defp first_path_segment(path) do
    case :binary.match(path, "/") do
      {index, _length} -> binary_part(path, 0, index)
      :nomatch -> path
    end
  end

  defp directory_exists?(files, dir_prefix) do
    Enum.any?(files, fn {path, _data} -> String.starts_with?(path, dir_prefix) end)
  end

  defp non_marker_child_exists?(files, dir_prefix) do
    keep_marker_key = dir_prefix <> @keep_marker

    Enum.any?(files, fn {path, _data} ->
      String.starts_with?(path, dir_prefix) and path != keep_marker_key
    end)
  end
end
