# OpenSSH SFTP benchmark redo after busy-system run

- Date: 2026-06-15
- Tested commit: `66e7bdb` (`Profile SFTP after window adjust batching`)
- Raw artifact: `notes/sftp-openssh-bench-window-adjust-8m-redo-20260615T003446Z.txt`
- Transport: `transport: :elixir`
- Backend: `Sftpd.Backends.Benchmark`
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- OpenSSH request shape: `-B 262080 -R 64`
- Server lifecycle: each script invocation starts and stops a fresh Sftpd server
- Reason: redo the 64MiB, 1GiB, and 10GiB 10x set after a high-CPU task may
  have affected earlier measurements.

## 10-run summary

| Size | Direction | Runs | Median MiB/s | Average MiB/s | Min MiB/s | Max MiB/s |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: |
| 64MiB | upload | 10 | 376.6 | 379.3 | 226.8 | 451.4 |
| 64MiB | download | 10 | 347.7 | 345.8 | 320.0 | 364.6 |
| 1GiB | upload | 10 | 588.9 | 586.0 | 556.4 | 603.3 |
| 1GiB | download | 10 | 555.0 | 555.8 | 551.1 | 564.8 |
| 10GiB | upload | 10 | 607.4 | 606.6 | 592.0 | 615.6 |
| 10GiB | download | 10 | 581.6 | 582.1 | 575.7 | 590.4 |

## Comparison with committed 8MiB-adjust benchmark

| Size | Direction | Prior median MiB/s | Redo median MiB/s | Delta |
| ---: | :--- | ---: | ---: | ---: |
| 64MiB | upload | 378.4 | 376.6 | -1.8 |
| 64MiB | download | 345.8 | 347.7 | +1.9 |
| 1GiB | upload | 593.1 | 588.9 | -4.2 |
| 1GiB | download | 559.2 | 555.0 | -4.2 |
| 10GiB | upload | 615.3 | 607.4 | -7.9 |
| 10GiB | download | 588.8 | 581.6 | -7.2 |

## Notes

The 10GiB redo is consistent but lower than the prior committed benchmark by
about 1.2-1.3%. The 64MiB upload set includes one clear low outlier at
226.8 MiB/s, so its median is more useful than its average. This redo does not
justify a code change by itself.
