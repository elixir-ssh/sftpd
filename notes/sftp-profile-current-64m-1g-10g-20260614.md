# Current SFTP Profile: 64MiB, 1GiB, 10GiB

Tested commit: `4229b3c` (`Preserve SFTP channel state across rekey drains`)

Raw profile: `notes/sftp-cprof-profile-current-64m-1g-10g-20260614T220220Z.txt`

Shape: pure-Elixir transport, OpenSSH `sftp`, `aes256-gcm@openssh.com`,
`-B 262080`, `-R 64`, memory/profile backend, one profile each for upload and
download at 64MiB, 1GiB, and 10GiB.

## Throughput Under cprof

cprof overhead makes these lower than benchmark numbers; use this table for
relative profile shape, not final throughput claims.

| direction | size | throughput |
|---|---:|---:|
| upload | 64MiB | 476.5 MiB/s |
| upload | 1GiB | 612.7 MiB/s |
| upload | 10GiB | 620.8 MiB/s |
| download | 64MiB | 131.3 MiB/s |
| download | 1GiB | 167.4 MiB/s |
| download | 10GiB | 169.3 MiB/s |

## Hot Shape

Upload is still dominated by OpenSSH WRITE fragmentation:

| size | `split_sftp_packets/2` | `continue_partial_sftp_packet/5` | writes |
|---:|---:|---:|---:|
| 64MiB | 8,200 | 8,195 | 257 |
| 1GiB | 131,110 | 131,104 | 4,098 |
| 10GiB | 1,311,046 | 1,311,040 | 40,971 |

Download is dominated by nonblocking drain/poll calls while flushing read
responses and observing client window traffic:

| size | `recv_buffered_or_available_encrypted_payload/2` | `drain_more_buffered_sftp_data/6` | reads |
|---:|---:|---:|---:|
| 64MiB | 6,158 | 6,158 | 258 |
| 1GiB | 99,276 | 99,276 | 4,099 |
| 10GiB | 991,018 | 991,018 | 40,972 |

## Next Targets

- Upload: reduce per-fragment drain/split recursion around large OpenSSH WRITE
  packets without reintroducing payload copies.
- Download: reduce socket polling while flushing responses. The hot path is not
  backend reads; it is checking for more encrypted input during response drain.
- Any change must be validated with 64MiB, 1GiB, and 10GiB because small-file
  startup effects and sustained-transfer behavior differ.
