# OpenSSH pure transport benchmark redo after busy system

- sha: 1e2974c
- commit: Avoid copying exact memory content reads
- date_utc: 20260615T142513Z
- transport: elixir
- backend: benchmark
- client: OpenSSH sftp via scripts/sftp_perf_bench.exs
- sizes: 64MiB, 1GiB, 10GiB
- samples_per_size: 10
- chunk: 262080
- requests: 64
- note: rerun requested because prior system had a high CPU task

Raw output: notes/sftp-openssh-bench-redo-after-busy-10x-1e2974c-20260615T142513Z.txt

## Results

Compared against:

- `47bd881` clean synthetic baseline from `notes/sftp-openssh-bench-redo-after-busy-10x-20260615T124717Z.md`
- `7a3fd5c` rerun from `notes/sftp-openssh-bench-redo-after-busy-10x-7a3fd5c-20260615T133922Z.md`

| Size | Direction | Median MiB/s | Min | Max | Delta vs 47bd881 baseline | Delta vs 7a3fd5c rerun | Samples |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 64MiB | put | 297.55 | 294.2 | 361.1 | -8.80 | -1.70 | 308.0, 297.2, 297.6, 297.5, 295.7, 361.1, 354.1, 298.0, 296.2, 294.2 |
| 64MiB | get | 287.95 | 285.8 | 299.0 | -6.55 | -4.20 | 287.6, 287.9, 299.0, 289.5, 287.6, 294.5, 292.0, 285.8, 288.0, 286.2 |
| 1GiB | put | 583.60 | 577.2 | 602.9 | -9.50 | -7.60 | 585.0, 582.7, 577.2, 582.2, 578.7, 589.3, 584.5, 581.7, 592.9, 602.9 |
| 1GiB | get | 609.80 | 599.3 | 636.3 | -4.20 | -3.35 | 610.2, 609.2, 599.3, 610.6, 609.4, 610.7, 609.1, 606.2, 632.7, 636.3 |
| 10GiB | put | 622.90 | 612.1 | 641.5 | +0.35 | +5.40 | 624.7, 626.4, 613.7, 621.1, 612.1, 625.8, 625.0, 620.7, 618.5, 641.5 |
| 10GiB | get | 657.80 | 649.2 | 682.7 | -0.35 | -1.65 | 682.7, 655.9, 649.2, 656.2, 666.1, 654.9, 659.4, 653.6, 674.5, 679.7 |

## Read

The 10GiB result is effectively flat against the clean `47bd881` baseline: upload is +0.35 MiB/s and download is -0.35 MiB/s. The smaller 64MiB and 1GiB cases are lower, especially 64MiB download, so this run does not show a broad benchmark win from the current stack. It does show that the prior slow-looking 10GiB download was likely system load noise rather than a persistent regression.
