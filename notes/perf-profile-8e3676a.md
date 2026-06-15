# Perf Profile Note

Tested commit:
- SHA: `8e3676a8ae9b9a538214fb349bc072bdbcf45ace`
- Message: `Reject OTP root mutation paths`

Profile run:
- `nix develop -c mix run -r test/support/ssh_keys.ex -e '...OpenSSH sftp -vvv get...'`
- OpenSSH `sftp` client against `transport: :elixir`
- Memory backend only
- 64 MiB download
- Cipher: `aes256-gcm@openssh.com`
- Client tuning: `-B 262080 -R 64`
- Server logger level lowered to `:info` so the profile reflects the transfer path instead of debug logging

Profile summary:
- `erts_internal:port_command/3` was the biggest cost at `23.98%`
- `crypto:aead_cipher_nif/7` was next at `17.54%`
- `erts_internal:port_control/3` took `11.05%`
- `Sftpd.SSH.Cipher.decrypt_packet_payload/3` took `1.59%`
- `Sftpd.SSH.Server.flush_sftp_responses/4` took `1.55%`
- `Sftpd.SSH.SFTPBridge.split_iodata/3` took `1.30%`
- `erlang:split_binary/2` took `1.32%`
- `Sftpd.SSH.SFTPBridge.response_payloads/2` and `Sftpd.SSH.Server.send_encrypted_payloads/3` were both present but below the crypto and port-call costs
- `Sftpd.Backends.Memory.read_content_at/3` was negligible at `0.03%`

What this says:
- The memory backend is not the bottleneck on this path.
- The hot path is still dominated by packet emission, AEAD work, and the port boundary.
- The next wins are in reducing packet count / `port_command` churn and shaving work from SFTP payload splitting and encryption, not in the memory backend read path.
