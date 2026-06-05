defmodule Sftpd.FileHandler do
  @moduledoc """
  Generic file handler for Erlang's ssh_sftpd server module.

  This module implements the `:ssh_sftpd_file_api` behaviour and delegates
  all storage operations to the configured backend.

  ## Usage

  This module is used internally by `Sftpd.start_server/1`. You typically
  don't need to use it directly unless you're customizing the SSH daemon setup.

      :ssh_sftpd.subsystem_spec(
        file_handler: {Sftpd.FileHandler, %{backend: MyBackend, backend_state: state}}
      )
  """

  @behaviour :ssh_sftpd_file_api

  alias Sftpd.{Backend, IODevice}

  @event_prefix [:sftpd, :sftp]

  @typedoc "File handler state containing backend module and its state"
  @type state :: %{
          required(:backend) => module(),
          required(:backend_state) => term(),
          optional(:session) => map(),
          optional(:cwd) => charlist()
        }

  @typedoc "Opaque handle returned to OTP ssh_sftpd for an open file"
  @type io_device :: term()

  @impl true
  @spec close(io_device(), state()) :: {:ok | {:error, term()}, state()}
  def close(io_device, state) do
    instrument(
      :close,
      state,
      %{io_device: io_device},
      fn ->
        result =
          if IODevice.handle?(io_device) do
            IODevice.close(io_device)
          else
            {:error, :einval}
          end

        {result, state}
      end,
      fn {result, _state}, duration ->
        {result_measurements(result, duration),
         %{result: result_status(result), reason: result_reason(result)}}
      end
    )
  end

  @impl true
  @spec delete(charlist(), state()) :: {:ok | {:error, atom()}, state()}
  def delete(path, %{backend: backend, backend_state: backend_state} = state) do
    state = ensure_session(state)

    instrument_path_call(:delete, path, state, fn ->
      {backend.delete(to_string(path), session(state), backend_state), state}
    end)
  end

  @impl true
  @spec del_dir(charlist(), state()) :: {:ok | {:error, atom()}, state()}
  def del_dir(path, %{backend: backend, backend_state: backend_state} = state) do
    state = ensure_session(state)

    instrument_path_call(:del_dir, path, state, fn ->
      {backend.del_dir(to_string(path), session(state), backend_state), state}
    end)
  end

  @impl true
  @spec get_cwd(state()) :: {{:ok, charlist()}, state()}
  def get_cwd(%{cwd: cwd} = state) do
    instrument(:get_cwd, state, %{}, fn -> {{:ok, cwd}, state} end)
  end

  def get_cwd(state) do
    instrument(:get_cwd, state, %{}, fn -> {{:ok, ~c"/"}, Map.put(state, :cwd, ~c"/")} end)
  end

  @impl true
  @spec is_dir(charlist(), state()) :: {boolean(), state()}
  def is_dir(path, %{backend: backend, backend_state: backend_state} = state) do
    state = ensure_session(state)

    instrument(
      :is_dir,
      state,
      %{path: to_string(path)},
      fn ->
        case backend.file_attrs(to_string(path), session(state), backend_state) do
          {:ok, %{type: :directory}} ->
            {true, state}

          {:ok, _attrs} ->
            {false, state}

          {:error, _} ->
            {false, state}
        end
      end,
      fn {result, _state}, duration ->
        {%{duration: duration}, %{result: if(result, do: :directory, else: :not_directory)}}
      end
    )
  end

  @impl true
  @spec list_dir(charlist(), state()) :: {{:ok, [charlist()]} | {:error, atom()}, state()}
  def list_dir(path, %{backend: backend, backend_state: backend_state} = state) do
    state = ensure_session(state)

    instrument_path_call(:list_dir, path, state, fn ->
      result =
        with {:ok, handle} <- backend.open_dir(to_string(path), session(state), backend_state),
             {:ok, entries} <- drain_dir_entries(handle, backend, backend_state, []) do
          {:ok, Enum.map(entries, &to_charlist(&1.name))}
        end

      {result, state}
    end)
  end

  @impl true
  @spec make_dir(charlist(), state()) :: {:ok | {:error, atom()}, state()}
  def make_dir(path, %{backend: backend, backend_state: backend_state} = state) do
    state = ensure_session(state)

    instrument_path_call(:make_dir, path, state, fn ->
      {backend.make_dir(to_string(path), %{}, session(state), backend_state), state}
    end)
  end

  @impl true
  @spec make_symlink(charlist(), charlist(), state()) :: {{:error, :enotsup}, state()}
  def make_symlink(_src, _dst, state) do
    instrument(:make_symlink, state, %{}, fn ->
      {{:error, :enotsup}, state}
    end)
  end

  @impl true
  @spec read_link(charlist(), state()) :: {{:error, :einval}, state()}
  def read_link(_path, state) do
    # Return einval to indicate path exists but is not a symlink
    # (we don't support symlinks, so nothing is ever a symlink)
    instrument(:read_link, state, %{}, fn ->
      {{:error, :einval}, state}
    end)
  end

  @impl true
  @spec read_link_info(charlist(), state()) ::
          {{:ok, Backend.file_info()} | {:error, atom()}, state()}
  def read_link_info(path, state) when path in [~c"/", ~c"/.", ~c"/..", ~c"..", ~c".", ~c""] do
    instrument_path_call(:read_link_info, path, state, fn ->
      {read_file_info_result(path, state), state}
    end)
  end

  def read_link_info(path, %{backend: backend, backend_state: backend_state} = state) do
    state = ensure_session(state)

    instrument_path_call(:read_link_info, path, state, fn ->
      {read_file_info_result(path, %{state | backend: backend, backend_state: backend_state}),
       state}
    end)
  end

  @impl true
  @spec open(charlist(), [atom()], state()) :: {{:ok, io_device()} | {:error, term()}, state()}
  def open(path, modes, %{backend: backend, backend_state: backend_state} = state) do
    state = ensure_session(state)

    instrument(
      :open,
      state,
      %{path: to_string(path), requested_modes: modes},
      fn ->
        result =
          cond do
            :read in modes and :write in modes ->
              open_device(path, :read_write, backend, backend_state, state,
                truncate?: :truncate in modes
              )

            :write in modes ->
              open_device(path, :write, backend, backend_state, state)

            true ->
              open_device(path, :read, backend, backend_state, state)
          end

        {result, state}
      end,
      fn {result, _state}, duration ->
        {%{duration: duration},
         %{
           result: result_status(result),
           reason: result_reason(result),
           mode: mode_from_modes(modes)
         }}
      end
    )
  end

  @impl true
  @spec position(io_device(), term(), state()) :: {{:ok, non_neg_integer()}, state()}
  def position(io_device, offset, state) do
    instrument(:position, state, %{io_device: io_device, offset: offset}, fn ->
      result =
        if IODevice.handle?(io_device) do
          IODevice.position(io_device, offset)
        else
          {:error, :einval}
        end

      {result, state}
    end)
  end

  @impl true
  @spec read(io_device(), non_neg_integer(), state()) ::
          {{:ok, binary()} | :eof | {:error, atom()}, state()}
  def read(io_device, len, state) do
    instrument(
      :read,
      state,
      %{io_device: io_device, bytes_requested: len},
      fn ->
        result =
          if IODevice.handle?(io_device) do
            IODevice.read(io_device, len)
          else
            {:error, :einval}
          end

        {result, state}
      end,
      fn {result, _state}, duration ->
        {%{duration: duration, bytes: read_bytes(result)},
         %{result: read_result_status(result), reason: result_reason(result)}}
      end
    )
  end

  @impl true
  @spec read_file_info(charlist(), state()) ::
          {{:ok, Backend.file_info()} | {:error, atom()}, state()}
  def read_file_info(path, state) do
    state = ensure_session(state)

    instrument_path_call(:read_file_info, path, state, fn ->
      {read_file_info_result(path, state), state}
    end)
  end

  @impl true
  @spec write_file_info(charlist(), term(), state()) :: {:ok, state()}
  def write_file_info(_path, _info, state) do
    instrument(:write_file_info, state, %{}, fn -> {:ok, state} end)
  end

  @impl true
  @spec rename(charlist(), charlist(), state()) :: {:ok | {:error, atom()}, state()}
  def rename(src, dst, %{backend: backend, backend_state: backend_state} = state) do
    state = ensure_session(state)

    instrument(:rename, state, %{src_path: to_string(src), dst_path: to_string(dst)}, fn ->
      {backend.rename(to_string(src), to_string(dst), session(state), backend_state), state}
    end)
  end

  @impl true
  @spec write(io_device(), iodata(), state()) :: {:ok | {:error, term()}, state()}
  def write(io_device, data, state) do
    bytes = IO.iodata_length(data)

    instrument(
      :write,
      state,
      %{io_device: io_device},
      fn ->
        result =
          if IODevice.handle?(io_device) do
            IODevice.write(io_device, data, bytes)
          else
            {:error, :einval}
          end

        {result, state}
      end,
      fn {result, _state}, duration ->
        {%{duration: duration, bytes: bytes},
         %{result: result_status(result), reason: result_reason(result)}}
      end
    )
  end

  defp instrument_path_call(operation, path, state, fun) do
    instrument(operation, state, %{path: to_string(path)}, fun)
  end

  defp open_device(path, mode, backend, backend_state, state, opts \\ []) do
    %{
      path: path,
      mode: mode,
      backend: backend,
      backend_state: backend_state,
      session: session(state)
    }
    |> Map.merge(Map.new(opts))
    |> IODevice.start()
  end

  defp drain_dir_entries(handle, backend, backend_state, entries) do
    case backend.read_dir(handle, backend_state) do
      {:ok, page, handle} ->
        drain_dir_entries(handle, backend, backend_state, [page | entries])

      :eof ->
        :ok = backend.close_dir(handle, backend_state)
        {:ok, entries |> Enum.reverse() |> List.flatten()}

      {:error, reason} ->
        _ = backend.close_dir(handle, backend_state)
        {:error, reason}
    end
  end

  defp read_file_info_result(path, _state)
       when path in [~c"/", ~c"/.", ~c"/..", ~c"..", ~c".", ~c""] do
    {:ok, Backend.directory_info()}
  end

  defp read_file_info_result(path, %{backend: backend, backend_state: backend_state} = state) do
    path_str = to_string(path)

    if String.ends_with?(path_str, "/.") or String.ends_with?(path_str, "/..") do
      {:ok, Backend.directory_info()}
    else
      with {:ok, attrs} <-
             backend.file_attrs(to_string(path), Map.get(state, :session, %{}), backend_state) do
        {:ok, Backend.file_info_from_attrs(attrs)}
      end
    end
  end

  defp ensure_session(%{session: session} = state) when is_map(session), do: state

  defp ensure_session(state) do
    case Sftpd.Subsystem.connection_manager()
         |> Sftpd.Auth.Registry.fetch() do
      {:ok, session} -> Map.put(state, :session, session)
      :error -> state
    end
  end

  defp session(state), do: Map.get(state, :session, %{})

  defp instrument(operation, state, metadata, fun, finalize_fun \\ &default_finalize/2) do
    Sftpd.Telemetry.span(
      @event_prefix ++ [operation],
      Map.merge(base_metadata(state), metadata),
      fun,
      finalize_fun
    )
  end

  defp base_metadata(%{backend: backend}) do
    %{backend: backend_name(backend), backend_kind: backend_kind(backend)}
  end

  defp default_finalize(result, duration) do
    {reply, _state} = normalize_result(result)

    {result_measurements(reply, duration),
     %{result: result_status(reply), reason: result_reason(reply)}}
  end

  defp normalize_result({_, _} = result), do: result
  defp normalize_result(result), do: {result, nil}

  defp result_measurements(result, duration) do
    measurements = %{duration: duration}

    case result do
      {:ok, data} when is_binary(data) -> Map.put(measurements, :bytes, byte_size(data))
      _ -> measurements
    end
  end

  defp result_status(:ok), do: :ok
  defp result_status({:ok, _value}), do: :ok
  defp result_status(:eof), do: :eof
  defp result_status({:error, _reason}), do: :error
  defp result_status(result) when is_boolean(result), do: if(result, do: :ok, else: :error)

  defp read_result_status(:eof), do: :eof
  defp read_result_status(result), do: result_status(result)

  defp result_reason({:error, reason}), do: reason
  defp result_reason(_result), do: nil

  defp read_bytes({:ok, data}) when is_binary(data), do: byte_size(data)
  defp read_bytes(_result), do: 0

  defp mode_from_modes(modes) do
    cond do
      :write in modes -> :write
      :read in modes -> :read
      true -> :read
    end
  end

  defp backend_kind(module) when is_atom(module), do: :module

  defp backend_name(module) when is_atom(module), do: module
end
