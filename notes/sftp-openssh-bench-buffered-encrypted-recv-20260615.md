# OpenSSH SFTP Benchmark: Buffered Encrypted Receive

Change under test: when no encrypted bytes are buffered, read available TCP data with one `recv(0)` call and parse SSH packets from the connection buffer before falling back to exact missing-byte reads.

Baseline commit: `b36c459 Record OpenSSH benchmark rerun`

Candidate base commit: `768c62b Record current OpenSSH SFTP profile`

Raw log: `notes/sftp-openssh-bench-buffered-encrypted-recv-20260615T022806Z.txt`

Context:

- Transport: pure Elixir SSH/SFTP
- Backend: benchmark memory backend
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- SFTP client flags: `-B 262080 -R 64`
- Samples: 10 per size
- Server lifecycle: restarted for every sample

| Size | Direction | Baseline median MiB/s | Buffered receive median MiB/s | Delta MiB/s |
| --- | --- | ---: | ---: | ---: |
| 64MiB | upload | 348.9 | 371.0 | +22.1 |
| 64MiB | download | 331.9 | 333.7 | +1.8 |
| 1GiB | upload | 589.3 | 614.0 | +24.7 |
| 1GiB | download | 617.9 | 648.5 | +30.7 |
| 10GiB | upload | 618.6 | 626.8 | +8.1 |
| 10GiB | download | 657.0 | 665.6 | +8.7 |

Notes:

- This keeps SSH packet sizes and encryption unchanged; it only changes how encrypted bytes are read from the socket into the existing connection buffer.
- The win lines up with the eprof profile, where upload was spending roughly a quarter of measured time in receive-side TCP port control.
- Download also improves because OpenSSH responses and window messages can arrive buffered during drain probes instead of forcing more exact-length reads.
