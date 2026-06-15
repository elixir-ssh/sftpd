# Inline Empty SFTP Drain Benchmark

- sha: f437b6e
- commit: Record current OpenSSH perf profile
- candidate: inline the no-response SFTP drain path used by fragmented OpenSSH uploads
- raw output: notes/sftp-openssh-bench-inline-empty-drain-full-f437b6e-20260615T144915Z.txt
- transport: elixir
- backend: benchmark
- client: OpenSSH sftp
- cipher: aes256-gcm@openssh.com
- sizes: 64MiB, 1GiB, 10GiB
- samples_per_size: 10
- chunk: 262080
- requests: 64

| Size | Direction | Median MiB/s | Delta vs fresh 10x baseline | Samples |
| --- | --- | ---: | ---: | --- |
| 64MiB | put | 298.40 | +0.85 | 289.3, 357.5, 331.7, 292.6, 290.4, 301.0, 295.4, 295.8, 338.3, 355.3 |
| 64MiB | get | 290.30 | +2.35 | 288.4, 286.5, 293.4, 288.7, 290.5, 290.2, 290.4, 289.6, 294.7, 293.4 |
| 1GiB | put | 587.25 | +3.65 | 584.2, 585.0, 598.1, 598.8, 588.5, 580.4, 599.7, 586.0, 585.8, 591.7 |
| 1GiB | get | 610.20 | +0.40 | 609.9, 611.9, 611.3, 610.5, 606.2, 593.0, 608.5, 614.5, 612.3, 608.4 |
| 10GiB | put | 624.95 | +2.05 | 626.8, 622.4, 618.3, 622.6, 645.0, 644.5, 629.4, 623.3, 626.6, 589.6 |
| 10GiB | get | 656.75 | -1.05 | 655.8, 659.8, 653.0, 672.2, 666.6, 654.2, 657.7, 654.0, 654.2, 661.5 |

## Read

The full 10x confirmation is a small net win rather than the large 3x gate signal. Upload improves at every size, while 10GiB download is effectively flat/slightly down. The change is kept because it removes work from the hottest fragmented-upload no-response drain path without changing protocol behavior, encryption, or packet sizes.
