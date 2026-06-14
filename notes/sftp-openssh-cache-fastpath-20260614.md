# Active Channel Cache Fast Path Benchmark

Tested commit: `2652145` (`Record current SFTP profile matrix`) plus local
active-channel cache fast path.

Raw profile: `notes/sftp-cprof-profile-cache-fastpath-20260614T220558Z.txt`

Raw benchmark: `notes/sftp-openssh-bench-cache-fastpath-20260614T220640Z.txt`

Shape: pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`,
`-B 262080`, `-R 64`, 10 runs each for 64MiB, 1GiB, and 10GiB. The benchmark
script restarted the SFTP server for every run.

## Change

The no-flush SFTP drain path now updates the already-active channel directly
instead of going through `cache_channel/2`. The fallback still uses
`cache_channel/2` when switching active channels.

This is on the upload hot path for fragmented OpenSSH WRITE packets and does
not change SSH/SFTP packet sizes, encryption, or wire behavior.

## Profile

Baseline profile: `notes/sftp-cprof-profile-current-64m-1g-10g-20260614T220220Z.txt`.

| size | baseline upload | fast path upload | note |
|---:|---:|---:|---|
| 1GiB | 612.7 MiB/s | 659.3 MiB/s | `cache_channel/2` dropped from top profile |
| 10GiB | 620.8 MiB/s | 619.9 MiB/s | sustained cprof throughput flat |

## 10x OpenSSH Benchmark

Throughput in MiB/s.

| size | put median | get median | put mean | get mean | put min..max | get min..max |
|---:|---:|---:|---:|---:|---:|---:|
| 64MiB | 386.5 | 359.5 | 393.9 | 358.9 | 286.0..466.3 | 348.5..368.7 |
| 1GiB | 608.1 | 581.2 | 609.7 | 579.3 | 599.7..618.0 | 564.8..587.0 |
| 10GiB | 626.3 | 602.5 | 625.5 | 600.9 | 620.2..629.4 | 590.9..606.6 |

## Versus Fragmented WRITE Iodata Baseline

Baseline: `notes/sftp-openssh-bench-iodata-write-20260614T214216Z.txt`.

| size | direction | baseline median | fast path median | delta |
|---:|---|---:|---:|---:|
| 64MiB | put | 388.1 | 386.5 | -0.4% |
| 64MiB | get | 363.2 | 359.5 | -1.0% |
| 1GiB | put | 603.9 | 608.1 | +0.7% |
| 1GiB | get | 579.1 | 581.2 | +0.4% |
| 10GiB | put | 606.2 | 626.3 | +3.3% |
| 10GiB | get | 580.1 | 602.5 | +3.9% |

## Notes

- The 64MiB result remains startup/noise dominated and included one low put
  outlier.
- The sustained 10GiB win is large enough to keep.
- The next profile target remains the drain/split loop call volume around
  OpenSSH fragmentation and response flushing.
