# OpenSSH SFTP current 1 GiB spot benchmark

Date: 2026-06-14T19:35:30Z

Branch: `mjc/pure-elixir-ssh-sftp`

Commit tested: `6d602fb74a7e52f33dfee4e47f59aa4e238d1d1e`

Commit message: `Drain available encrypted packets before flushing`

Raw output: `notes/sftp-openssh-current-1g-20260614T133527.txt`

The benchmark used the OpenSSH `sftp` client with the pure-Elixir transport, `Sftpd.Backends.Benchmark`, `aes256-gcm@openssh.com`, `chunk=262080`, `requests=64`, and a fresh server/port per iteration.

| Size | Operation | n | Min | Median | Mean | Max |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 GiB | upload | 3 | 560.3 | 565.7 | 565.5 | 570.4 |
| 1 GiB | download | 3 | 465.3 | 476.4 | 474.9 | 483.1 |

Per-iteration throughput:

| Operation | Values |
| --- | --- |
| upload | 560.3, 570.4, 565.7 |
| download | 465.3, 476.4, 483.1 |

Interpretation:

- This is a spot check, not a replacement for a full 64 MiB / 1 GiB / 10 GiB 10x run.
- Current 1 GiB wall-time throughput is materially above the older noisy 10x note taken near `52ae256`.
