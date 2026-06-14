# Window Adjust Drain Profile

Tested dirty base: `a4cd3ad` (`Record redone OpenSSH 10x benchmark set`)

Change: when the pure SSH drain loop receives a `CHANNEL_WINDOW_ADJUST` while SFTP responses are pending, it keeps draining already-available encrypted packets before flushing. This lets multiple buffered window updates accumulate into the channel window and avoids some one-packet flushes.

Raw profile: `notes/sftp-cprof-profile-window-adjust-drain-20260614T202110Z.txt`

Raw benchmark: `notes/sftp-openssh-bench-window-adjust-drain-20260614T202251Z.txt`

## CProf Download Counts

| size | metric | before | after |
|---:|---|---:|---:|
| 1GiB | throughput MiB/s | 153.0 | 155.4 |
| 1GiB | `flush_sftp_responses_with_channel/4` | 70,806 | 70,389 |
| 1GiB | `send_encrypted_payloads/3` | 66,779 | 66,362 |
| 10GiB | throughput MiB/s | 154.2 | 155.3 |
| 10GiB | `flush_sftp_responses_with_channel/4` | 717,235 | 709,079 |
| 10GiB | `send_encrypted_payloads/3` | 676,337 | 668,181 |

The 64MiB profile was noisier and did not improve, which is expected for a startup-heavy run.

## OpenSSH 10GiB Benchmark

Pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`, 10 runs, restarted server per run.

| direction | before median MiB/s | after median MiB/s |
|---|---:|---:|
| put | 601.0 | 601.7 |
| get | 541.2 | 542.5 |

This is a small wall-clock win, but the call-count reduction is consistent at 1GiB and 10GiB and the protocol behavior is unchanged.
