defmodule Sftpd.SFTP.SerializedPacket do
  @moduledoc false

  @enforce_keys [:kind]
  defstruct [:kind, :iodata, :header, :data]

  @type t ::
          %__MODULE__{kind: :iodata, iodata: iodata(), header: nil, data: nil}
          | %__MODULE__{kind: :data, iodata: nil, header: binary(), data: iodata()}

  @spec iodata(iodata()) :: t()
  def iodata(iodata), do: %__MODULE__{kind: :iodata, iodata: iodata}

  @spec data(binary(), iodata()) :: t()
  def data(header, data) when is_binary(header) do
    %__MODULE__{kind: :data, header: header, data: data}
  end
end
