# Pure transport eprof profile redo

Commit tested: `47bd881 Fast-path fragmented SFTP write decode`

Raw output: `notes/sftp-eprof-profile-redo-baseline-64m-1g-10g-20260615T130319Z.txt`

Command shape:

```sh
for size in 67108864 1073741824 10737418240; do
  for direction in upload download; do
    MIX_ENV=test nix develop -c mix run scripts/sftp_profile.exs \
      --profiler eprof \
      --size "$size" \
      --direction "$direction" \
      --chunk 262080 \
      --requests 64 \
      --port "$port"
  done
done
```

The profile uses the official OpenSSH `sftp` client with
`aes256-gcm@openssh.com`, `-B 262080`, and `-R 64`. Eprof targets the accepted
pure SSH connection process. Throughput under eprof is profiling context, not a
benchmark result.

## Throughput Under Eprof

| Size | Direction | Throughput MiB/s |
| ---: | :--- | ---: |
| 64MiB | upload | 273.2 |
| 64MiB | download | 236.3 |
| 1GiB | upload | 538.0 |
| 1GiB | download | 611.1 |
| 10GiB | upload | 566.8 |
| 10GiB | download | 673.6 |

## 10GiB Upload Top Costs

| Function | Percent |
| :--- | ---: |
| `erts_internal:port_control/3` | 26.89 |
| `crypto:aead_cipher_nif/7` | 22.87 |
| `Sftpd.SSH.Cipher.decrypt_packet_payload/2` | 4.76 |
| `erlang:split_binary/2` | 2.63 |
| `Sftpd.SSH.Server.recv_encrypted_packet/3` | 2.52 |
| `Sftpd.SSH.Server.drain_more_buffered_sftp_data/7` | 2.07 |
| `erts_internal:port_command/3` | 1.91 |
| `prim_inet:recv0/3` | 1.81 |

## 10GiB Download Top Costs

| Function | Percent |
| :--- | ---: |
| `crypto:aead_cipher_nif/7` | 31.05 |
| `erts_internal:port_command/3` | 16.94 |
| `erts_internal:port_control/3` | 13.30 |
| `Sftpd.SSH.Cipher.decrypt_packet_payload/2` | 5.11 |
| `erlang:split_binary/2` | 3.14 |
| `crypto:crypto_one_time_aead/7` | 2.54 |
| `Sftpd.SSH.Server.recv_buffered_encrypted_payload/1` | 2.02 |
| `Sftpd.SSH.Packet.decode_decrypted/2` | 2.00 |
| `Sftpd.SSH.Server.drain_more_buffered_sftp_data/7` | 1.71 |
| `Sftpd.SSH.SFTPBridge.split_iodata/3` | 1.14 |

## Follow-Up Evidence

Two candidates were tried from this profile and reverted:

- Binary DATA window split fast path improved 64MiB but regressed 10GiB
  download. Gate raw output:
  `notes/sftp-openssh-bench-binary-data-window-split-fastpath-gate-20260615T130621Z.txt`.
- Increasing the SFTP drain probe timeout from 1ms to 2ms improved 10GiB
  download by `+18.85 MiB/s` in a 3x gate, but regressed 64MiB and 1GiB. Gate
  raw output: `notes/sftp-openssh-bench-drain-probe-2ms-gate-20260615T130916Z.txt`.
- Switching to 2ms after 1024 client window-adjust packets won the 3x gate but
  failed the full 10x matrix. Full-run medians were `64MiB put +7.50/get -5.65`,
  `1GiB put -7.05/get -5.25`, and `10GiB put +1.50/get -1.50` MiB/s versus
  the redo baseline. Full raw output:
  `notes/sftp-openssh-bench-window-adjust-adaptive-drain-full-20260615T132140Z.txt`.
- Special-casing response accumulator reversal for empty and single-response
  lists failed its 3x gate. Medians were `64MiB put -1.55/get -1.90`,
  `1GiB put -11.00/get -2.50`, and `10GiB put +2.35/get +0.15` MiB/s versus
  the redo baseline. Gate raw output:
  `notes/sftp-openssh-bench-response-reverse-fastpath-gate-20260615T133036Z.txt`.

The 2ms drain result suggests adaptive response coalescing may be worth a
targeted experiment, but a global timeout change is not acceptable across the
64MiB, 1GiB, and 10GiB matrix.
