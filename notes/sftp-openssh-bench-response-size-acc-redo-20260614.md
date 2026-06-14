# OpenSSH SFTP Response-Size Accumulator Redo

Tested commit: `0f29e35822ca75914393ba2632d9dd61c4f68e10` (`Carry SFTP response byte totals`)

Raw output: `notes/sftp-openssh-bench-response-size-acc-redo-20260614T230842Z.txt`

Reason for redo: the previous set may have overlapped with a high-CPU task.

Shape: pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`,
`-B 262080`, `-R 64`, 10 runs each for 64MiB, 1GiB, and 10GiB. The benchmark
script restarted the SFTP server for every run.

Throughput in MiB/s.

| size | direction | median | min | max | median seconds |
|---:|---|---:|---:|---:|---:|
| 64MiB | put | 375.1 | 367.1 | 459.0 | 0.171 |
| 64MiB | get | 347.9 | 331.4 | 375.8 | 0.184 |
| 1GiB | put | 586.5 | 580.2 | 601.5 | 1.746 |
| 1GiB | get | 559.5 | 557.6 | 583.0 | 1.830 |
| 10GiB | put | 608.5 | 605.4 | 615.9 | 16.829 |
| 10GiB | get | 579.6 | 571.8 | 597.6 | 17.667 |

## Comparison

Prior accumulator note: `notes/sftp-response-size-accumulator-20260614.md`

| size | direction | previous median | redo median | delta |
|---:|---|---:|---:|---:|
| 64MiB | put | 376.9 | 375.1 | -0.5% |
| 64MiB | get | 354.2 | 347.9 | -1.8% |
| 1GiB | put | 589.4 | 586.5 | -0.5% |
| 1GiB | get | 555.9 | 559.5 | +0.6% |
| 10GiB | put | 608.8 | 608.5 | -0.0% |
| 10GiB | get | 583.4 | 579.6 | -0.7% |

## Notes

- The sustained 10GiB upload result is effectively unchanged from the prior
  accumulator benchmark.
- The 10GiB download median is lower than the prior run, but still in the same
  range as the cache-fastpath redo baseline (`580.0 MiB/s`).
- The 64MiB upload run remains noisy enough that it should not drive hot-path
  decisions by itself.
