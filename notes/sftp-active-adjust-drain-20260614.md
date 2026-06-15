# Active Window Adjust Drain Profile

Tested dirty base: `b780b93` (`Index memory backend chunks for ranged reads`)

Change: when the active pure-SSH channel receives `CHANNEL_WINDOW_ADJUST` while SFTP responses are pending, run the same nonblocking encrypted drain used for channel data before flushing. This lets already-available read requests and window updates accumulate, reducing tiny flush/send cycles without changing channel windows, max packet sizes, encryption, or SFTP packet sizes.

Raw profile: `notes/sftp-cprof-profile-active-adjust-drain-20260614T204512Z.txt`

Raw benchmark: `notes/sftp-openssh-bench-active-adjust-drain-20260614T204644Z.txt`

## CProf Download Counts

Compared to `notes/sftp-cprof-profile-window-adjust-drain-20260614T202110Z.txt`.

| size | metric | before | after |
|---:|---|---:|---:|
| 1GiB | throughput MiB/s | 155.4 | 167.1 |
| 1GiB | `flush_sftp_responses_with_channel/4` | 70,389 | 4,091 |
| 1GiB | `send_encrypted_payloads/3` | 66,362 | 4,055 |
| 10GiB | throughput MiB/s | 155.3 | 169.5 |
| 10GiB | `flush_sftp_responses_with_channel/4` | 709,079 | 36,592 |
| 10GiB | `send_encrypted_payloads/3` | 668,181 | 36,275 |

The tradeoff is more drain-loop work (`drain_buffered_sftp_data/6` rises), but it replaces hundreds of thousands of encrypted flush/send cycles.

## OpenSSH 10GiB Benchmark

Pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`, 10 runs, restarted server per run.

| direction | before median MiB/s | after median MiB/s |
|---|---:|---:|
| put | 601.7 | 601.9 |
| get | 542.5 | 579.4 |

Download is the win: the median moved by roughly +6.8% while upload stayed effectively flat.
