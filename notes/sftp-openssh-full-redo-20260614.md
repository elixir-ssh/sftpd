# OpenSSH Full Benchmark Redo

Tested commit: `ee0e7cd` (`Record current OpenSSH full benchmark`)

Raw output: `notes/sftp-openssh-bench-full-redo-20260614T213057Z.txt`

Shape: pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`,
`-B 262080`, `-R 64`, 10 runs each for 64MiB, 1GiB, and 10GiB. The benchmark
script restarted the SFTP server for every run.

This reruns the previous full matrix after the machine had a high-CPU task
during earlier measurements.

## Current Medians

Throughput in MiB/s.

| size | put median | get median | put mean | get mean | put min..max | get min..max |
|---:|---:|---:|---:|---:|---:|---:|
| 64MiB | 381.5 | 356.8 | 395.8 | 354.9 | 370.5..445.6 | 341.8..364.9 |
| 1GiB | 584.7 | 558.1 | 585.3 | 560.0 | 579.6..591.4 | 540.7..585.9 |
| 10GiB | 601.5 | 580.3 | 600.2 | 581.4 | 583.0..608.1 | 574.2..594.7 |

## Versus Previous Current Full Run

Previous current run: `notes/sftp-openssh-bench-current-full-20260614T211820Z.txt`.

| size | direction | previous median | redo median | delta |
|---:|---|---:|---:|---:|
| 64MiB | put | 381.9 | 381.5 | -0.1% |
| 64MiB | get | 359.2 | 356.8 | -0.7% |
| 1GiB | put | 585.6 | 584.7 | -0.2% |
| 1GiB | get | 554.9 | 558.1 | +0.6% |
| 10GiB | put | 599.2 | 601.5 | +0.4% |
| 10GiB | get | 579.8 | 580.3 | +0.1% |

## Notes

- The redo confirms the previous current full run was representative. The
  large-transfer medians are effectively unchanged after removing the external
  CPU load.
- 64MiB put remains noisy because the transfer is short enough for startup and
  client variance to dominate.
- Upload profiling should still focus on fragmented OpenSSH write packet
  assembly: the prior upload profile showed about 1.31M `split_sftp_packets/2`
  and `continue_partial_sftp_packet/5` calls for a 10GiB upload.
