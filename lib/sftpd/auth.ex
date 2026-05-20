defmodule Sftpd.Auth do
  @moduledoc """
  Behaviour and helpers for SFTP authentication.

  Applications can pass `auth: {Module, opts}` to `Sftpd.start_server/1` or
  `Sftpd.child_spec/1`. The callbacks return an opaque session map that is
  threaded into backend operations for the authenticated SSH connection.
  """

  @typedoc "Opaque session context returned by application auth callbacks."
  @type session :: map()

  @callback authenticate_password(
              username :: String.t(),
              password :: String.t(),
              peer :: term(),
              opts :: term()
            ) ::
              {:ok, session()} | :error | {:error, term()} | :disconnect

  @callback authorize_public_key(
              username :: String.t(),
              public_key :: term(),
              opts :: term()
            ) ::
              {:ok, session()} | :error | {:error, term()}

  @doc """
  Return an OpenSSH-style public-key fingerprint.

  SHA256 fingerprints are formatted as `SHA256:<base64-no-padding>`. MD5
  fingerprints are formatted as `MD5:<colon-separated-hex>`.
  """
  @spec fingerprint(term(), atom()) :: String.t()
  def fingerprint(public_key, digest \\ :sha256) do
    encoded = :ssh_message.ssh2_pubkey_encode(public_key)
    hash = :crypto.hash(digest, encoded)

    case digest do
      :md5 ->
        "MD5:" <>
          (hash
           |> :binary.bin_to_list()
           |> Enum.map_join(":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0"))))

      :sha256 ->
        "SHA256:" <> Base.encode64(hash, padding: false)

      other ->
        "#{String.upcase(to_string(other))}:" <> Base.encode64(hash, padding: false)
    end
  end

  @doc """
  Decode one OpenSSH authorized-key line into an Erlang public key.
  """
  @spec decode_authorized_key(binary()) :: {:ok, term()} | {:error, term()}
  def decode_authorized_key(line) when is_binary(line) do
    line
    |> String.trim()
    |> split_authorized_key_fields()
    |> find_key_blob()
    |> case do
      {:ok, blob64} ->
        with {:ok, blob} <- Base.decode64(blob64),
             public_key <- :ssh_message.ssh2_pubkey_decode(blob) do
          {:ok, public_key}
        else
          :error -> {:error, :invalid_authorized_key}
        end

      :error ->
        {:error, :invalid_authorized_key}
    end
  rescue
    error -> {:error, error}
  end

  defp find_key_blob([type, blob | rest]), do: find_key_blob(type, blob, rest)
  defp find_key_blob(_parts), do: :error

  defp find_key_blob(type, blob, rest) do
    if ssh_key_type?(type) do
      {:ok, blob}
    else
      case rest do
        [next | tail] -> find_key_blob(blob, next, tail)
        [] -> :error
      end
    end
  end

  defp ssh_key_type?("ssh-" <> _), do: true
  defp ssh_key_type?("ecdsa-" <> _), do: true
  defp ssh_key_type?("sk-" <> _), do: true
  defp ssh_key_type?(_type), do: false

  defp split_authorized_key_fields(line),
    do: split_authorized_key_fields(line, [], "", false, false)

  defp split_authorized_key_fields(<<>>, fields, "", _quoted?, _escaped?),
    do: Enum.reverse(fields)

  defp split_authorized_key_fields(<<>>, fields, current, _quoted?, _escaped?),
    do: Enum.reverse([current | fields])

  defp split_authorized_key_fields(<<"\\", rest::binary>>, fields, current, true, false),
    do: split_authorized_key_fields(rest, fields, current <> "\\", true, true)

  defp split_authorized_key_fields(<<"\"", rest::binary>>, fields, current, quoted?, false),
    do: split_authorized_key_fields(rest, fields, current <> "\"", not quoted?, false)

  defp split_authorized_key_fields(<<char::utf8, rest::binary>>, fields, "", false, false)
       when char in [?\s, ?\t, ?\r, ?\n],
       do: split_authorized_key_fields(rest, fields, "", false, false)

  defp split_authorized_key_fields(<<char::utf8, rest::binary>>, fields, current, false, false)
       when char in [?\s, ?\t, ?\r, ?\n],
       do: split_authorized_key_fields(rest, [current | fields], "", false, false)

  defp split_authorized_key_fields(
         <<char::utf8, rest::binary>>,
         fields,
         current,
         quoted?,
         _escaped?
       ),
       do: split_authorized_key_fields(rest, fields, current <> <<char::utf8>>, quoted?, false)
end
