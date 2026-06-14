# Active Channel Cache Fast Path Benchmark Redo

Tested commit: `8fcc7a9` (`Fast-path active channel cache updates`)

Raw benchmark: `notes/sftp-openssh-bench-cache-fastpath-redo-20260614T221726Z.txt`

Shape: pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`,
`-B 262080`, `-R 64`, 10 runs each for 64MiB, 1GiB, and 10GiB. The benchmark
script restarted the SFTP server for every run.

This reran the previous cache-fastpath set because the earlier benchmark may
have overlapped with a high-CPU task.

## 10x OpenSSH Benchmark

Throughput in MiB/s.

| size | put median | get median | put mean | get mean | put min..max | get min..max |
|---:|---:|---:|---:|---:|---:|---:|
| 64MiB | 378.0 | 353.4 | 387.5 | 353.9 | 327.3..470.4 | 338.9..375.5 |
| 1GiB | 586.0 | 558.2 | 586.2 | 567.5 | 575.7..598.1 | 549.8..641.3 |
| 10GiB | 602.7 | 580.0 | 604.3 | 580.5 | 578.5..624.2 | 575.2..589.4 |

## Comparison To Prior Cache-Fastpath Run

Prior raw benchmark: `notes/sftp-openssh-bench-cache-fastpath-20260614T220640Z.txt`

| size | direction | prior median | redo median | delta |
|---:|---|---:|---:|---:|
| 64MiB | put | 386.5 | 378.0 | -2.2% |
| 64MiB | get | 359.5 | 353.4 | -1.7% |
| 1GiB | put | 608.1 | 586.0 | -3.6% |
| 1GiB | get | 581.2 | 558.2 | -4.0% |
| 10GiB | put | 626.3 | 602.7 | -3.8% |
| 10GiB | get | 602.5 | 580.0 | -3.7% |

## Notes

- The redo does not reproduce the prior 10GiB 602.5 MiB/s download median.
- The sustained 10GiB redo is tightly clustered around 580 MiB/s for download.
- Use this redo as the current benchmark reference before the next performance
  change.
