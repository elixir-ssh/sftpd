# OpenSSH SFTP benchmark with batched AEAD padding

- Date: 2026-06-15
- Tested commit: `580004c` (`Cover buffered cipher payload rest handling`) plus local candidate changes
- Candidate: generate one random padding binary per encrypted response batch, then split it across AEAD packets
- Raw benchmark: `notes/sftp-openssh-bench-batched-aead-padding-20260615T013955Z.txt`
- Transport: `transport: :elixir`
- Backend: `Sftpd.Backends.Benchmark`
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- OpenSSH request shape: `-B 262080 -R 64`
- Server lifecycle: each script invocation starts and stops a fresh Sftpd server

The change does not alter SSH packet sizes, SFTP request sizes, encryption, or
wire format. Each packet keeps the same padding length calculation as before;
the server only reduces RNG NIF calls by drawing all padding bytes for a flush
in one call and slicing that random binary per packet.

## 10-run summary

| Size | Direction | Runs | Median MiB/s | Average MiB/s | Min MiB/s | Max MiB/s |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: |
| 64MiB | upload | 10 | 350.8 | 367.5 | 332.1 | 421.7 |
| 64MiB | download | 10 | 325.1 | 324.4 | 311.3 | 337.6 |
| 1GiB | upload | 10 | 614.8 | 615.1 | 600.7 | 628.8 |
| 1GiB | download | 10 | 652.9 | 621.7 | 366.3 | 659.9 |
| 10GiB | upload | 10 | 627.8 | 625.4 | 583.6 | 642.4 |
| 10GiB | download | 10 | 678.8 | 671.7 | 646.1 | 689.1 |

## Comparison with previous committed baseline

Baseline: `notes/sftp-openssh-bench-drain-coalesce-1ms-20260615.md`.

| Size | Direction | Baseline MiB/s | Batched padding MiB/s | Delta |
| ---: | :--- | ---: | ---: | ---: |
| 64MiB | upload | 341.5 | 350.8 | +9.3 |
| 64MiB | download | 320.5 | 325.1 | +4.6 |
| 1GiB | upload | 590.0 | 614.8 | +24.8 |
| 1GiB | download | 620.7 | 652.9 | +32.1 |
| 10GiB | upload | 617.4 | 627.8 | +10.4 |
| 10GiB | download | 659.5 | 678.8 | +19.2 |

The 1GiB download average includes one low outlier at 366.3 MiB/s. The median
still improved materially, and the 10GiB medians improved in both directions.
