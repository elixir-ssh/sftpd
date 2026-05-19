defmodule Sftpd.AuthTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  defmodule PublicKeyAuth do
    @behaviour Sftpd.Auth

    @impl true
    def authenticate_password(_username, _password, _peer, _opts), do: :error

    @impl true
    def authorize_public_key(username, public_key, opts) do
      if username == "key-user" and Sftpd.Auth.fingerprint(public_key) == opts[:fingerprint] do
        {:ok, %{username: username}}
      else
        :error
      end
    end
  end

  defmodule InvalidPasswordSessionAuth do
    @behaviour Sftpd.Auth

    @impl true
    def authenticate_password(_username, _password, _peer, _opts), do: {:ok, nil}

    @impl true
    def authorize_public_key(_username, _public_key, _opts), do: :error
  end

  describe "fingerprint/2" do
    test "returns stable OpenSSH-style SHA256 fingerprints" do
      public_key = rsa_public_key()

      assert "SHA256:" <> encoded = Sftpd.Auth.fingerprint(public_key)
      refute String.contains?(encoded, "=")
      assert Sftpd.Auth.fingerprint(public_key) == Sftpd.Auth.fingerprint(public_key, :sha256)
    end

    property "fingerprints are deterministic and base64 digests are unpadded" do
      public_key = rsa_public_key()

      check all(digest <- member_of([:sha256, :sha384, :sha512])) do
        fingerprint = Sftpd.Auth.fingerprint(public_key, digest)
        expected_prefix = digest |> to_string() |> String.upcase()

        assert fingerprint == Sftpd.Auth.fingerprint(public_key, digest)
        assert String.starts_with?(fingerprint, expected_prefix <> ":")
        refute String.ends_with?(fingerprint, "=")
      end
    end
  end

  describe "decode_authorized_key/1" do
    test "decodes an OpenSSH authorized key line" do
      public_key = rsa_public_key()
      blob = public_key |> :ssh_message.ssh2_pubkey_encode() |> Base.encode64()

      assert {:ok, ^public_key} =
               Sftpd.Auth.decode_authorized_key("ssh-rsa #{blob} test@example")
    end

    test "returns an error for invalid key lines" do
      assert {:error, _reason} = Sftpd.Auth.decode_authorized_key("not a key")
    end

    test "returns a tagged error for invalid base64 key payloads" do
      assert {:error, :invalid_authorized_key} =
               Sftpd.Auth.decode_authorized_key("ssh-rsa not-base64")
    end

    test "decodes lines with quoted options containing key-like text" do
      public_key = rsa_public_key()
      blob = public_key |> :ssh_message.ssh2_pubkey_encode() |> Base.encode64()
      line = ~s(command="echo ssh-rsa #{Base.encode64("not a key")}",no-pty ssh-rsa #{blob})

      assert {:ok, ^public_key} = Sftpd.Auth.decode_authorized_key(line)
    end

    test "decodes lines with escaped quotes inside quoted options" do
      public_key = rsa_public_key()
      blob = public_key |> :ssh_message.ssh2_pubkey_encode() |> Base.encode64()
      line = ~s(command="echo \\"ssh-rsa\\"",environment="A B" ssh-rsa #{blob})

      assert {:ok, ^public_key} = Sftpd.Auth.decode_authorized_key(line)
    end

    test "returns a tagged error for blank lines" do
      assert {:error, :invalid_authorized_key} = Sftpd.Auth.decode_authorized_key(" \t\n ")
    end

    property "decodes authorized-key lines with options, comments, and extra whitespace" do
      public_key = rsa_public_key()
      blob = public_key |> :ssh_message.ssh2_pubkey_encode() |> Base.encode64()

      check all(
              leading <- string([?\s, ?\t], max_length: 4),
              separator <- string([?\s, ?\t], min_length: 1, max_length: 4),
              comment <- string(:alphanumeric, max_length: 20),
              include_options? <- boolean()
            ) do
        prefix = if include_options?, do: "no-pty,no-X11-forwarding ", else: ""
        line = "#{leading}#{prefix}ssh-rsa#{separator}#{blob} #{comment}"

        assert {:ok, ^public_key} = Sftpd.Auth.decode_authorized_key(line)
      end
    end
  end

  describe "key callback" do
    test "accepts authorized public keys and rejects unauthorized keys" do
      public_key = rsa_public_key()
      auth = {PublicKeyAuth, [fingerprint: Sftpd.Auth.fingerprint(public_key)]}
      opts = [key_cb_private: [auth: auth]]

      assert Sftpd.Auth.KeyCallback.is_auth_key(public_key, ~c"key-user", opts)
      refute Sftpd.Auth.KeyCallback.is_auth_key(public_key, ~c"other-user", opts)
    end
  end

  describe "password callback" do
    test "rejects non-map sessions from custom auth modules" do
      password_fun = Sftpd.Auth.Adapter.password_fun({InvalidPasswordSessionAuth, []})

      refute password_fun.("user", "password", :peer, nil)
    end
  end

  defp rsa_public_key do
    private_key = :public_key.generate_key({:rsa, 512, 65_537})
    {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}
  end
end
