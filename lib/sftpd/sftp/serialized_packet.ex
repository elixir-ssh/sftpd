defmodule Sftpd.SFTP.SerializedPacket do
  @moduledoc false

  @enforce_keys [:kind, :size]
  defstruct [:kind, :iodata, :header, :data, :size]

  @type t ::
          %__MODULE__{
            kind: :iodata,
            iodata: iodata(),
            header: nil,
            data: nil,
            size: non_neg_integer()
          }
          | %__MODULE__{
              kind: :data,
              iodata: nil,
              header: binary(),
              data: iodata(),
              size: non_neg_integer()
            }

  @spec iodata(iodata()) :: t()
  def iodata(iodata), do: iodata(iodata, IO.iodata_length(iodata))

  @spec iodata(iodata(), non_neg_integer()) :: t()
  def iodata(iodata, size), do: %__MODULE__{kind: :iodata, iodata: iodata, size: size}

  @spec data(binary(), iodata()) :: t()
  def data(header, data) when is_binary(header) do
    data(header, data, byte_size(header) + IO.iodata_length(data))
  end

  @spec data(binary(), iodata(), non_neg_integer()) :: t()
  def data(header, data, size) when is_binary(header) do
    %__MODULE__{kind: :data, header: header, data: data, size: size}
  end
end
