# SFTP cprof Profile

Tested base commit:
- SHA: `8e3676a8ae9b9a538214fb349bc072bdbcf45ace`
- Message: `Reject OTP root mutation paths`

Profile setup:
- Date: 2026-06-14
- Server: `transport: :elixir`
- Backend: in-process memory-size profile backend, seeded directly for downloads
- Client: OpenSSH `sftp`
- Cipher: `aes256-gcm@openssh.com`
- Client tuning: `-B 262080 -R 64`
- Authentication: generated Ed25519 key with `IdentitiesOnly=yes`
- Profiler: Erlang `cprof` breakpoint call counters over the `Sftpd` modules plus the profile backend
- Current working tree includes the window-adjust batching patch on top of that base commit

Important caveat:
- These are profiles, not benchmarks. `cprof` adds overhead, so throughput below is only context for the profiled run.
- `tprof` call-time tracing was too intrusive for this OpenSSH workload; even narrowed tracing changed behavior enough to close the connection. `cprof` kept the workload stable.

Commands used:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction download --port 29224 --limit 40
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction download --port 29226 --limit 40
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction download --port 29227 --limit 40
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction upload --port 29230 --limit 40
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction upload --port 29225 --limit 40
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction upload --port 29228 --limit 40
```

## Download Profiles

| Size | Elapsed | Profiled Throughput | Backend Reads | Encrypted Loop | `send_encrypted_payloads/3` | `put_channel/2` | `fetch_channel/2` |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 MiB | 0.659 s | 97.2 MiB/s | 258 | 5,448 | 4,804 | 11,077 | 5,440 |
| 1 GiB | 7.895 s | 129.7 MiB/s | 4,099 | 72,297 | 67,813 | 148,620 | 72,289 |
| 10 GiB | 72.795 s | 140.7 MiB/s | 40,972 | 718,907 | 677,772 | 1,478,712 | 718,899 |

10 GiB top profile rows:

| Function | Calls |
| --- | ---: |
| `Sftpd.SSH.Server.put_channel/2` | 1,478,712 |
| `Sftpd.SSH.Wire.string/1` | 831,173 |
| `Sftpd.SSH.Server.-send_encrypted_payloads/3-fun-0-/2` | 831,137 |
| `Sftpd.SSH.Server.validate_encrypted_packet_length/1` | 718,907 |
| `Sftpd.SSH.Server.recv_encrypted_payload/2` | 718,907 |
| `Sftpd.SSH.Server.recv_encrypted_packet/3` | 718,907 |
| `Sftpd.SSH.Server.handle_encrypted_payload/3` | 718,907 |
| `Sftpd.SSH.Server.encrypted_loop/2` | 718,907 |
| `Sftpd.SSH.Server.flush_sftp_responses/4` | 718,896 |
| `Sftpd.SSH.Server.send_encrypted_payloads/3` | 677,772 |
| `SftpdProfile.Backend.read_at/4` | 40,972 |

Download interpretation:
- Backend reads still scale cleanly with the OpenSSH request size: roughly one `read_at/4` per 256 KiB request.
- The new window-adjust batching dropped `send_encrypted_payloads/3` from 711,479 to 677,772 at 10 GiB.
- The hot shape is still connection/channel bookkeeping and response flushing, not memory backend reads.
- `put_channel/2` and `fetch_channel/2` remain prominent, which means the next real win is still reducing channel-state churn in the loop.

## Upload Profiles

| Size | Elapsed | Profiled Throughput | Backend Writes | Encrypted Loop | `send_encrypted_payloads/3` | `put_channel/2` | `fetch_channel/2` |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 MiB | 0.187 s | 342.2 MiB/s | 257 | 8,148 | 322 | 16,596 | 8,140 |
| 1 GiB | 2.579 s | 397.0 MiB/s | 4,098 | 131,110 | 5,087 | 267,285 | 131,102 |
| 10 GiB | 21.284 s | 481.1 MiB/s | 40,971 | 1,303,254 | 50,650 | 2,657,136 | 1,303,246 |

10 GiB top profile rows:

| Function | Calls |
| --- | ---: |
| `Sftpd.SSH.Server.put_channel/2` | 2,657,136 |
| `Sftpd.SSH.Wire.take_string/1` | 1,303,301 |
| `Sftpd.SSH.Server.validate_encrypted_packet_length/1` | 1,303,254 |
| `Sftpd.SSH.Server.recv_encrypted_payload/2` | 1,303,254 |
| `Sftpd.SSH.Server.recv_encrypted_packet/3` | 1,303,254 |
| `Sftpd.SSH.Server.handle_encrypted_payload/3` | 1,303,254 |
| `Sftpd.SSH.Server.encrypted_loop/2` | 1,303,254 |
| `Sftpd.SSH.Server.fetch_channel/2` | 1,303,246 |
| `Sftpd.SSH.Server.flush_sftp_responses/4` | 50,662 |
| `Sftpd.SSH.Server.send_encrypted_payloads/3` | 50,650 |
| `SftpdProfile.Backend.write_at/4` | 40,971 |

Upload interpretation:
- The window-adjust batching made the big difference here: `send_encrypted_payloads/3` fell from 673,785 to 50,650 at 10 GiB.
- Throughput improved from 421.5 MiB/s to 481.1 MiB/s in the profiled 10 GiB OpenSSH upload.
- Backend writes still scale as expected: roughly one `write_at/4` per 256 KiB request.
- Channel-state calls are still heavy, so the remaining next step is channel-state churn reduction rather than backend work.

## Likely Next Work

1. Reduce channel map churn. `fetch_channel/2` and `put_channel/2` are still the biggest non-network call volume on both directions. Keep the active channel in the loop state while draining a burst, then write it back once.
2. Batch download response flushing further. Download improved, but `flush_sftp_responses/4` still runs for each response batch. The bridge and server could probably hold more responses per flush when the client window is clearly open.
3. Consider a dedicated active-channel cache in the connection loop. The profile still shows a single-channel workload paying the cost of map lookups/updates on every packet.
4. Add a time profiler once call count is lower. `cprof` identified where call volume is going, but not per-call cost. A narrower time profiler should be more useful after the loop count is lower.

## Follow-up: Active Channel Cache

After adding a conservative active-channel cache and deferring active-channel map writes until channel switch/cleanup, the 64 MiB OpenSSH profile shape changed as expected.

Commands used:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction download --port 29247 --limit 20
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction upload --port 29248 --limit 20
```

