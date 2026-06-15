# Fragmented WRITE Fast Parser Benchmark

Commit under test: pending change after `bf853fc Receive blocking encrypted packets directly`

Raw output: `notes/sftp-openssh-bench-fragmented-write-fast-parser-full-20260615T121634Z.txt`

Change under test:

- Parse fragmented SFTP `WRITE` packets directly when the first iodata fragment
  contains the complete request metadata.
- Preserve upload file data as iodata.
- Avoid generic `split_iodata` walks and avoid traversing the remaining upload
  data just to validate the common packet shape.

Command shape:

```sh
MIX_ENV=test nix develop -c mix run scripts/sftp_perf_bench.exs \
  --transport elixir \
  --size <64MiB|1GiB|10GiB> \
  --chunk 262080 \
  --requests 64 \
  --port 29222
```

Each size was run 10 times with the official OpenSSH `sftp` client using
`aes256-gcm@openssh.com`.

## Results

Baseline is the current-machine rerun from
`notes/sftp-openssh-bench-redo-current-10x-rerun-20260615.md`.

| Size | Direction | Median MiB/s | vs rerun base | vs prior `bf853fc` |
|---:|:---|---:|---:|---:|
| 64MiB | put | 306.85 | -2.45 | -15.70 |
| 64MiB | get | 299.45 | +1.00 | -15.45 |
| 1GiB | put | 597.70 | +9.00 | -5.55 |
| 1GiB | get | 638.25 | +27.30 | +11.20 |
| 10GiB | put | 636.00 | +13.15 | -2.40 |
| 10GiB | get | 677.95 | +16.45 | -4.65 |

## Samples

| Size | Direction | Samples MiB/s |
|---:|:---|:---|
| 64MiB | put | 371.3, 301.5, 301.4, 304.9, 303.4, 308.8, 343.7, 362.1, 304.1, 321.3 |
| 64MiB | get | 296.6, 298.9, 294.5, 300.1, 300.0, 277.9, 310.8, 278.4, 314.5, 316.5 |
| 1GiB | put | 544.0, 594.8, 597.6, 602.6, 597.8, 604.2, 607.6, 596.9, 618.2, 585.2 |
| 1GiB | get | 642.3, 622.3, 647.7, 630.4, 621.3, 628.1, 634.2, 646.5, 649.5, 643.5 |
| 10GiB | put | 624.8, 639.3, 636.5, 645.6, 634.1, 640.7, 620.3, 636.9, 626.1, 635.5 |
| 10GiB | get | 679.3, 683.8, 692.7, 687.2, 665.6, 657.6, 656.1, 665.0, 697.8, 676.6 |

## Read

The 64MiB upload row remains noisy and slightly negative against the immediate
rerun baseline. The 1GiB and 10GiB rows are positive in both directions, with
the targeted upload path improving by +9.00 MiB/s at 1GiB and +13.15 MiB/s at
10GiB.
