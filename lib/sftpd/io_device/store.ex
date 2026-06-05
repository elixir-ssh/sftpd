defmodule Sftpd.IODevice.Store do
  @moduledoc false

  @type handle :: Sftpd.IODevice.handle()
  @type key :: {:sftpd_io, reference()}

  @spec put(handle(), term()) :: term()
  def put({:sftpd_io, ref}, state) when is_reference(ref) do
    Process.put(key(ref), state)
  end

  @spec get(handle()) :: term() | nil
  def get({:sftpd_io, ref}) when is_reference(ref) do
    Process.get(key(ref))
  end

  @spec delete(handle()) :: term() | nil
  def delete({:sftpd_io, ref}) when is_reference(ref) do
    Process.delete(key(ref))
  end

  @spec key(reference()) :: key()
  defp key(ref), do: {:sftpd_io, ref}
end
