# Current Pure SSH/SFTP Eprof Rerun

Commit under test before the hot-path logging edit: `bf853fc Receive blocking encrypted packets directly`

Raw output: `notes/sftp-eprof-profile-current-64m-1g-10g-rerun-20260615T115630Z.txt`

Command shape:

```sh
MIX_ENV=test nix develop -c mix run scripts/sftp_profile.exs \
  --profiler eprof \
  --direction <upload|download> \
  --size <64MiB|1GiB|10GiB> \
  --chunk 262080 \
  --requests 64 \
  --port 29223
```

The profile uses the official OpenSSH `sftp` client with
`aes256-gcm@openssh.com`.

## Throughput

| Size | Direction | MiB/s | Elapsed s |
|---:|:---|---:|---:|
| 64MiB | upload | 276.4 | 0.232 |
| 64MiB | download | 227.8 | 0.281 |
| 1GiB | upload | 537.4 | 1.906 |
| 1GiB | download | 598.3 | 1.712 |
| 10GiB | upload | 569.7 | 17.975 |
| 10GiB | download | 668.0 | 15.330 |

## Top Hotspots

| Size | Direction | Top rows |
|---:|:---|:---|
| 64MiB | upload | `erts_internal:port_control/3` 24.69%, `crypto:aead_cipher_nif/7` 21.05%, `Sftpd.SSH.Cipher.decrypt_packet_payload/2` 4.50%, `erlang:split_binary/2` 2.70% |
| 64MiB | download | `crypto:aead_cipher_nif/7` 26.54%, `erts_internal:port_control/3` 15.82%, `erts_internal:port_command/3` 14.38%, `Sftpd.SSH.Cipher.decrypt_packet_payload/2` 4.20% |
| 1GiB | upload | `erts_internal:port_control/3` 26.45%, `crypto:aead_cipher_nif/7` 22.09%, `Sftpd.SSH.Cipher.decrypt_packet_payload/2` 4.69%, `erlang:split_binary/2` 2.64% |
| 1GiB | download | `crypto:aead_cipher_nif/7` 30.49%, `erts_internal:port_command/3` 16.39%, `erts_internal:port_control/3` 13.56%, `Sftpd.SSH.Cipher.decrypt_packet_payload/2` 5.12% |
| 10GiB | upload | `erts_internal:port_control/3` 26.27%, `crypto:aead_cipher_nif/7` 22.02%, `Sftpd.SSH.Cipher.decrypt_packet_payload/2` 4.76%, `Sftpd.SSH.Server.recv_encrypted_packet/3` 2.72% |
| 10GiB | download | `crypto:aead_cipher_nif/7` 31.13%, `erts_internal:port_command/3` 16.80%, `erts_internal:port_control/3` 13.32%, `Sftpd.SSH.Cipher.decrypt_packet_payload/2` 5.11% |

## Read

Across all three sizes, upload remains dominated by socket receive port control
and AES-GCM decrypt. Download remains dominated by AES-GCM encrypt plus socket
send port command. The remaining Elixir-level costs are small, but per-packet
debug logging still appears in the 10GiB upload profile through Logger gating
work; removing channel-data debug logs is a low-risk hot-path cleanup to test.
