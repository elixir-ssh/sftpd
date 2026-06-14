# OpenSSH SFTP 10x benchmark, pure transport

Date: 2026-06-14T18:55:02Z

Branch: `mjc/pure-elixir-ssh-sftp`

Commit tested: `52ae2563526db9af6d750309681f50ae88cbf990`

Commit message: `Skip EOF close checks on normal SFTP flushes`

Raw output: `notes/sftp-openssh-bench-10x-20260614T123251.txt`

Important caveat: the worktree was dirty during this run:

- `lib/sftpd/ssh/server.ex`: inline SFTP window-adjust payload construction under evaluation.
- `scripts/sftp_perf_bench.exs`: OpenSSH benchmark script updates for `--transport elixir`, `IdentitiesOnly=yes`, quiet logging, and `Sftpd.Backends.Benchmark`.

The benchmark used the OpenSSH `sftp` client with the pure-Elixir transport, memory-like benchmark backend, `aes256-gcm@openssh.com`, `chunk=262080`, `requests=64`, and a fresh server/port per iteration.

## Results

Throughput is MiB/s.

| Size | Operation | n | Min | Median | Mean | Max | Median time |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 MiB | upload | 10 | 101.0 | 236.5 | 228.3 | 356.6 | 0.271s |
| 64 MiB | download | 10 | 68.1 | 117.2 | 127.6 | 195.7 | 0.549s |
| 1 GiB | upload | 10 | 149.7 | 308.4 | 296.4 | 422.3 | 3.324s |
| 1 GiB | download | 10 | 82.1 | 235.5 | 238.3 | 307.2 | 4.349s |
| 10 GiB | upload | 10 | 153.9 | 183.1 | 218.3 | 552.0 | 55.967s |
| 10 GiB | download | 10 | 108.2 | 149.8 | 203.7 | 466.5 | 68.376s |

## Per-iteration throughput

| Size | Operation | Values |
| --- | --- | --- |
| 64 MiB | upload | 248.9, 232.9, 240.0, 294.6, 325.2, 207.2, 119.3, 157.0, 356.6, 101.0 |
| 64 MiB | download | 159.8, 165.5, 171.2, 195.7, 104.9, 104.1, 72.6, 125.9, 108.5, 68.1 |
| 1 GiB | upload | 201.3, 149.7, 422.3, 356.1, 368.1, 317.9, 298.8, 248.2, 280.2, 321.8 |
| 1 GiB | download | 204.0, 307.2, 288.9, 230.8, 301.3, 225.5, 231.7, 239.3, 82.1, 272.0 |
| 10 GiB | upload | 197.5, 180.1, 178.8, 197.9, 186.0, 220.7, 155.2, 160.4, 153.9, 552.0 |
| 10 GiB | download | 216.0, 138.2, 140.0, 147.6, 108.2, 151.9, 116.0, 164.6, 387.9, 466.5 |

## Notes

- The discarded prior run was interrupted because an unrelated high-CPU task was active.
- This rerun still shows substantial host/load variance. The last 10 GiB iteration was a high outlier for both upload and download.
- Median is the most useful headline number here. By median, 10 GiB download is materially slower than 10 GiB upload.
- Because each iteration starts a fresh server on a fresh port, the slow 10 GiB downloads do not appear to be caused by a single long-lived server process carrying degraded state between runs.
- Next profiling target: pure-transport download path at 10 GiB, especially SFTP read response production, SSH packet encryption/framing, socket send batching, and channel/window backpressure behavior.
