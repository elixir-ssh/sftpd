# OpenSSH SFTP benchmark with 1ms drain coalescing

- Date: 2026-06-15
- Tested commit: `f23936e` (`Record OpenSSH SFTP benchmark redo`) plus local
  candidate changes
- Candidate: use a 1ms encrypted-packet probe in the SFTP drain path so
  pipelined OpenSSH requests can be coalesced before flushing responses
- Raw benchmark: `notes/sftp-openssh-bench-drain-coalesce-1ms-redo-20260615T010610Z.txt`
- Raw eprof: `notes/sftp-eprof-profile-drain-coalesce-1ms-20260615T005038Z.txt`
- Transport: `transport: :elixir`
- Backend: `Sftpd.Backends.Benchmark`
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- OpenSSH request shape: `-B 262080 -R 64`
- Server lifecycle: each script invocation starts and stops a fresh Sftpd server

The change does not alter SSH packet sizes, SFTP request sizes, or encryption.
It gives the server a very small receive-side coalescing window before flushing
SFTP responses, which lets the official OpenSSH client keep more requests in a
single encrypted response batch.

## 10-run summary

| Size | Direction | Runs | Median MiB/s | Average MiB/s | Min MiB/s | Max MiB/s |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: |
| 64MiB | upload | 10 | 341.5 | 356.5 | 328.1 | 408.2 |
| 64MiB | download | 10 | 320.5 | 323.1 | 314.4 | 341.5 |
| 1GiB | upload | 10 | 590.0 | 591.8 | 574.0 | 609.8 |
| 1GiB | download | 10 | 620.7 | 620.0 | 611.9 | 630.9 |
| 10GiB | upload | 10 | 617.4 | 618.7 | 611.9 | 637.2 |
| 10GiB | download | 10 | 659.5 | 662.3 | 655.9 | 682.1 |

## Comparison with previous clean redo

| Size | Direction | Previous redo MiB/s | 1ms coalesce MiB/s | Delta |
| ---: | :--- | ---: | ---: | ---: |
| 64MiB | upload | 376.6 | 341.5 | -35.1 |
| 64MiB | download | 347.7 | 320.5 | -27.2 |
| 1GiB | upload | 588.9 | 590.0 | +1.1 |
| 1GiB | download | 555.0 | 620.7 | +65.7 |
| 10GiB | upload | 607.4 | 617.4 | +10.0 |
| 10GiB | download | 581.6 | 659.5 | +77.9 |

## Eprof gate

| Direction | Baseline MiB/s | Candidate MiB/s |
| :--- | ---: | ---: |
| 10GiB upload | 587.3 | 590.6 |
| 10GiB download | 588.8 | 680.2 |

The eprof profile showed the large download improvement came from substantially
fewer socket port calls and encrypted sends. The tradeoff is worse 64MiB latency
workloads, where the fixed 1ms probe cost is visible.
