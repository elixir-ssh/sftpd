# OpenSSH SFTP eprof Profile

Commit: `b36c459 Record OpenSSH benchmark rerun`

Raw log: `notes/sftp-eprof-profile-current-20260615T022312Z.txt`

Context:

- Transport: pure Elixir SSH/SFTP
- Backend: benchmark memory backend
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- SFTP client flags: `-B 262080 -R 64`
- Profiler: OTP `:eprof`, connection process only

## Top Findings

- Upload is dominated by receive-side TCP port control plus AEAD decrypt/encrypt work.
- Download is dominated by AEAD work, TCP `port_command` send cost, receive-side port control, and response iodata splitting.
- The 64MiB profiles include compile/load noise, so 1GiB and 10GiB are the better optimization targets.

| Size | Direction | Throughput under eprof | Main costs |
| --- | --- | ---: | --- |
| 64MiB | upload | see raw log | `port_control` 25.63%, AEAD NIF 20.13%, decrypt wrapper 4.65%, `split_binary` 2.69% |
| 64MiB | download | see raw log | AEAD NIF 26.69%, `port_control` 15.93%, `port_command` 13.65%, decrypt wrapper 4.27% |
| 1GiB | upload | see raw log | `port_control` 25.40%, AEAD NIF 21.26%, decrypt wrapper 5.02%, `split_binary` 2.81% |
| 1GiB | download | 624.0 MiB/s | AEAD NIF 29.64%, `port_command` 16.50%, `port_control` 14.05%, decrypt wrapper 5.12% |
| 10GiB | upload | see raw log | `port_control` 25.53%, AEAD NIF 21.26%, decrypt wrapper 4.94%, `split_binary` 2.82% |
| 10GiB | download | 670.7 MiB/s | AEAD NIF 30.55%, `port_command` 16.76%, `port_control` 13.00%, decrypt wrapper 5.10% |

## Next Candidate

The upload path still does a two-step blocking read when no encrypted bytes are buffered: one `gen_tcp.recv/3` for the 4-byte packet length and another for the encrypted body. OpenSSH upload produces many encrypted packets, so this shows up as receive-side `port_control` in every upload profile.

Try changing the empty-buffer encrypted receive path to pull available TCP data into the existing encrypted buffer first, then parse packets from that buffer. Keep the same SSH packet sizes and encryption; this is only socket buffering strategy.
