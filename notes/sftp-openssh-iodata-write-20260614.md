# Fragmented WRITE Iodata Benchmark

Tested commit: `ee0e7cd` (`Record current OpenSSH full benchmark`) plus local
fragmented SFTP WRITE iodata changes.

Raw profile: `notes/sftp-cprof-profile-upload-iodata-write-20260614T214134Z.txt`

Raw benchmark: `notes/sftp-openssh-bench-iodata-write-20260614T214216Z.txt`

Shape: pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`,
`-B 262080`, `-R 64`, 10 runs each for 64MiB, 1GiB, and 10GiB. The benchmark
script restarted the SFTP server for every run.

## Change

Fragmented SFTP packets now stay as iodata through the SSH splitter. The SFTP
codec decodes fragmented `SSH_FXP_WRITE` requests by flattening only the small
fixed fields and handle, leaving the write payload as original sub-binaries for
the backend call.

## Profile

Baseline profile: `notes/sftp-cprof-profile-upload-current-20260614T212807Z.txt`.

| size | baseline upload | iodata upload | delta |
|---:|---:|---:|---:|
| 1GiB | 568.7 MiB/s | 612.4 MiB/s | +7.7% |
| 10GiB | 595.4 MiB/s | 617.0 MiB/s | +3.6% |

The call-count shape is intentionally similar because OpenSSH still fragments
the same number of channel-data packets. The win comes from avoiding the
per-WRITE `IO.iodata_to_binary/1` copy in the fragmented packet assembler.

## 10x OpenSSH Benchmark

Throughput in MiB/s.

| size | put median | get median | put mean | get mean | put min..max | get min..max |
|---:|---:|---:|---:|---:|---:|---:|
| 64MiB | 388.1 | 363.2 | 399.6 | 363.1 | 379.6..452.8 | 354.6..372.5 |
| 1GiB | 603.9 | 579.1 | 601.3 | 574.9 | 579.2..613.6 | 555.8..589.7 |
| 10GiB | 606.2 | 580.1 | 606.9 | 581.8 | 599.9..616.2 | 575.9..592.7 |

## Versus Clean Redo Baseline

Baseline: `notes/sftp-openssh-bench-full-redo-20260614T213057Z.txt`.

| size | direction | baseline median | iodata median | delta |
|---:|---|---:|---:|---:|
| 64MiB | put | 381.5 | 388.1 | +1.7% |
| 64MiB | get | 356.8 | 363.2 | +1.8% |
| 1GiB | put | 584.7 | 603.9 | +3.3% |
| 1GiB | get | 558.1 | 579.1 | +3.8% |
| 10GiB | put | 601.5 | 606.2 | +0.8% |
| 10GiB | get | 580.3 | 580.1 | -0.0% |

## Notes

- The strongest and most direct win is upload profile throughput, where the
  eliminated copy is on the measured hot path.
- Repeated OpenSSH upload benchmarks improve at 1GiB and 10GiB. Download is
  effectively unchanged for sustained 10GiB transfers.
- This keeps OpenSSH packet sizing and encryption unchanged.