| Direction | Elapsed | Profiled Throughput | `put_channel/2` | `fetch_channel/2` | New hot channel helper |
| --- | ---: | ---: | ---: | ---: | --- |
| Download | 0.667 s | 96.0 MiB/s | below top 20 | below top 20 | `cache_channel/2`: 10,777 calls |
| Upload | 0.173 s | 370.2 MiB/s | below top 20 | below top 20 | `cache_channel/2`: 8,524 calls |

Interpretation:
- The map-update and map-fetch functions dropped out of the top rows for the profiled 64 MiB OpenSSH workload.
- The remaining channel helper calls are state-slot updates, not full channel map rewrites.
- Download is still dominated by response flushing and encrypted packet send count; upload is now mostly the receive/decode/drain loop.

## Follow-up: Sized Channel Data Payloads

After threading known fragment sizes through `SFTPBridge.response_payloads/2`, channel-data packet emission no longer calls `Wire.string/1` for every outgoing data fragment.

Commands used:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction download --port 29249 --limit 20
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction upload --port 29250 --limit 20
```

| Direction | Elapsed | Profiled Throughput | Notable call-count change |
| --- | ---: | ---: | --- |
| Download | 0.704 s | 90.8 MiB/s | `Wire.string/1` dropped below the top 20; `SerializedPacket.iodata/2` from window splitting is now visible at 9,671 calls |
| Upload | 0.158 s | 405.4 MiB/s | unchanged hot shape: receive/decode/drain plus 324 response flushes |

Interpretation:
- This removes one avoidable per-fragment iodata length calculation in the send path.
- It does not solve download packet count. The remaining work is in window splitting/flush behavior and the OpenSSH-advertised channel packet limit.

## Follow-up: Skip Empty Window-Adjust Flushes

After changing channel-window-adjust handling to skip SFTP response flushing when no responses are pending, the full cprof matrix was:

Commands used:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction download --port 29311 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction upload --port 29312 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction download --port 29313 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction upload --port 29314 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction download --port 29315 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction upload --port 29316 --limit 25
```

