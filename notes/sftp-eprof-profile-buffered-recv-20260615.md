# OpenSSH SFTP eprof Profile After Buffered Receive

Commit: `0bb335c Buffer encrypted receive packets`

Raw log: `notes/sftp-eprof-profile-buffered-recv-20260615T023718Z.txt`

Context:

- Transport: pure Elixir SSH/SFTP
- Backend: benchmark memory backend
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- SFTP client flags: `-B 262080 -R 64`
- Profiler: OTP `:eprof`, connection process only

## Top Findings

- The buffered receive change improved the benchmark, but upload remains dominated by receive-side TCP port control and AEAD work.
- Download still spends most time in AEAD, TCP send, decrypt framing, binary splitting, and response iodata splitting.
- `port_control` call counts dropped on download compared with the previous profile, but the remaining cost is still significant.

| Size | Direction | Throughput under eprof | Main costs |
| --- | --- | ---: | --- |
| 64MiB | upload | 349.3 MiB/s | `port_control` 24.59%, AEAD NIF 21.01%, decrypt wrapper 4.67%, `split_binary` 2.76% |
| 64MiB | download | 238.5 MiB/s | AEAD NIF 27.30%, `port_command` 15.15%, `port_control` 13.77%, decrypt wrapper 4.80% |
| 1GiB | upload | 594.3 MiB/s | `port_control` 24.03%, AEAD NIF 21.68%, decrypt wrapper 5.17%, `split_binary` 2.70% |
| 1GiB | download | 672.0 MiB/s | AEAD NIF 30.93%, `port_command` 15.03%, `port_control` 11.97%, decrypt wrapper 5.70% |
| 10GiB | upload | 589.0 MiB/s | `port_control` 24.98%, AEAD NIF 21.75%, decrypt wrapper 5.07%, `split_binary` 2.81% |
| 10GiB | download | 662.6 MiB/s | AEAD NIF 30.27%, `port_command` 16.56%, `port_control` 12.76%, decrypt wrapper 5.41% |

## Next Candidates

- Reduce `Sftpd.SSH.Cipher.decrypt_packet_payload/2` and `Packet.decode_decrypted/2` overhead without changing packet validation.
- Reduce `Sftpd.SSH.SFTPBridge.split_iodata/3` work on download, especially repeated generic iodata splitting for data packets.
- Further reduce receive probe calls only if a new approach avoids the regressions seen with longer drain probe timeouts.
