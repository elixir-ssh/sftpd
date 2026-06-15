# eprof after offset-based binary channel-data payloads

Commit profiled: `b001425` (`Frame binary SFTP data by offset`)

Raw data:

- `notes/sftp-eprof-profile-after-offset-binary-channel-64m-1g-10g-20260615T095434Z.txt`

Profile shape:

- Official OpenSSH `sftp`
- Pure-Elixir transport
- AES256-GCM
- Benchmark backend
- `--chunk 262080 --requests 64`
- eprof on the pure SSH connection process
- 64MiB, 1GiB, and 10GiB upload/download

Selected timed rows:

| Size | Direction | Throughput under eprof | Top rows |
| --- | --- | ---: | --- |
| 64MiB | upload | 295.9 MiB/s | `port_control/3` 24.55%, `crypto:aead_cipher_nif/7` 20.99%, decrypt 4.57%, `split_binary/2` 2.63% |
| 64MiB | download | 244.8 MiB/s | `crypto:aead_cipher_nif/7` 28.22%, `port_control/3` 14.80%, `port_command/3` 14.32%, decrypt 4.74%, `split_binary/2` 2.81% |
| 1GiB | upload | 564.4 MiB/s | `port_control/3` 25.21%, `crypto:aead_cipher_nif/7` 22.32%, decrypt 4.87%, `split_binary/2` 2.73% |
| 1GiB | download | 655.8 MiB/s | `crypto:aead_cipher_nif/7` 32.28%, `port_command/3` 15.44%, `port_control/3` 11.84%, decrypt 5.55%, `split_binary/2` 3.28% |
| 10GiB | upload | 592.7 MiB/s | `port_control/3` 25.66%, `crypto:aead_cipher_nif/7` 22.55%, decrypt 4.76%, `split_binary/2` 2.64% |
| 10GiB | download | 720.6 MiB/s | `crypto:aead_cipher_nif/7` 32.55%, `port_command/3` 15.44%, `port_control/3` 11.73%, decrypt 5.59%, `split_binary/2` 3.34% |

Download still spends measurable time in generic response splitting even after
the offset chunker:

- 10GiB download: `Sftpd.SSH.SFTPBridge.split_iodata/3` 737,395 calls, 1.26%.
- 10GiB download: `Sftpd.SSH.SFTPBridge.channel_data_payloads/5` 368,745 calls, 0.52%.

Next candidate: preserve the `SerializedPacket.data` shape through
`payloads_for_window/2` so the hot DATA response path reaches the binary
offset chunker instead of first becoming generic `[header, data]` iodata.