| Size | Direction | Elapsed | Profiled Throughput | Flush calls | Send calls |
| ---: | --- | ---: | ---: | ---: | ---: |
| 64 MiB | Download | 0.692 s | 92.5 MiB/s | 4,965 | 4,778 |
| 64 MiB | Upload | 0.183 s | 349.7 MiB/s | 324 | 323 |
| 1 GiB | Download | 8.124 s | 126.1 MiB/s | 71,866 | 67,837 |
| 1 GiB | Upload | 2.893 s | 354.0 MiB/s | 4,876 | 4,875 |
| 10 GiB | Download | 79.206 s | 129.3 MiB/s | 718,654 | 677,755 |
| 10 GiB | Upload | 28.026 s | 365.4 MiB/s | 50,809 | 50,808 |

Interpretation:
- This is a modest sequential-download improvement at best, but it avoids provably unnecessary response-flush work for empty window-adjust packets.
- The behavior is likely more useful for many-small-files and other control-heavy OpenSSH workloads than for a single large sequential transfer.
- Large sequential download is still dominated by OpenSSH channel packet fragmentation and the resulting encrypted send count.

## Follow-up: Partial SFTP Input Buffer

After replacing `channel.sftp_buffer <> data` with a partial-packet accumulator, complete SFTP packets remain sub-binaries and fragmented packets are materialized only once when complete.

Commands used:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction upload --port 29331 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction upload --port 29332 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction upload --port 29333 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction download --port 29334 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction download --port 29335 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction download --port 29336 --limit 25
```

| Size | Direction | Elapsed | Profiled Throughput | Notes |
| ---: | --- | ---: | ---: | --- |
| 64 MiB | Upload | 0.289 s | 221.4 MiB/s | small-size cprof noise; call shape unchanged except partial parser |
| 1 GiB | Upload | 3.228 s | 317.2 MiB/s | noisy slower run |
| 10 GiB | Upload | 21.433 s | 477.8 MiB/s | best large-upload cprof result in this series |
| 64 MiB | Download | 0.767 s | 83.4 MiB/s | neutral/noisy; download is not the target path |
| 1 GiB | Download | 8.434 s | 121.4 MiB/s | neutral/noisy |
| 10 GiB | Download | 72.158 s | 141.9 MiB/s | no large regression; still send-count-bound |

Interpretation:
- The optimization targets fragmented upload packets. It avoids repeated growing-buffer copies, but still pays one parser helper call per SSH channel fragment.
- Large uploads benefit most; small cprof runs remain too noisy to use alone.
- The next upload work is reducing per-fragment loop/helper overhead, not backend writes.

## Follow-up: Direct Channel-Data Parse

After replacing `Wire.take_string/1` with direct binary matching for SSH channel-data payloads, the generic string parser dropped out of the upload/download hot rows.

Commands used:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction upload --port 29341 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction upload --port 29342 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction upload --port 29343 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction download --port 29344 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction download --port 29345 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction download --port 29346 --limit 25
```

| Size | Direction | Elapsed | Profiled Throughput | Notes |
| ---: | --- | ---: | ---: | --- |
| 64 MiB | Upload | 0.269 s | 238.4 MiB/s | small-size cprof noise |
| 1 GiB | Upload | 3.332 s | 307.4 MiB/s | noisy slower run |
| 10 GiB | Upload | 22.376 s | 457.6 MiB/s | still in the improved large-upload range |
| 64 MiB | Download | 0.743 s | 86.2 MiB/s | noisy |
| 1 GiB | Download | 7.359 s | 139.1 MiB/s | improved in this run |
| 10 GiB | Download | 70.233 s | 145.8 MiB/s | best large-download cprof result in this series |

