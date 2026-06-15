# OpenSSH SFTP benchmark, 8MiB window-adjust batching

- Date: 2026-06-15
- Base comparison commit: `07baa8a` (`Record clean OpenSSH SFTP benchmark redo`)
- Candidate: batch SSH channel window-adjust messages at `8MiB` instead of
  `1MiB`
- Raw artifact: `notes/sftp-openssh-bench-window-adjust-8m-20260615T000022Z.txt`
- Transport: `transport: :elixir`
- Backend: `Sftpd.Backends.Benchmark`
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- OpenSSH request shape: `-B 262080 -R 64`
- Server lifecycle: each script invocation starts and stops a fresh Sftpd server

The change does not alter SSH packet sizes, SFTP request sizes, or encryption.
It reduces encrypted upload-side control traffic by sending receive-window
adjustments less often while keeping the batch size well below the advertised
`64MiB` channel window.

## Median MiB/s

| Size | Direction | Baseline | 8MiB adjust | Delta |
| ---: | :--- | ---: | ---: | ---: |
| 64MiB | upload | 370.9 | 378.4 | +7.5 |
| 64MiB | download | 348.3 | 345.8 | -2.5 |
| 1GiB | upload | 583.9 | 593.1 | +9.2 |
| 1GiB | download | 556.1 | 559.2 | +3.1 |
| 10GiB | upload | 605.1 | 615.3 | +10.2 |
| 10GiB | download | 581.4 | 588.8 | +7.4 |

## Candidate 10-run summary

| Size | Direction | Runs | Median MiB/s | Average MiB/s | Min MiB/s | Max MiB/s |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: |
| 64MiB | upload | 10 | 378.4 | 395.6 | 362.3 | 452.9 |
| 64MiB | download | 10 | 345.8 | 343.6 | 326.7 | 350.0 |
| 1GiB | upload | 10 | 593.1 | 593.1 | 577.9 | 606.2 |
| 1GiB | download | 10 | 559.2 | 561.8 | 551.4 | 576.5 |
| 10GiB | upload | 10 | 615.3 | 612.7 | 596.3 | 623.8 |
| 10GiB | download | 10 | 588.8 | 589.2 | 572.6 | 605.7 |

Focused validation:

```text
nix develop -c mix test test/sftpd/ssh/server_test.exs test/sftpd/ssh/sftp_bridge_test.exs
27 passed (3 properties, 24 tests)
```
