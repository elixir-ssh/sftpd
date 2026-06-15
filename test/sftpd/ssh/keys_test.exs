defmodule Sftpd.SSH.KeysTest do
  use ExUnit.Case, async: true

  alias Sftpd.SSH.{Keys, Wire}

  test "loads an OpenSSH ed25519 host key and signs exchange data" do
    system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

    assert {:ok, key} = Keys.load_host_key(system_dir)
    assert key.algorithm == "ssh-ed25519"

    assert {:ok, "ssh-ed25519", rest} = Wire.take_string(key.blob)
    assert {:ok, public, ""} = Wire.take_string(rest)
    assert byte_size(public) == 32

    data = :crypto.strong_rand_bytes(32)
    signature_blob = Keys.signature(key, data)
    assert {:ok, "ssh-ed25519", rest} = Wire.take_string(signature_blob)
    assert {:ok, signature, ""} = Wire.take_string(rest)
    assert byte_size(signature) == 64
    assert Keys.verify_signature(key, data, signature)
  end
end