Interpretation:
- This is a call-count cleanup, not a fundamental packet-count fix.
- It removes `Wire.take_string/1` from the hot channel-data path.
- The remaining large-transfer bottleneck is still one encrypted-loop pass per OpenSSH channel-data/window packet.

## Follow-up: Skip Empty Response Append

After splitting the empty-response drain path, fragmented upload packets no longer call `append_pending_responses/2` unless an SFTP request completed and produced a response.

Commands used:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction upload --port 29351 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction upload --port 29352 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction upload --port 29353 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction download --port 29354 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction download --port 29355 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction download --port 29356 --limit 25
```

| Size | Direction | Elapsed | Profiled Throughput | Notes |
| ---: | --- | ---: | ---: | --- |
| 64 MiB | Upload | 0.254 s | 252.4 MiB/s | `append_pending_responses/2`: 262 calls |
| 1 GiB | Upload | 3.071 s | 333.4 MiB/s | `append_pending_responses/2`: 4,103 calls |
| 10 GiB | Upload | 21.055 s | 486.3 MiB/s | best large-upload cprof result in this series |
| 64 MiB | Download | 0.706 s | 90.7 MiB/s | neutral/noisy |
| 1 GiB | Download | 7.328 s | 139.7 MiB/s | no regression |
| 10 GiB | Download | 69.694 s | 146.9 MiB/s | best large-download cprof result in this series |

Interpretation:
- This removes one no-op function from every incomplete upload fragment.
- `append_pending_responses/2` now scales with completed SFTP requests rather than SSH channel-data fragments on upload.
- The remaining upload cost is the unavoidable receive/decrypt/dispatch loop per OpenSSH channel packet plus partial-packet bookkeeping.

## Baseline After Empty Response Append

After commit `4abce91` (`Skip empty SFTP response append`), the full cprof matrix was:

Commands used:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction download --port 29401 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction upload --port 29402 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction download --port 29403 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction upload --port 29404 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction download --port 29405 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction upload --port 29406 --limit 25
```

| Size | Direction | Elapsed | Profiled Throughput | Main hot shape |
| ---: | --- | ---: | ---: | --- |
| 64 MiB | Download | 0.665 s | 96.2 MiB/s | send/flush loop, 4,719 sends |
| 64 MiB | Upload | 0.186 s | 344.5 MiB/s | receive/decrypt/drain loop, 8,200 channel fragments |
| 1 GiB | Download | 8.348 s | 122.7 MiB/s | send/flush loop, 67,676 sends |
| 1 GiB | Upload | 2.823 s | 362.8 MiB/s | receive/decrypt/drain loop, 130,824 channel fragments |
| 10 GiB | Download | 77.319 s | 132.4 MiB/s | send/flush loop, 673,975 sends |
| 10 GiB | Upload | 24.311 s | 421.2 MiB/s | receive/decrypt/drain loop, 1,310,986 channel fragments |

Interpretation:
- Throughput is still noisy under `cprof`; call counts are more stable than elapsed time.
- Upload remains dominated by per-fragment receive/decrypt/dispatch and active-channel updates.
- Download remains dominated by OpenSSH channel packet/window cadence and encrypted send count.

## Follow-up: Direct Pending Response Check

After replacing the hot window-adjust `no_pending_responses?/1` helper call with a direct `channel.pending_responses == []` check, the full cprof matrix was:

