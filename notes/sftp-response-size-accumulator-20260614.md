# SFTP Response Size Accumulator

Tested commit: `8fcc7a9` (`Fast-path active channel cache updates`) plus local
response-size accumulator changes.

Raw profile: `notes/sftp-cprof-profile-response-size-acc-guarded-20260614T222937Z.txt`

Raw benchmark: `notes/sftp-openssh-bench-response-size-acc-guarded-20260614T223123Z.txt`

Baseline benchmark: `notes/sftp-openssh-bench-cache-fastpath-redo-20260614T221726Z.txt`

Shape: pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`,
`-B 262080`, `-R 64`, 10 runs each for 64MiB, 1GiB, and 10GiB. The benchmark
script restarted the SFTP server for every run.

## Change

The SFTP drain loop now carries accumulated response bytes alongside the
reversed response list. This avoids repeatedly walking the accumulated response
list just to decide whether responses are near the client window.

The empty-response path is guarded so fragmented OpenSSH WRITE packets do not
pay the response-size reducer when they only extend a partial packet.

## Profile

Baseline profile: `notes/sftp-cprof-profile-current-64m-1g-10g-20260614T220220Z.txt`

Guarded profile:

| size | direction | baseline | accumulator |
|---:|---|---:|---:|
| 64MiB | upload | 476.5 MiB/s | 424.6 MiB/s |
| 64MiB | download | 131.3 MiB/s | 127.2 MiB/s |
| 1GiB | upload | 612.7 MiB/s | 600.2 MiB/s |
| 1GiB | download | 167.4 MiB/s | 167.9 MiB/s |
| 10GiB | upload | 620.8 MiB/s | 627.1 MiB/s |
| 10GiB | download | 169.3 MiB/s | 170.4 MiB/s |

The profile shows the expensive `responses_window_size/1` reducer runs only
for real response lists after the guard. A cheap empty-list guard remains on
the fragmented upload path.

## 10x OpenSSH Benchmark

Throughput in MiB/s.

| size | put median | get median | put mean | get mean | put min..max | get min..max |
|---:|---:|---:|---:|---:|---:|---:|
| 64MiB | 376.9 | 354.2 | 393.8 | 357.2 | 368.2..453.9 | 346.0..375.4 |
| 1GiB | 589.4 | 555.9 | 581.2 | 540.7 | 375.9..712.2 | 427.0..559.7 |
| 10GiB | 608.8 | 583.4 | 607.9 | 583.9 | 596.8..613.1 | 577.8..594.9 |

## Versus Redo Baseline

Baseline: `notes/sftp-openssh-cache-fastpath-redo-20260614.md`

| size | direction | baseline median | accumulator median | delta |
|---:|---|---:|---:|---:|
| 64MiB | put | 378.0 | 376.9 | -0.3% |
| 64MiB | get | 353.4 | 354.2 | +0.2% |
| 1GiB | put | 586.0 | 589.4 | +0.6% |
| 1GiB | get | 558.2 | 555.9 | -0.4% |
| 10GiB | put | 602.7 | 608.8 | +1.0% |
| 10GiB | get | 580.0 | 583.4 | +0.6% |

## Notes

- The sustained 10GiB result is the reason to keep this change.
- The 1GiB set had one obvious noisy put/get pair; the median remains flat.
- This does not change SSH/SFTP packet sizes, encryption, or wire behavior.
