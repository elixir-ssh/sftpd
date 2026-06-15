# Skip Adjust Near-Window Recheck Profile

Tested dirty base: `aa37c64` (`Defer channel cache updates during SFTP drains`)

Change: after a buffered `CHANNEL_WINDOW_ADJUST`, continue directly to the next nonblocking receive instead of re-entering the generic `drain_buffered_sftp_data/6` near-window check. The client window only increased, so an accumulator that was not near the previous window cannot become near the larger window.

Raw profile: `notes/sftp-cprof-profile-skip-adjust-near-check-20260614T210837Z.txt`

Raw benchmark: `notes/sftp-openssh-bench-skip-adjust-near-check-20260614T211008Z.txt`

## CProf Download Counts

Compared to `notes/sftp-cprof-profile-defer-drain-cache-20260614T205515Z.txt`.

| size | metric | before | after |
|---:|---|---:|---:|
| 1GiB | throughput MiB/s | 167.5 | 166.2 |
| 1GiB | `drain_buffered_sftp_data/6` | 101,985 | 8,000 |
| 1GiB | `send_encrypted_payloads/3` | 4,183 | 3,969 |
| 10GiB | throughput MiB/s | 168.7 | 168.3 |
| 10GiB | `drain_buffered_sftp_data/6` | 1,019,200 | 75,696 |
| 10GiB | `send_encrypted_payloads/3` | 35,935 | 34,792 |

The profile is mostly a call-count cleanup; profiled throughput is effectively flat to slightly lower.

## OpenSSH 10GiB Benchmark

Pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`, 10 runs, restarted server per run.

| direction | before median MiB/s | after median MiB/s |
|---|---:|---:|
| put | 601.5 | 598.0 |
| get | 579.8 | 581.5 |

This is a small download win with a small upload dip in this run. The changed branch is download/window-adjust oriented, so keep watching this in the next full benchmark set.
