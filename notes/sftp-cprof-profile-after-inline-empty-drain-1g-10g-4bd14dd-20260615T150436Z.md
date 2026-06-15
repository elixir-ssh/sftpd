# cprof after inline empty SFTP drain

- sha: 4bd14dd
- commit: Inline empty SFTP drain path
- date_utc: 20260615T150436Z
- profiler: cprof
- transport: elixir
- backend: benchmark
- client: OpenSSH sftp
- sizes: 1GiB, 10GiB
- directions: upload, download
- chunk: 262080
- requests: 64

Raw output: notes/sftp-cprof-profile-after-inline-empty-drain-1g-10g-4bd14dd-20260615T150436Z.txt

## Results

| Size | Direction | Throughput MiB/s | drain_more_buffered_sftp_data/7 | recv_buffered_or_available_encrypted_payload/3 | recv_available_encrypted_payload/3 | recv_buffered_encrypted_payload/1 | recv_encrypted_packet/3 | finish_channel_data_drain/2 | finish_open_channel_data_drain/5 | flush_sftp_responses_with_channel/4 | send_encrypted_payloads/3 | write_at/4 | read_at/4 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1GiB | upload | 601.7 | 131111 | 131111 | 131109 | 219245 | 85955 | 42975 | 4093 | 4206 | 4205 | 4098 | 0 |
| 1GiB | download | 579.1 | 130806 | 130806 | 43550 | 174331 | 4245 | 4056 | 4042 | 4057 | 4052 | 0 | 4099 |
| 10GiB | upload | 616.3 | 1311044 | 1311044 | 1311032 | 2194078 | 856003 | 427999 | 40898 | 41961 | 41960 | 40971 | 0 |
| 10GiB | download | 651.3 | 1310710 | 1310710 | 496144 | 1806828 | 41105 | 40913 | 40900 | 40914 | 40912 | 0 | 40972 |

## Read

Inlining the empty-drain finalizer moved most upload no-response completions out of `finish_open_channel_data_drain/5`: 10GiB upload now calls that helper about 40,898 times instead of about 429,369 times in the prior profile. The dominant cost is still earlier in the loop: `drain_more_buffered_sftp_data/7`, `recv_buffered_or_available_encrypted_payload/3`, and `recv_available_encrypted_payload/3` remain at roughly 1.31 million calls for both upload and download.

Follow-up attempts to skip the zero-response near-window predicate and to special-case single-response finalization did not survive the OpenSSH 10GiB gate, so the next useful target is the receive/probe loop itself rather than more finalizer reshaping.
