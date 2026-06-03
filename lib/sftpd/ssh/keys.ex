defmodule Sftpd.SSH.Keys do
  @moduledoc false

  alias Sftpd.SSH.Wire

  @ed25519 :"ssh-ed25519"

  @type ed25519_host_key :: %{
          algorithm: binary(),
          private_key: tuple(),
          public_key: binary(),
          blob: binary()
        }

  @spec load_host_key(String.t() | charlist()) :: {:ok, ed25519_host_key()} | {:error, term()}
  def load_host_key(system_dir) do
    opts = [system_dir: to_charlist(system_dir)]

    with {:ok,
          {:ECPrivateKey, _version, _private, {:namedCurve, {1, 3, 101, 112}}, public, _attrs} =
            key} <- :ssh_file.host_key(@ed25519, opts) do
      blob = IO.iodata_to_binary([Wire.string("ssh-ed25519"), Wire.string(public)])
      {:ok, %{algorithm: "ssh-ed25519", private_key: key, public_key: public, blob: blob}}
    end
  end

  @spec signature(ed25519_host_key(), binary()) :: binary()
  def signature(%{private_key: private_key}, data) do
    sig = :public_key.sign(data, :none, private_key)
    IO.iodata_to_binary([Wire.string("ssh-ed25519"), Wire.string(sig)])
  end

  @spec verify_signature(ed25519_host_key(), binary(), binary()) :: boolean()
  def verify_signature(
        %{private_key: {:ECPrivateKey, _v, _priv, curve, public, _attrs}},
        data,
        sig
      ) do
    public_key = {:ECPrivateKey, 1, <<>>, curve, public, :asn1_NOVALUE}
    :public_key.verify(data, :none, sig, public_key)
  end
end
