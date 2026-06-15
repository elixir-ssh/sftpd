# OpenSSH SFTP eprof profile after 8MiB window-adjust batching

- Date: 2026-06-15
- Commit: `d417046` (`Batch SSH window adjustments at 8MiB`)
- Raw artifact: `notes/sftp-eprof-profile-window-adjust-8m-20260615T000939Z.txt`
- Transport: `transport: :elixir`
- Backend: `Sftpd.Backends.Benchmark`
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- OpenSSH request shape: `-B 262080 -R 64`
- Profiler: `:eprof`, targeted at the accepted pure SSH connection process

## Throughput Under Eprof

Eprof adds overhead, so these numbers are profile context, not benchmark
medians.

| Size | Upload MiB/s | Download MiB/s |
| ---: | ---: | ---: |
| 64MiB | 331.1 | 278.0 |
| 1GiB | 612.9 | 558.8 |
| 10GiB | 587.3 | 588.8 |

## 10GiB Hot Spots

Upload:

| function | time share |
| --- | ---: |
| `erts_internal:port_control/3` | 27.91% |
| `crypto:aead_cipher_nif/7` | 20.40% |
| `Sftpd.SSH.Cipher.decrypt_packet_payload/2` | 4.22% |
| `erlang:split_binary/2` | 2.61% |
| `erts_internal:port_command/3` | 1.65% |
| `Sftpd.SSH.Packet.decode_decrypted/2` | 1.56% |
| `Sftpd.SSH.Cipher.packet_iv/2` | 1.10% |

Download:

| function | time share |
| --- | ---: |
| `crypto:aead_cipher_nif/7` | 22.36% |
| `erts_internal:port_control/3` | 18.38% |
| `erts_internal:port_command/3` | 16.88% |
| `Sftpd.SSH.Cipher.decrypt_packet_payload/2` | 3.05% |
| `erlang:split_binary/2` | 2.57% |
| `crypto:strong_rand_bytes_nif/1` | 1.80% |
| `Sftpd.SSH.Packet.decode_decrypted/2` | 1.48% |
| `Sftpd.SSH.SFTPBridge.split_iodata/3` | 1.30% |
| `Sftpd.SSH.Cipher.packet_iv/2` | 1.19% |

## Read

The 8MiB window-adjust change reduced encrypted upload-side control traffic
enough to improve benchmark medians, but the profile is still fundamentally
socket-port and AES-GCM bound. The next narrow candidate is avoiding repeated
AES-GCM IV binary pattern matching in `Sftpd.SSH.Cipher.packet_iv/2`; it is only
about 1.1-1.2% of eprof time, so it must be benchmarked before keeping.
