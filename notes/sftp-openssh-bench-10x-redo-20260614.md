# OpenSSH SFTP 10x Benchmark Redo

Tested commit: `3d4c453` (`Fuse SFTP window split and payload encoding`)

Raw output: `notes/sftp-openssh-bench-10x-redo-20260614T195632Z.txt`

Reason for redo: the previous benchmark set may have overlapped with a high-CPU task. This run used the same OpenSSH `sftp` client path with `aes256-gcm@openssh.com`, `-B 262080`, `-R 64`, and restarted the SFTP server for every individual run.

## Summary

Throughput in MiB/s.

| transport | size | put median | get median | put mean | get mean |
|---|---:|---:|---:|---:|---:|
| OTP | 64MiB | 300.4 | 304.2 | 297.4 | 299.1 |
| Elixir | 64MiB | 388.0 | 290.0 | 395.8 | 292.6 |
| OTP | 1GiB | 466.6 | 520.8 | 454.0 | 516.4 |
| Elixir | 1GiB | 595.7 | 527.6 | 597.2 | 524.7 |
| OTP | 10GiB | 461.1 | 553.2 | 461.2 | 547.8 |
| Elixir | 10GiB | 601.0 | 541.2 | 602.1 | 540.3 |

## Full Spread

| transport | size | direction | n | min | median | mean | max |
|---|---:|---|---:|---:|---:|---:|---:|
| OTP | 64MiB | put | 10 | 246.5 | 300.4 | 297.4 | 337.5 |
| OTP | 64MiB | get | 10 | 262.4 | 304.2 | 299.1 | 329.3 |
| Elixir | 64MiB | put | 10 | 358.9 | 388.0 | 395.8 | 459.1 |
| Elixir | 64MiB | get | 10 | 263.8 | 290.0 | 292.6 | 317.1 |
| OTP | 1GiB | put | 10 | 383.8 | 466.6 | 454.0 | 475.4 |
| OTP | 1GiB | get | 10 | 499.1 | 520.8 | 516.4 | 529.5 |
| Elixir | 1GiB | put | 10 | 582.1 | 595.7 | 597.2 | 609.3 |
| Elixir | 1GiB | get | 10 | 508.6 | 527.6 | 524.7 | 536.6 |
| OTP | 10GiB | put | 10 | 428.7 | 461.1 | 461.2 | 489.0 |
| OTP | 10GiB | get | 10 | 498.5 | 553.2 | 547.8 | 581.1 |
| Elixir | 10GiB | put | 10 | 590.0 | 601.0 | 602.1 | 616.4 |
| Elixir | 10GiB | get | 10 | 531.6 | 541.2 | 540.3 | 545.0 |

## Notes

- Pure-Elixir upload is the clear win in the stable large-file cases: 1GiB median is 595.7 MiB/s versus OTP 466.6 MiB/s, and 10GiB median is 601.0 MiB/s versus OTP 461.1 MiB/s.
- Pure-Elixir download does not show the same win. It is slightly ahead at 1GiB, but below OTP at 10GiB in this redo: 541.2 MiB/s versus OTP 553.2 MiB/s.
- OTP 10GiB download had a wider spread than pure-Elixir download, so the median comparison is more useful than any single sample.
- The next optimization target remains the pure-Elixir download path, especially response generation, encryption, and write batching.