Commands used:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction download --port 29431 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction upload --port 29432 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction download --port 29433 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction upload --port 29434 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction download --port 29435 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction upload --port 29436 --limit 25
```

| Size | Direction | Elapsed | Profiled Throughput | Notes |
| ---: | --- | ---: | ---: | --- |
| 64 MiB | Download | 0.743 s | 86.1 MiB/s | helper removed from hot rows |
| 64 MiB | Upload | 0.173 s | 368.9 MiB/s | upload mostly unaffected |
| 1 GiB | Download | 8.224 s | 124.5 MiB/s | helper removed from hot rows |
| 1 GiB | Upload | 2.755 s | 371.7 MiB/s | neutral/noisy |
| 10 GiB | Download | 77.909 s | 131.4 MiB/s | send calls: 673,176 |
| 10 GiB | Upload | 23.615 s | 433.6 MiB/s | neutral/noisy |

Interpretation:
- This is a small call-count cleanup on the window-adjust path.
- It removes an avoidable helper call from hundreds of thousands of download-side packets.
- The fundamental download limit remains encrypted send count and OpenSSH channel packet/window cadence.

## Follow-up: Skip EOF Close Checks During Normal Flushes

After guarding `maybe_close_eof_channel/3` behind a direct `channel.eof_received?` branch in the response flush path, the full cprof matrix was:

Commands used:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction download --port 29441 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 67108864 --direction upload --port 29442 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction download --port 29443 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 1073741824 --direction upload --port 29444 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction download --port 29445 --limit 25
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction upload --port 29446 --limit 25
```

| Size | Direction | Elapsed | Profiled Throughput | Notes |
| ---: | --- | ---: | ---: | --- |
| 64 MiB | Download | 0.797 s | 80.3 MiB/s | `maybe_close_eof_channel/3` removed from hot rows |
| 64 MiB | Upload | 0.163 s | 393.7 MiB/s | upload mostly unaffected |
| 1 GiB | Download | 8.071 s | 126.9 MiB/s | close helper removed from hot rows |
| 1 GiB | Upload | 2.152 s | 475.8 MiB/s | noisy strong run |
| 10 GiB | Download | 77.244 s | 132.6 MiB/s | close helper removed from hot rows |
| 10 GiB | Upload | 23.615 s | 433.6 MiB/s | neutral/noisy |

Interpretation:
- This removes a no-op EOF close check from every ordinary SFTP response flush.
- It is a call-count cleanup; the remaining transfer limit is still packet count and crypto/socket work.

## Inline window-adjust payload construction

After inlining SFTP window-adjust payload construction in the response flush path, the 10 GiB OpenSSH download profile was:

```sh
nix develop -c mix run -r test/support/ssh_keys.ex scripts/sftp_profile.exs --size 10737418240 --direction download --port 29860 --limit 35
```

| Size | Direction | Elapsed | Profiled Throughput | Notes |
| ---: | --- | ---: | ---: | --- |
| 10 GiB | Download | 71.701 s | 142.8 MiB/s | `maybe_add_window_adjust/2` removed from hot rows |

Top rows:

| function | calls |
| --- | ---: |
| `Sftpd.SSH.Server.cache_channel/2` | 1442716 |
| `Sftpd.SSH.Server.-send_encrypted_payloads/3-fun-0-/2` | 832596 |
| `Sftpd.SSH.Server.validate_encrypted_packet_length/1` | 721574 |
| `Sftpd.SSH.Server.recv_encrypted_payload/2` | 721574 |
| `Sftpd.SSH.Server.recv_encrypted_packet/3` | 721574 |
| `Sftpd.SSH.Server.handle_encrypted_payload/3` | 721574 |
| `Sftpd.SSH.Server.encrypted_loop/2` | 721574 |
| `Sftpd.SSH.Server.fetch_active_channel/2` | 721565 |
| `Sftpd.SSH.Server.prepend_sftp_response_payloads/3` | 721154 |
| `Sftpd.SSH.Server.flush_sftp_responses_with_channel/4` | 721154 |
| `Sftpd.SSH.Server.flush_sftp_responses/4` | 721154 |
| `Sftpd.SSH.Server.send_encrypted_payloads/3` | 680254 |

Interpretation:
- This is another small call-count cleanup in the ordinary SFTP flush loop.
- The remaining large download bottleneck is still the per-packet connection loop: active-channel cache writes, encrypted packet receive, response payload prep, and encrypted send.
