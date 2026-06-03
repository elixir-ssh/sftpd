defmodule Sftpd.SSH.AlgorithmsTest do
  use ExUnit.Case, async: true

  alias Sftpd.SSH.Algorithms

  test "server kexinit round-trips through decoder" do
    {payload, parsed} = Algorithms.server_kexinit()

    assert {:ok, ^parsed} = Algorithms.decode_kexinit(payload)
    assert "curve25519-sha256" in parsed.kex_algorithms
    assert "ssh-ed25519" in parsed.server_host_key_algorithms
    assert ["aes256-gcm@openssh.com" | _] = parsed.encryption_algorithms_server_to_client
    assert "aes256-gcm@openssh.com" in parsed.encryption_algorithms_server_to_client
  end

  test "negotiates first client-preferred matching algorithms" do
    {_payload, server} = Algorithms.server_kexinit()

    client = %{
      server
      | kex_algorithms: ["unknown", "curve25519-sha256@libssh.org", "curve25519-sha256"],
        encryption_algorithms_client_to_server: ["aes256-gcm@openssh.com"],
        encryption_algorithms_server_to_client: ["aes256-gcm@openssh.com"]
    }

    assert {:ok, negotiated} = Algorithms.negotiate(client, server)
    assert negotiated.kex == "curve25519-sha256@libssh.org"
    assert negotiated.cipher_c2s == "aes256-gcm@openssh.com"
    assert negotiated.cipher_s2c == "aes256-gcm@openssh.com"
  end

  test "reports missing matches by category" do
    {_payload, server} = Algorithms.server_kexinit()
    client = %{server | kex_algorithms: ["diffie-hellman-group1-sha1"]}

    assert {:error, {:no_matching_algorithm, :kex}} = Algorithms.negotiate(client, server)
  end
end
