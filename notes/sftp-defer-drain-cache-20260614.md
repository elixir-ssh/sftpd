# Deferred Drain Cache Profile

Tested dirty base: `1f3744c` (`Drain active window adjusts before SFTP flushes`)

Change: while the pure SSH drain loop is consuming buffered `CHANNEL_WINDOW_ADJUST` packets for the active SFTP channel, keep the updated channel in the recursive drain state and defer `cache_channel/2` until the drain finish/flush boundary.

Raw profile: `notes/sftp-cprof-profile-defer-drain-cache-20260614T205515Z.txt`

Raw benchmark: `notes/sftp-openssh-bench-defer-drain-cache-20260614T205642Z.txt`

## CProf Download Counts

Compared to `notes/sftp-cprof-profile-active-adjust-drain-20260614T204512Z.txt`.

| size | metric | before | after |
|---:|---|---:|---:|
| 1GiB | throughput MiB/s | 167.1 | 167.5 |
| 1GiB | `cache_channel/2` | 94,101 | 362 |
| 1GiB | `flush_sftp_responses_with_channel/4` | 4,091 | 4,240 |
| 1GiB | `send_encrypted_payloads/3` | 4,055 | 4,183 |
| 10GiB | throughput MiB/s | 169.5 | 168.7 |
| 10GiB | `cache_channel/2` | 941,966 | 356 |
| 10GiB | `flush_sftp_responses_with_channel/4` | 36,592 | 36,228 |
| 10GiB | `send_encrypted_payloads/3` | 36,275 | 35,935 |

The main win is removing repeated active-channel cache updates from the recursive drain path.

## OpenSSH 10GiB Benchmark

Pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`, 10 runs, restarted server per run.

| direction | before median MiB/s | after median MiB/s |
|---|---:|---:|
| put | 601.9 | 601.5 |
| get | 579.4 | 579.8 |

The OpenSSH median is effectively flat to slightly positive while the hot-path call count is much lower.
