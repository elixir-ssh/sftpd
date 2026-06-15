# Offset-based binary channel-data payloads

Commit under test: `99a5d3f` (`Tune pure SSH connection GC`) plus the
candidate that frames binary SFTP DATA responses by offset into the original
binary instead of repeatedly splitting the remaining binary tail.

Raw data:

- Gate: `notes/sftp-openssh-bench-offset-binary-channel-gate-20260615T094422Z.txt`
- Full matrix: `notes/sftp-openssh-bench-offset-binary-channel-full-20260615T094622Z.txt`

Benchmark shape:

- Official OpenSSH `sftp`
- Pure-Elixir transport
- AES256-GCM
- Memory benchmark backend
- `--chunk 262080 --requests 64`
- Fresh server for each sample
- 10 samples each for 64MiB, 1GiB, and 10GiB

Clean baseline medians from `notes/sftp-openssh-bench-redo-current-clean-20260615.md`:

| Size | Upload | Download |
| --- | ---: | ---: |
| 64MiB | 339.05 MiB/s | 319.35 MiB/s |
| 1GiB | 603.90 MiB/s | 627.55 MiB/s |
| 10GiB | 630.55 MiB/s | 684.45 MiB/s |

Candidate full-matrix medians:

| Size | Upload | Delta | Download | Delta |
| --- | ---: | ---: | ---: | ---: |
| 64MiB | 327.35 MiB/s | -11.70 | 316.25 MiB/s | -3.10 |
| 1GiB | 607.55 MiB/s | +3.65 | 643.15 MiB/s | +15.60 |
| 10GiB | 643.45 MiB/s | +12.90 | 689.35 MiB/s | +4.90 |

This is a large-transfer win and a small-transfer regression. Keep it because
the current optimization target is sustained OpenSSH transfer throughput, but
do not use this as evidence for many-small-files performance.
