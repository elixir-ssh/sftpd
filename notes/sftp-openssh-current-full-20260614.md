# Current OpenSSH Full Benchmark

Tested commit: `1644e0c` (`Skip redundant drain check after window adjusts`)

Raw output: `notes/sftp-openssh-bench-current-full-20260614T211820Z.txt`

Shape: pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`, `-B 262080`, `-R 64`, 10 runs each for 64MiB, 1GiB, and 10GiB. The benchmark script restarted the SFTP server for every run.

## Current Medians

Throughput in MiB/s.

| size | put median | get median | put mean | get mean |
|---:|---:|---:|---:|---:|
| 64MiB | 381.9 | 359.2 | 392.9 | 353.4 |
| 1GiB | 585.6 | 554.9 | 589.1 | 552.5 |
| 10GiB | 599.2 | 579.8 | 599.1 | 580.1 |

## Versus Earlier Full Redo

Baseline: `notes/sftp-openssh-bench-10x-redo-20260614T195632Z.txt` at `3d4c453`.

| size | direction | baseline median | current median | delta |
|---:|---|---:|---:|---:|
| 64MiB | put | 388.0 | 381.9 | -1.6% |
| 64MiB | get | 290.0 | 359.2 | +23.9% |
| 1GiB | put | 595.7 | 585.6 | -1.7% |
| 1GiB | get | 527.6 | 554.9 | +5.2% |
| 10GiB | put | 601.0 | 599.2 | -0.3% |
| 10GiB | get | 541.2 | 579.8 | +7.1% |

## Notes

- The accumulated drain-loop changes clearly improve OpenSSH downloads across all measured sizes.
- Upload remains roughly flat to slightly lower compared with the earlier full redo. The latest download-focused changes should continue to be watched against full put/get matrices.
- The next download profile target is the receive/drain loop itself: `recv_buffered_encrypted_payload/1`, `recv_buffered_or_available_encrypted_payload/2`, and `drain_more_buffered_sftp_data/6` dominate after reducing encrypted flush/send calls.
