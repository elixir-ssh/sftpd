# Current Pure SSH/SFTP eprof Profile

- Commit: `156db63`
- Raw output: `notes/sftp-eprof-profile-current-64m-1g-10g-156db63-20260615T135933Z.txt`
- Client: OpenSSH `sftp` via `scripts/sftp_profile.exs`
- Transport: pure Elixir SSH/SFTP
- Backend: `Sftpd.Backends.Benchmark` synthetic backend
- Cipher: `aes256-gcm@openssh.com`
- Shape: upload and download at 64MiB, 1GiB, 10GiB

| Direction | Size | Throughput MiB/s | Elapsed s | Top time functions |
| --- | ---: | ---: | ---: | --- |
| upload | 64MiB | 268.4 | 0.238 | `erts_internal:port_control/3` 26.28%<br>`crypto:aead_cipher_nif/7` 21.45%<br>`'Elixir.Sftpd.SSH.Cipher':decrypt_packet_payload/2` 4.41%<br>`erts_internal:prepare_loading/2` 3.36%<br>`erlang:split_binary/2` 2.53%<br>`'Elixir.Sftpd.SSH.Server':recv_encrypted_packet/3` 2.47%<br>`erts_internal:port_command/3` 2.05%<br>`'Elixir.Sftpd.SSH.Server':drain_more_buffered_sftp_data/7` 1.97% |
| upload | 1GiB | 533.4 | 1.920 | `erts_internal:port_control/3` 26.76%<br>`crypto:aead_cipher_nif/7` 22.52%<br>`'Elixir.Sftpd.SSH.Cipher':decrypt_packet_payload/2` 4.91%<br>`erlang:split_binary/2` 2.75%<br>`'Elixir.Sftpd.SSH.Server':recv_encrypted_packet/3` 2.41%<br>`'Elixir.Sftpd.SSH.Server':drain_more_buffered_sftp_data/7` 2.02%<br>`erts_internal:port_command/3` 1.94%<br>`'Elixir.Sftpd.SSH.Server':encrypted_loop/2` 1.83% |
| upload | 10GiB | 579.2 | 17.680 | `erts_internal:port_control/3` 26.38%<br>`crypto:aead_cipher_nif/7` 22.77%<br>`'Elixir.Sftpd.SSH.Cipher':decrypt_packet_payload/2` 4.86%<br>`erlang:split_binary/2` 2.73%<br>`'Elixir.Sftpd.SSH.Server':recv_encrypted_packet/3` 2.46%<br>`'Elixir.Sftpd.SSH.Server':drain_more_buffered_sftp_data/7` 1.99%<br>`'Elixir.Sftpd.SSH.Server':encrypted_loop/2` 1.89%<br>`erts_internal:port_command/3` 1.88% |
| download | 64MiB | 234.1 | 0.273 | `crypto:aead_cipher_nif/7` 27.68%<br>`erts_internal:port_control/3` 16.54%<br>`erts_internal:port_command/3` 12.33%<br>`erts_internal:prepare_loading/2` 5.68%<br>`'Elixir.Sftpd.SSH.Cipher':decrypt_packet_payload/2` 4.40%<br>`erlang:split_binary/2` 2.67%<br>`crypto:crypto_one_time_aead/7` 2.08%<br>`'Elixir.Sftpd.SSH.Server':recv_buffered_encrypted_payload/1` 1.86% |
| download | 1GiB | 636.7 | 1.608 | `crypto:aead_cipher_nif/7` 32.27%<br>`erts_internal:port_command/3` 15.00%<br>`erts_internal:port_control/3` 11.92%<br>`'Elixir.Sftpd.SSH.Cipher':decrypt_packet_payload/2` 5.37%<br>`erlang:split_binary/2` 3.31%<br>`crypto:crypto_one_time_aead/7` 2.65%<br>`'Elixir.Sftpd.SSH.Packet':decode_decrypted/2` 2.16%<br>`'Elixir.Sftpd.SSH.Server':recv_buffered_encrypted_payload/1` 2.10% |
| download | 10GiB | 723.4 | 14.155 | `crypto:aead_cipher_nif/7` 32.34%<br>`erts_internal:port_command/3` 15.18%<br>`erts_internal:port_control/3` 12.43%<br>`'Elixir.Sftpd.SSH.Cipher':decrypt_packet_payload/2` 5.30%<br>`erlang:split_binary/2` 3.24%<br>`crypto:crypto_one_time_aead/7` 2.61%<br>`'Elixir.Sftpd.SSH.Server':recv_buffered_encrypted_payload/1` 2.12%<br>`'Elixir.Sftpd.SSH.Packet':decode_decrypted/2` 2.09% |

## Notes

The sustained 10GiB download profile is dominated by AES-GCM NIF time plus socket port I/O. The next Elixir-side targets with measurable time are encrypted packet splitting/decode and SFTPBridge response splitting, but previous pattern-match split and response-size threading candidates regressed in OpenSSH gates.

The profile script currently uses `Sftpd.Backends.Benchmark`, not `Sftpd.Backends.Memory`, so transport hot-path conclusions are valid but memory-backend allocation/copy costs are not represented in this profile.
