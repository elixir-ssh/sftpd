# OpenSSH SFTP Benchmark Rerun After Busy Host

Commit: `3efc5a8 Batch AEAD padding generation for SFTP responses`

Raw log: `notes/sftp-openssh-bench-rerun-20260615T015201Z.txt`

Context:

- Transport: pure Elixir SSH/SFTP
- Backend: benchmark memory backend
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- SFTP client flags: `-B 262080 -R 64`
- Samples: 10 per size
- Server lifecycle: restarted for every sample

| Size | Direction | Median MiB/s | Mean MiB/s | Min | Max |
| --- | --- | ---: | ---: | ---: | ---: |
| 64MiB | upload | 348.9 | 375.0 | 329.0 | 436.3 |
| 64MiB | download | 331.9 | 318.9 | 200.6 | 341.5 |
| 1GiB | upload | 589.3 | 589.9 | 563.8 | 605.7 |
| 1GiB | download | 617.9 | 618.6 | 610.2 | 631.7 |
| 10GiB | upload | 618.6 | 620.6 | 613.5 | 643.9 |
| 10GiB | download | 657.0 | 658.5 | 650.8 | 678.5 |

Notes:

- The 10GiB samples are tight except for one faster outlier, so the median is a useful baseline.
- The 64MiB run remains noisy, especially one download sample at 200.6 MiB/s, so use the larger sizes for optimization decisions.
- Compared with the prior batched-padding note, the 1GiB and 10GiB medians are lower on this rerun, so the earlier set was not a stable target for evaluating small follow-up changes.
