# Current OpenSSH cprof profile redo after busy system

- sha: 1e2974c
- commit: Avoid copying exact memory content reads
- date_utc: 20260615T144053Z
- profiler: cprof
- transport: elixir
- backend: benchmark
- client: OpenSSH sftp
- sizes: 64MiB, 1GiB, 10GiB
- directions: upload, download
- chunk: 262080
- requests: 64

Raw output: notes/sftp-cprof-profile-redo-after-busy-64m-1g-10g-1e2974c-20260615T144053Z.txt

## Results

| Size | Direction | Throughput MiB/s | drain_more_buffered_sftp_data/7 | recv_buffered_or_available_encrypted_payload/3 | recv_available_encrypted_payload/3 | recv_buffered_encrypted_payload/1 | recv_encrypted_packet/3 | split_sftp_packets/2 | continue_partial_sftp_packet/5 | flush_sftp_responses_with_channel/4 | send_encrypted_payloads/3 | write_at/4 | read_at/4 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64MiB | upload | 378.2 | 8200 | 8200 | 8200 | 13928 | 4949 | 8200 | 8195 | 266 | 265 | 257 | 0 |
| 64MiB | download | 249.4 | 7906 | 7906 | 3348 | 11231 | 382 | 202 | 0 | 211 | 209 | 0 | 258 |
| 1GiB | upload | 596.7 | 131111 | 131111 | 131110 | 220298 | 83851 | 131110 | 131104 | 4173 | 4172 | 4098 | 0 |
| 1GiB | download | 597.8 | 130831 | 130831 | 48814 | 179620 | 4217 | 4047 | 0 | 4057 | 4052 | 0 | 4099 |
| 10GiB | upload | 614.5 | 1311057 | 1311057 | 1311046 | 2192734 | 858743 | 1311046 | 1311040 | 41997 | 41996 | 40971 | 0 |
| 10GiB | download | 643.5 | 1310766 | 1310766 | 338701 | 1649440 | 41084 | 40915 | 0 | 40928 | 40927 | 0 | 40972 |

## Read

The profile is dominated by the SSH/SFTP drain loop rather than backend calls. At 10GiB upload there are about 40,971 backend writes, but 1,311,046 SFTP splitter calls and 1,311,057 drain iterations because OpenSSH fragments each large SFTP WRITE across many SSH packets. Download has the same drain iteration count, but far fewer full encrypted packet receives because pipelined READ packets are often already buffered.

The next useful optimization needs to reduce drain/probe iterations or the work inside them while preserving OpenSSH pipelining. Narrow allocation tweaks in packet sizing, benchmark write-size accounting, and fragmented-buffer state did not survive the 10GiB gate.
