defmodule Sftpd.Backends.Benchmark do
  @moduledoc """
  Synthetic backend for transport benchmarks.

  Uploads record only final file sizes. Downloads return zero-filled byte ranges
  without storing full file contents. This keeps benchmark runs focused on SSH
  and SFTP framing costs rather than backend storage allocation.
  """

  @behaviour Sftpd.Backend

  alias Sftpd.Backend

  @keep_marker ".keep"
  @zero_slab :binary.copy(<<0>>, 1024 * 1024)

  @type state :: %{agent: pid()}
  def init(opts) do
    files =
      opts
      |> Keyword.get(:files, %{})
      |> Enum.map(fn {path, value} -> {copied_normalized_path(path), normalize_file(value)} end)
      |> Map.new()

    {:ok, agent} = Agent.start_link(fn -> files end)
    {:ok, %{agent: agent}}
  end

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

  def file_info(path, %{agent: agent}) do
    if Backend.root_path?(path) do
      {:ok, Backend.directory_info()}
    else
      key = copied_normalized_path(path)
      dir_prefix = normalize_prefix(path)

      Agent.get(agent, fn files ->
        case Map.get(files, key) do
          %{size: size, mtime: mtime} ->
            {:ok, Backend.file_info(size, NaiveDateTime.to_erl(mtime), :read_write)}

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

  def make_dir(path, %{agent: agent}) do
    key = normalize_prefix(path) <> @keep_marker

    Agent.update(agent, fn files ->
      Map.put(files, :binary.copy(key), %{size: 0, mtime: NaiveDateTime.utc_now()})
    end)

    :ok
  end

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

  def delete(path, %{agent: agent}) do
    key = copied_normalized_path(path)

    Agent.update(agent, fn files ->
      Map.delete(files, key)
    end)

    :ok
  end

  def rename(src, dst, %{agent: agent}) do
    src_key = copied_normalized_path(src)
    dst_key = copied_normalized_path(dst)
    src_prefix = normalize_prefix(src)
    dst_prefix = normalize_prefix(dst)

    Agent.update(agent, fn files ->
      Enum.reduce(files, %{}, fn {key, data}, renamed ->
        cond do
          key == src_key ->
            Map.put(renamed, dst_key, data)

          src_prefix != "" and String.starts_with?(key, src_prefix) ->
            Map.put(renamed, String.replace_prefix(key, src_prefix, dst_prefix), data)

          true ->
            Map.put(renamed, key, data)
        end
      end)
    end)

    :ok
  end

  def read_file(path, state) do
    case file_info(path, state) do
      {:ok, {:file_info, size, :regular, _, _, _, _, _, _, _, _, _, _, _}} ->
        {:ok, zeroes(size)}

      {:ok, _directory} ->
        {:error, :eisdir}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def write_file(path, content, %{agent: agent}) do
    key = copied_normalized_path(path)
    size = IO.iodata_length(content)

    Agent.update(agent, fn files ->
      Map.put(files, key, %{size: size, mtime: NaiveDateTime.utc_now()})
    end)

    :ok
  end

  def read_file_range(path, offset, len, state) do
    with {:ok, handle} <- open_read(path, %{}, state) do
      read_at(handle, offset, len, state)
    end
  end

  def begin_write(path, state), do: open_write(path, %{}, %{}, state)
  def write_chunk(handle, offset, data, state), do: write_at(handle, offset, data, state)

  def finish_write(%{path: path, size: size}, %{agent: agent}) do
    Agent.update(agent, fn files ->
      Map.put(files, path, %{size: size, mtime: NaiveDateTime.utc_now()})
    end)

    :ok
  end

  def abort_write(_handle, _state), do: :ok

  def open_read(path, _session, %{agent: agent}) do
    key = copied_normalized_path(path)

    Agent.get(agent, fn files ->
      case Map.get(files, key) do
        %{size: size} -> {:ok, %{path: key, size: size}}
        nil -> {:error, :enoent}
      end
    end)
  end

  def read_at(%{size: size}, offset, len, _state) do
    cond do
      offset >= size ->
        :eof

      true ->
        {:ok, zeroes(min(len, size - offset))}
    end
  end

  def open_write(path, _attrs, _session, _state) do
    {:ok, %{path: copied_normalized_path(path), size: 0}}
  end

  def write_at(%{size: size} = handle, offset, data, _state) do
    {:ok, %{handle | size: max(size, offset + IO.iodata_length(data))}}
  end

  def open_dir(path, _session, state) do
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

      {:ok, %{entries: entries, read?: false}}
    end
  end

  def read_dir(%{read?: true}, _state), do: :eof

  def read_dir(%{entries: entries, read?: false} = handle, _state) do
    {:ok, entries, %{handle | read?: true}}
  end

  def close_dir(_handle, _state), do: :ok

  def file_attrs(path, _session, state) do
    case file_info(path, state) do
      {:ok, info} -> {:ok, Backend.attrs_from_file_info(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  def make_dir(path, _attrs, _session, state), do: make_dir(path, state)
  def del_dir(path, _session, state), do: del_dir(path, state)
  def delete(path, _session, state), do: delete(path, state)
  def rename(src, dst, _session, state), do: rename(src, dst, state)

  defp normalize_file(%{size: size, mtime: mtime}) do
    %{size: size, mtime: mtime}
  end

  defp normalize_file(%{content: content, mtime: mtime}) do
    %{size: IO.iodata_length(content), mtime: mtime}
  end

  defp normalize_file(content) do
    %{size: IO.iodata_length(content), mtime: NaiveDateTime.utc_now()}
  end

  defp zeroes(0), do: ""

  defp zeroes(size) when size <= byte_size(@zero_slab) do
    binary_part(@zero_slab, 0, size)
  end

  defp zeroes(size) do
    full_slabs = div(size, byte_size(@zero_slab))
    tail = rem(size, byte_size(@zero_slab))

    [
      List.duplicate(@zero_slab, full_slabs),
      binary_part(@zero_slab, 0, tail)
    ]
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

  defp trim_prefix(str, ""), do: str
  defp trim_prefix(str, prefix), do: String.replace_prefix(str, prefix, "")

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
