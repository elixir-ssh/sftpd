defmodule Sftpd.SSH.Cipher do
  @moduledoc false

  alias Sftpd.SSH.{Kex, Packet}

  @aes256_gcm "aes256-gcm@openssh.com"
  @aes_key_len 32
  @aes_iv_len 12
  @aes_tag_len 16

  @type direction :: :client_to_server | :server_to_client
  @type state :: %{
          algorithm: binary(),
          key: binary(),
          iv: binary(),
          sequence: non_neg_integer()
        }

  @spec new(binary(), direction(), binary(), binary(), binary()) :: state()
  def new(@aes256_gcm, direction, shared_secret, exchange_hash, session_id) do
    {iv_letter, key_letter} =
      case direction do
        :client_to_server -> {?A, ?C}
        :server_to_client -> {?B, ?D}
      end

    %{
      algorithm: @aes256_gcm,
      key: Kex.derive_key(shared_secret, exchange_hash, session_id, key_letter, @aes_key_len),
      iv: Kex.derive_key(shared_secret, exchange_hash, session_id, iv_letter, @aes_iv_len),
      sequence: 0
    }
  end

  @spec set_sequence(state(), non_neg_integer()) :: state()
  def set_sequence(state, sequence), do: %{state | sequence: sequence}

  @spec block_size(state()) :: pos_integer()
  def block_size(%{algorithm: @aes256_gcm}), do: 16

  @spec encrypt_packet(state(), Sftpd.SSH.Packet.aead_packet()) :: {iodata(), state()}
  def encrypt_packet(
        %{algorithm: @aes256_gcm} = state,
        %Sftpd.SSH.Packet.AEADPacket{packet_length: packet_length, plaintext: plaintext}
      ) do
    aad = <<packet_length::32>>
    iv = packet_iv(state.iv, state.sequence)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        state.key,
        iv,
        plaintext,
        aad,
        @aes_tag_len,
        true
      )

    {[aad, ciphertext, tag], increment_sequence(state)}
  end

  @spec decrypt_packet(state(), binary()) ::
          {:ok, binary(), binary(), state()} | :more | {:error, :bad_packet}
  def decrypt_packet(%{algorithm: @aes256_gcm} = state, buffer) do
    with <<packet_length::32, rest::binary>> when byte_size(rest) >= packet_length + @aes_tag_len <-
           buffer do
      <<ciphertext::binary-size(^packet_length), tag::binary-size(@aes_tag_len), rest::binary>> =
        rest

      aad = <<packet_length::32>>
      iv = packet_iv(state.iv, state.sequence)

      case :crypto.crypto_one_time_aead(:aes_256_gcm, state.key, iv, ciphertext, aad, tag, false) do
        :error ->
          {:error, :bad_packet}

        plaintext ->
          {:ok, <<packet_length::32, plaintext::binary>>, rest, increment_sequence(state)}
      end
    else
      _ -> :more
    end
  end

  @spec decrypt_packet_payload(state(), binary()) ::
          {:ok, binary(), binary(), state()} | :more | {:error, :bad_packet}
  def decrypt_packet_payload(%{algorithm: @aes256_gcm} = state, buffer) do
    with <<packet_length::32, rest::binary>> when byte_size(rest) >= packet_length + @aes_tag_len <-
           buffer do
      <<ciphertext::binary-size(^packet_length), tag::binary-size(@aes_tag_len), rest::binary>> =
        rest

      aad = <<packet_length::32>>
      iv = packet_iv(state.iv, state.sequence)

      case :crypto.crypto_one_time_aead(:aes_256_gcm, state.key, iv, ciphertext, aad, tag, false) do
        :error ->
          {:error, :bad_packet}

        plaintext ->
          case Packet.decode_decrypted(packet_length, plaintext) do
            {:ok, payload} -> {:ok, payload, rest, increment_sequence(state)}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      _ -> :more
    end
  end

  @spec decrypt_packet_payload(state(), non_neg_integer(), binary()) ::
          {:ok, binary(), state()} | {:error, :bad_packet}
  def decrypt_packet_payload(%{algorithm: @aes256_gcm} = state, packet_length, encrypted_body)
      when byte_size(encrypted_body) == packet_length + @aes_tag_len do
    <<ciphertext::binary-size(^packet_length), tag::binary-size(@aes_tag_len)>> = encrypted_body
    aad = <<packet_length::32>>
    iv = packet_iv(state.iv, state.sequence)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, state.key, iv, ciphertext, aad, tag, false) do
      :error ->
        {:error, :bad_packet}

      plaintext ->
        case Packet.decode_decrypted(packet_length, plaintext) do
          {:ok, payload} -> {:ok, payload, increment_sequence(state)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def decrypt_packet_payload(%{algorithm: @aes256_gcm}, _packet_length, _encrypted_body) do
    {:error, :bad_packet}
  end

  defp packet_iv(<<fixed::32, counter::64>>, sequence) do
    <<fixed::32, counter + sequence::64>>
  end

  defp increment_sequence(%{sequence: sequence} = state) do
    %{state | sequence: rem(sequence + 1, 0x1_0000_0000)}
  end
end
