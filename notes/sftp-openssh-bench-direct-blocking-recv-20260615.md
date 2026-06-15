# OpenSSH SFTP benchmark after direct blocking encrypted receive

Commit under test before commit: working tree based on `9c1edcc`
(`Record SFTP profile after offset framing`).

Change under test: when the encrypted connection buffer is empty, the blocking
receive path reads exactly one SSH encrypted packet by length/body instead of
first reading all currently available socket bytes into the Elixir buffer. The
nonblocking SFTP drain path still uses the buffered receive path for request
coalescing.

Raw log:

- `notes/sftp-openssh-bench-direct-blocking-recv-full-20260615T111538Z.txt`

Baseline used for current-condition comparison:

- `notes/sftp-openssh-bench-redo-after-busy-10x-20260615.md`

All runs use official OpenSSH `sftp`, pure-Elixir transport, memory benchmark
backend, and `aes256-gcm@openssh.com`.

## Results

| Size | Direction | Median MiB/s | Current redo MiB/s | Delta MiB/s | Prior best MiB/s | Delta vs prior best |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: |
| 64 MiB | upload | 322.55 | 304.05 | +18.50 | 327.35 | -4.80 |
| 64 MiB | download | 314.90 | 297.25 | +17.65 | 316.25 | -1.35 |
| 1 GiB | upload | 603.25 | 592.55 | +10.70 | 607.55 | -4.30 |
| 1 GiB | download | 627.05 | 613.00 | +14.05 | 643.15 | -16.10 |
| 10 GiB | upload | 638.40 | 619.25 | +19.15 | 643.45 | -5.05 |
| 10 GiB | download | 682.60 | 660.00 | +22.60 | 689.35 | -6.75 |

## Read

This is a clean 10-sample current-condition win across every tested size and
direction. It does not exceed the earlier best committed benchmark, so future
comparisons should keep both numbers in view.
