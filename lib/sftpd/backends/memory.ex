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

  alias Sftpd.{Backend, FastBackend}

  # Marker file used to represent empty directories (matching S3 convention)
  @keep_marker ".keep"

  @typedoc "Memory backend state containing the Agent process"
  @type state :: %{agent: pid()}

  @typedoc "File data stored in memory"
  @type file_data :: %{content: binary(), mtime: NaiveDateTime.t()}

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    initial_files = Keyword.get(opts, :files, %{})
    {:ok, agent} = Agent.start_link(fn -> initial_files end)
    {:ok, %{agent: agent}}
  end

  @impl true
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

  @impl true
  @spec file_info(Backend.path(), state()) :: {:ok, Backend.file_info()} | {:error, atom()}
  def file_info(path, %{agent: agent}) do
    if Backend.root_path?(path) do
      {:ok, Backend.directory_info()}
    else
      key = Backend.normalize_path(path)
      dir_prefix = normalize_prefix(path)

      Agent.get(agent, fn files ->
        case Map.get(files, key) do
          %{content: content, mtime: mtime} ->
            {:ok, Backend.file_info(byte_size(content), NaiveDateTime.to_erl(mtime), :read_write)}

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

  @impl true
  @spec make_dir(Backend.path(), state()) :: :ok
  def make_dir(path, %{agent: agent}) do
    key = normalize_prefix(path) <> @keep_marker

    Agent.update(agent, fn files ->
      Map.put(files, key, %{content: "", mtime: NaiveDateTime.utc_now()})
    end)

    :ok
  end

  @impl true
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

  @impl true
  @spec delete(Backend.path(), state()) :: :ok
  def delete(path, %{agent: agent}) do
    key = Backend.normalize_path(path)

    Agent.update(agent, fn files ->
      Map.delete(files, key)
    end)

    :ok
  end

  @impl true
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

  @impl true
  @spec read_file(Backend.path(), state()) :: {:ok, binary()} | {:error, :enoent}
  def read_file(path, %{agent: agent}) do
    key = Backend.normalize_path(path)

    Agent.get(agent, fn files ->
      case Map.get(files, key) do
        %{content: content} -> {:ok, content}
        nil -> {:error, :enoent}
      end
    end)
  end

  @impl true
  @spec write_file(Backend.path(), binary(), state()) :: :ok
  def write_file(path, content, %{agent: agent}) do
    key = Backend.normalize_path(path)

    Agent.update(agent, fn files ->
      Map.put(files, key, %{content: content, mtime: NaiveDateTime.utc_now()})
    end)

    :ok
  end

  def open_read(path, _session, state) do
    case read_file(path, state) do
      {:ok, content} -> {:ok, %{path: normalize_binary_path(path), content: content}}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_at(%{content: content}, offset, len, _state) do
    cond do
      offset >= byte_size(content) ->
        :eof

      true ->
        bytes = min(len, byte_size(content) - offset)
        {:ok, binary_part(content, offset, bytes)}
    end
  end

  def open_write(path, _attrs, _session, _state) do
    {:ok, %{path: normalize_binary_path(path), chunks: []}}
  end

  def write_at(%{chunks: chunks} = handle, offset, data, _state) do
    {:ok, %{handle | chunks: [{offset, IO.iodata_to_binary(data)} | chunks]}}
  end

  @impl true
  def finish_write(%{path: path, chunks: chunks}, state) do
    write_file(path, materialize_chunks(chunks), state)
  end

  @impl true
  def abort_write(_handle, _state), do: :ok

  def open_dir(path, _session, state) do
    {:ok, entries} = fast_list_dir(path, state)
    {:ok, %{entries: entries, read?: false}}
  end

  def read_dir(%{read?: true}, _state), do: :eof

  def read_dir(%{entries: entries, read?: false} = handle, _state) do
    {:ok, entries, %{handle | read?: true}}
  end

  def close_dir(_handle, _state), do: :ok

  def file_attrs(path, _session, state) do
    case file_info(path, state) do
      {:ok, info} -> {:ok, FastBackend.attrs_from_file_info(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  def make_dir(path, _attrs, _session, state), do: make_dir(path, state)

  @impl true
  def del_dir(path, _session, state), do: del_dir(path, state)

  @impl true
  def delete(path, _session, state), do: delete(path, state)

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
    path = normalize_binary_path(path)
    name = to_string(name)

    case path do
      "" -> name
      "/" -> name
      _ -> path <> "/" <> name
    end
  end

  defp materialize_chunks(chunks) do
    chunks
    |> Enum.sort_by(fn {offset, _data} -> offset end)
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

  defp normalize_binary_path(path), do: Backend.normalize_path(path)

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
