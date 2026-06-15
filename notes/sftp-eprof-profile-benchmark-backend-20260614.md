# OpenSSH SFTP Eprof Profile, Benchmark Backend

Tested commit: `0f29e35822ca75914393ba2632d9dd61c4f68e10` (`Carry SFTP response byte totals`)

Raw output: `notes/sftp-eprof-profile-benchmark-backend-20260614T232234Z.txt`

Shape: pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`,
`-B 262080`, `-R 64`, one run each for 64MiB, 1GiB, and 10GiB upload/download.
The eprof trace targets the accepted pure SSH connection process.

The profile script uses `Sftpd.Backends.Benchmark` so download profiling matches
the benchmark workload and does not spend most time allocating zero-filled
backend chunks.

## Throughput Under Eprof

Eprof adds overhead, so these are profile context numbers, not benchmark
medians.

| size | upload | download |
|---:|---:|---:|
| 64MiB | 369.5 MiB/s | 264.9 MiB/s |
| 1GiB | 547.5 MiB/s | 541.6 MiB/s |
| 10GiB | 556.9 MiB/s | 584.1 MiB/s |

## 10GiB Hot Spots

Upload:

| function | time share |
|---|---:|
| `erts_internal:port_control/3` | 28.19% |
| `crypto:aead_cipher_nif/7` | 20.19% |
| `erlang:split_binary/2` | 2.50% |
| `erts_internal:port_command/3` | 2.02% |
| `Sftpd.SSH.Server.drain_more_buffered_sftp_data/7` | 1.85% |
| `Sftpd.SSH.Server.recv_buffered_encrypted_payload/1` | 1.66% |

Download:

| function | time share |
|---|---:|
| `crypto:aead_cipher_nif/7` | 22.19% |
| `erts_internal:port_control/3` | 18.46% |
| `erts_internal:port_command/3` | 18.01% |
| `Sftpd.SSH.Cipher.decrypt_packet_payload/2` | 2.93% |
| `erlang:split_binary/2` | 2.51% |
| `Sftpd.SSH.Packet.decode_decrypted/2` | 1.41% |
| `Sftpd.SSH.Server.recv_buffered_encrypted_payload/1` | 1.41% |
| `Sftpd.SSH.SFTPBridge.split_iodata/3` | 1.27% |

## Candidate Tried

Tried a DATA-specific `payloads_for_window/2` path so full DATA responses used
the existing header/data pair splitter instead of the generic iodata splitter.
Focused bridge tests passed, but the 10GiB download profile regressed to
`571.1 MiB/s` and `Sftpd.SSH.SFTPBridge.split_iodata/3` remained at `1.27%`.

Conclusion: do not keep that candidate. The next likely wins are reducing
socket port calls, reducing receive-loop fragmentation overhead, or reducing
per-packet AEAD wrapper work. Generic iodata splitting is not currently a large
enough standalone target.
