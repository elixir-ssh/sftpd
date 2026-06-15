# OpenSSH SFTP benchmark after connection heap flags

- Commit under test: `66b5613` (`Record buffered receive profile`)
- Raw output: `notes/sftp-openssh-bench-connection-heap-flags-20260615T041512Z.txt`
- Change: set larger pure SSH connection `min_heap_size` and delay full sweeps
- Client: OpenSSH `sftp`
- Transport: pure Elixir SSH/SFTP
- Cipher: `aes256-gcm@openssh.com`
- Chunk size: `262080`
- Requests: `64`
- Samples: `10`
- Server restart: yes, one server per sample

The connection process allocates continuously while decrypting client packets,
dispatching SFTP requests, serializing responses, and encrypting SSH packets.
Giving the pure SSH connection worker a larger starting heap and delaying full
sweeps improved the full OpenSSH benchmark matrix versus the clean rerun.

| Size | Direction | Previous median MiB/s | Clean redo median MiB/s | Candidate median MiB/s | Delta vs redo MiB/s | Candidate min MiB/s | Candidate max MiB/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 64MiB | upload | 371.0 | 332.9 | 378.9 | +46.0 | 319.8 | 411.6 |
| 64MiB | download | 333.7 | 314.5 | 315.0 | +0.5 | 311.9 | 334.4 |
| 1GiB | upload | 614.0 | 601.9 | 603.2 | +1.3 | 561.1 | 623.2 |
| 1GiB | download | 648.5 | 634.0 | 638.8 | +4.8 | 616.8 | 654.6 |
| 10GiB | upload | 626.8 | 627.2 | 635.3 | +8.1 | 617.9 | 642.4 |
| 10GiB | download | 665.6 | 660.5 | 666.8 | +6.2 | 652.3 | 694.3 |
