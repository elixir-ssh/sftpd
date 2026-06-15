defmodule Sftpd.SSH.AlgorithmsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sftpd.SSH.Algorithms

  test "server kexinit round-trips through decoder" do
    {payload, parsed} = Algorithms.server_kexinit()

    assert {:ok, ^parsed} = Algorithms.decode_kexinit(payload)
    assert "curve25519-sha256" in parsed.kex_algorithms
    assert "ssh-ed25519" in parsed.server_host_key_algorithms
    assert ["aes256-gcm@openssh.com" | _] = parsed.encryption_algorithms_server_to_client
    assert "aes256-gcm@openssh.com" in parsed.encryption_algorithms_server_to_client
  end

  property "negotiates first client-preferred matching algorithms" do
    {_payload, server} = Algorithms.server_kexinit()

    check all(
            preferred_kex <- member_of(["curve25519-sha256@libssh.org", "curve25519-sha256"]),
            preferred_cipher <- member_of(["aes256-gcm@openssh.com"])
          ) do
      client = %{
        server
        | kex_algorithms: ["unknown", preferred_kex, "curve25519-sha256"],
          encryption_algorithms_client_to_server: [preferred_cipher, "aes256-gcm@openssh.com"],
          encryption_algorithms_server_to_client: [preferred_cipher, "aes256-gcm@openssh.com"]
      }

      assert {:ok, negotiated} = Algorithms.negotiate(client, server)
      assert negotiated.kex == preferred_kex
      assert negotiated.cipher_c2s == preferred_cipher
      assert negotiated.cipher_s2c == preferred_cipher
    end
  end

  test "reports missing matches by category" do
    {_payload, server} = Algorithms.server_kexinit()
    client = %{server | kex_algorithms: ["diffie-hellman-group1-sha1"]}

    assert {:error, {:no_matching_algorithm, :kex}} = Algorithms.negotiate(client, server)
  end
end
