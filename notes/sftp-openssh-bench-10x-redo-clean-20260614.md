# OpenSSH SFTP benchmark redo after busy-system run

- Date: 2026-06-14
- Commit: `3bf647b` (`Add time-based SFTP profiling evidence`)
- Raw artifact: `notes/sftp-openssh-bench-10x-redo-clean-20260614T234956Z.txt`
- Transport: `transport: :elixir`
- Backend: `Sftpd.Backends.Benchmark`
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- OpenSSH request shape: `-B 262080 -R 64`
- Server lifecycle: each script invocation starts and stops a fresh Sftpd server

This reruns the 64MiB, 1GiB, and 10GiB OpenSSH benchmark set because the prior
machine state had a high-CPU task running.

| Size | Direction | Runs | Median MiB/s | Average MiB/s | Min MiB/s | Max MiB/s |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: |
| 64MiB | upload | 10 | 370.9 | 386.7 | 366.8 | 434.9 |
| 64MiB | download | 10 | 348.3 | 349.5 | 340.2 | 359.9 |
| 1GiB | upload | 10 | 583.9 | 585.0 | 567.5 | 595.7 |
| 1GiB | download | 10 | 556.1 | 555.9 | 551.4 | 559.9 |
| 10GiB | upload | 10 | 605.1 | 607.7 | 599.8 | 621.3 |
| 10GiB | download | 10 | 581.4 | 583.3 | 576.6 | 595.0 |

The clean rerun is consistent with the previous post-profile baseline at large
sizes. The abandoned `:prim_inet.recv/3` experiment was reverted before this
run because its upload eprof result regressed materially.
