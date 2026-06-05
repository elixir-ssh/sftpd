defmodule Sftpd.IODevice.Store do
  @moduledoc false

  def put({:sftpd_io, ref}, state) when is_reference(ref) do
    Process.put(key(ref), state)
  end

  def get({:sftpd_io, ref}) when is_reference(ref) do
    Process.get(key(ref))
  end

  def delete({:sftpd_io, ref}) when is_reference(ref) do
    Process.delete(key(ref))
  end

  defp key(ref), do: {:sftpd_io, ref}
end
