# Dart transport and file-transfer benchmarks

Run the smoke workload from `daemon-dart/`:

```sh
dart run benchmark/transport_file_transfer_benchmark.dart --quick
```

Capture a full machine-readable baseline:

```sh
dart run benchmark/transport_file_transfer_benchmark.dart \
  --json > /tmp/rift-baseline.json
```

Compare a later run made on the same machine and in the same runtime mode:

```sh
dart run benchmark/transport_file_transfer_benchmark.dart \
  --compare /tmp/rift-baseline.json
```

For production logging comparisons, compile both revisions as AOT executables so
`dart.vm.product` matches deployed behavior:

```sh
dart compile exe benchmark/transport_file_transfer_benchmark.dart \
  -o /tmp/rift-benchmark
/tmp/rift-benchmark --suite logging --json > /tmp/rift-logging.json
```

The default run uses two warm-up and five measured iterations. `--quick` uses
smaller workloads with one warm-up and one measured iteration. Override these
with `--warmup N` and `--iterations N`. Use `--suite` to select any combination
of `cpu`, `tls`, `flush`, `control`, `bulk`, `mixed`, `file-service`, `receiver`,
or `logging`.

The suites measure:

- SHA-256, Base64, realistic file-chunk JSON, outbound JSON validation, and Rift
  frame encoding independently;
- actual loopback `SecureSocket` throughput and benchmark-only flush policies;
- idle control-message latency and sustained framed throughput;
- the 64 KiB through 4 MiB chunk-size matrix, with per-stage timings, sampled
  RSS, and control messages queued behind bulk frames;
- `FileTransferService` offer hashing and active sender throughput with the
  negotiated 256 KiB baseline;
- receiver Base64 decode, SHA-256 verification, and the production
  open/append/close staging-file pattern;
- the production `TransportImpl.sendMessage()` logging path against an
  otherwise equivalent no-per-message-log path.

Generated file data is deterministic and non-zero. File generation, identity
creation, certificate generation, and TLS handshakes occur outside measured
regions. Network iterations complete only after the receiver observes the exact
reported wire-byte count. Large asynchronous workloads sample starting, peak,
and ending RSS; latency microbenchmarks avoid the sampler.

Flush variants other than `flush-every-frame` are experiments only. They do not
change `sendMessage()` completion, backpressure, or ordering semantics. Do not
compare results from different machines, runtime modes, suite selections, or
workload settings as if they were a controlled before/after measurement.
