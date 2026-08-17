import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:daemon_dart/src/file_transfer/file_transfer_service.dart';
import 'package:daemon_dart/src/network/frame_codec.dart';
import 'package:daemon_dart/src/network/peer_write_gate.dart';
import 'package:daemon_dart/src/network/transport_impl.dart';

import 'benchmark_runner.dart';
import 'benchmark_support.dart';
import 'file_transfer_benchmark_harness.dart';

const benchmarkSuites = <String>{
  'cpu',
  'tls',
  'flush',
  'control',
  'bulk',
  'mixed',
  'file-service',
  'receiver',
  'logging',
};

const _kibibyte = 1024;
const _mebibyte = 1024 * 1024;
const _chunkSizes = <int>[
  64 * _kibibyte,
  128 * _kibibyte,
  256 * _kibibyte,
  512 * _kibibyte,
  1 * _mebibyte,
  2 * _mebibyte,
  4 * _mebibyte,
];
const _cpuSizes = <int>[
  64 * _kibibyte,
  256 * _kibibyte,
  512 * _kibibyte,
  1 * _mebibyte,
  2 * _mebibyte,
  4 * _mebibyte,
];

class BenchmarkWorkloadConfig {
  const BenchmarkWorkloadConfig({
    required this.warmUpIterations,
    required this.iterations,
    required this.quick,
    required this.suites,
  });

  final int warmUpIterations;
  final int iterations;
  final bool quick;
  final Set<String> suites;
}

class RiftBenchmarkWorkloads {
  RiftBenchmarkWorkloads(this.config);

  final BenchmarkWorkloadConfig config;
  final BenchmarkRunner _runner = BenchmarkRunner();
  final List<BenchmarkResult> _results = [];
  TlsLoopback? _tls;
  Directory? _temporaryDirectory;

  Future<List<BenchmarkResult>> run() async {
    _temporaryDirectory = await Directory.systemTemp.createTemp(
      'rift_benchmark_workloads_',
    );
    try {
      if (config.suites.contains('cpu')) await _runCpuSuite();
      if (_usesSharedTls) _tls = await TlsLoopback.open();
      if (config.suites.contains('tls')) await _runRawTlsSuite();
      if (config.suites.contains('flush')) await _runFlushSuite();
      if (config.suites.contains('control')) await _runControlSuite();
      if (config.suites.contains('bulk')) await _runBulkSuite();
      if (config.suites.contains('mixed')) await _runMixedChunkSuite();
      if (config.suites.contains('file-service')) {
        await _runFileServiceSuite();
      }
      if (config.suites.contains('receiver')) await _runReceiverSuite();
      if (config.suites.contains('logging')) await _runLoggingSuite();
      return List.unmodifiable(_results);
    } finally {
      await _tls?.close();
      final temporaryDirectory = _temporaryDirectory;
      if (temporaryDirectory != null && await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  }

  bool get _usesSharedTls => config.suites.intersection({
    'tls',
    'flush',
    'control',
    'bulk',
    'mixed',
  }).isNotEmpty;

  Future<BenchmarkResult> _measure({
    required String benchmark,
    required String variant,
    required int payloadBytes,
    required BenchmarkBody body,
  }) async {
    stderr.writeln(
      'running $benchmark/$variant payload=$payloadBytes '
      'warmup=${config.warmUpIterations} iterations=${config.iterations}',
    );
    final result = await _runner.run(
      BenchmarkDefinition(
        benchmark: benchmark,
        variant: variant,
        payloadBytes: payloadBytes,
        warmUpIterations: config.warmUpIterations,
        iterations: config.iterations,
        body: body,
      ),
    );
    _results.add(result);
    return result;
  }

  void _addAggregated({
    required String benchmark,
    required String variant,
    required int payloadBytes,
    required List<BenchmarkMeasurement> measurements,
  }) {
    _results.add(
      BenchmarkRunner.aggregate(
        BenchmarkDefinition(
          benchmark: benchmark,
          variant: variant,
          payloadBytes: payloadBytes,
          warmUpIterations: 0,
          iterations: measurements.length,
          body: () => throw UnsupportedError('Already measured.'),
        ),
        measurements,
      ),
    );
  }

  Future<void> _runCpuSuite() async {
    final sizes = config.quick
        ? const [64 * _kibibyte, 256 * _kibibyte]
        : _cpuSizes;
    final targetBytes = config.quick ? 2 * _mebibyte : 32 * _mebibyte;

    for (final size in sizes) {
      final bytes = deterministicBytes(size);
      final operations = math.max(1, (targetBytes / size).ceil());
      await _measure(
        benchmark: 'encoding/sha256',
        variant: 'raw-chunk',
        payloadBytes: size,
        body: () async {
          var checksum = 0;
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            final digest = sha256.convert(bytes);
            checksum ^= digest.bytes[i % digest.bytes.length];
          }
          watch.stop();
          _consume(checksum);
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: size * operations,
            rawFileBytes: size * operations,
          );
        },
      );

      await _measure(
        benchmark: 'encoding/base64',
        variant: 'encode',
        payloadBytes: size,
        body: () async {
          var encodedLength = 0;
          var checksum = 0;
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            final encoded = base64.encode(bytes);
            encodedLength += encoded.length;
            checksum ^= encoded.codeUnitAt(i % encoded.length);
          }
          watch.stop();
          _consume(checksum);
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: size * operations,
            rawFileBytes: size * operations,
            wireBytes: encodedLength,
            metrics: {'amplification': encodedLength / (size * operations)},
          );
        },
      );

      final contentBase64 = base64.encode(bytes);
      final chunkHash = sha256.convert(bytes).toString();
      await _measure(
        benchmark: 'encoding/chunk-envelope',
        variant: 'map-json-utf8',
        payloadBytes: size,
        body: () async {
          var wireBytes = 0;
          var checksum = 0;
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            final envelope = chunkEnvelope(
              rawBytes: bytes,
              chunkSha256: chunkHash,
              chunkIndex: i,
              offset: i * size,
              isLastChunk: i == operations - 1,
              contentBase64: contentBase64,
            );
            final encoded = utf8.encode(json.encode(envelope));
            wireBytes += encoded.length;
            checksum ^= encoded[(i * 31) % encoded.length];
          }
          watch.stop();
          _consume(checksum);
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: size * operations,
            rawFileBytes: size * operations,
            wireBytes: wireBytes,
            metrics: {'amplification': wireBytes / (size * operations)},
          );
        },
      );

      final serialized = Uint8List.fromList(
        utf8.encode(
          json.encode(
            chunkEnvelope(
              rawBytes: bytes,
              chunkSha256: chunkHash,
              chunkIndex: 0,
              offset: 0,
              isLastChunk: true,
              contentBase64: contentBase64,
            ),
          ),
        ),
      );
      await _measure(
        benchmark: 'encoding/outbound-validation',
        variant: 'utf8-json-object',
        payloadBytes: size,
        body: () async {
          var checksum = 0;
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            final decoded = json.decode(utf8.decode(serialized));
            if (decoded is! Map<String, dynamic>) {
              throw StateError('Validation benchmark decoded a non-object.');
            }
            checksum ^= (decoded['type'] as String).length + i;
          }
          watch.stop();
          _consume(checksum);
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: size * operations,
            rawFileBytes: size * operations,
            wireBytes: serialized.length * operations,
          );
        },
      );

      await _measure(
        benchmark: 'encoding/rift-frame',
        variant: 'encode-bytes',
        payloadBytes: size,
        body: () async {
          var framedBytes = 0;
          var checksum = 0;
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            final frame = RiftFrameCodec.encodeBytes(serialized);
            framedBytes += frame.length;
            checksum ^= frame[(i * 17) % frame.length];
          }
          watch.stop();
          _consume(checksum);
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: size * operations,
            rawFileBytes: size * operations,
            wireBytes: framedBytes,
          );
        },
      );
    }
  }

  Future<void> _runRawTlsSuite() async {
    final tls = _tls!;
    final sizes = config.quick
        ? const [1024, 64 * _kibibyte, 256 * _kibibyte]
        : const [
            1024,
            16 * _kibibyte,
            64 * _kibibyte,
            256 * _kibibyte,
            1 * _mebibyte,
            4 * _mebibyte,
          ];
    final targetBytes = config.quick ? 4 * _mebibyte : 64 * _mebibyte;
    for (final size in sizes) {
      final payload = deterministicBytes(size, seed: 0x544c5300 + size);
      for (final policy in const [
        _FlushPolicy.everyFrame,
        _FlushPolicy.finalOnly,
      ]) {
        await _measure(
          benchmark: 'transport/tls-raw',
          variant: policy.label,
          payloadBytes: size,
          body: () => _writeRepeatedFrames(
            tls: tls,
            frame: payload,
            rawBytesPerFrame: size,
            targetRawBytes: targetBytes,
            policy: policy,
            sampleRss: size >= _mebibyte,
          ),
        );
      }
    }
  }

  Future<void> _runFlushSuite() async {
    const rawSize = 256 * _kibibyte;
    final raw = deterministicBytes(rawSize);
    final serialized = _serializedChunk(raw);
    final frame = RiftFrameCodec.encodeBytes(serialized);
    final targetBytes = config.quick ? 4 * _mebibyte : 64 * _mebibyte;
    for (final policy in _FlushPolicy.values) {
      await _measure(
        benchmark: 'transport/framed-flush-policy',
        variant: policy.label,
        payloadBytes: rawSize,
        body: () => _writeRepeatedFrames(
          tls: _tls!,
          frame: frame,
          rawBytesPerFrame: rawSize,
          targetRawBytes: targetBytes,
          policy: policy,
          sampleRss: true,
        ),
      );
    }
  }

  Future<void> _runControlSuite() async {
    final operations = config.quick ? 50 : 500;
    for (final payloadSize in const [512, 2 * _kibibyte, 16 * _kibibyte]) {
      final frame = RiftFrameCodec.encodeBytes(jsonPayloadOfSize(payloadSize));
      await _measure(
        benchmark: 'transport/control-idle',
        variant: 'add-flush-every-frame',
        payloadBytes: payloadSize,
        body: () async {
          final tls = _tls!;
          final receiveTarget = tls.receivedBytes + frame.length * operations;
          final latencies = <int>[];
          var addUs = 0;
          var flushUs = 0;
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            final operationWatch = Stopwatch()..start();
            final addWatch = Stopwatch()..start();
            tls.sender.add(frame);
            addWatch.stop();
            addUs += addWatch.elapsedMicroseconds;
            final flushWatch = Stopwatch()..start();
            await tls.sender.flush();
            flushWatch.stop();
            flushUs += flushWatch.elapsedMicroseconds;
            operationWatch.stop();
            latencies.add(math.max(1, operationWatch.elapsedMicroseconds));
          }
          await tls.waitForReceived(receiveTarget);
          watch.stop();
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: payloadSize * operations,
            wireBytes: frame.length * operations,
            latenciesUs: latencies,
            metrics: {
              'addUs': addUs,
              'flushUs': flushUs,
              'flushCalls': operations,
            },
          );
        },
      );
    }
  }

  Future<void> _runBulkSuite() async {
    const rawSize = 256 * _kibibyte;
    final frame = RiftFrameCodec.encodeBytes(
      _serializedChunk(deterministicBytes(rawSize)),
    );
    await _measure(
      benchmark: 'transport/sustained-bulk',
      variant: 'current-writer',
      payloadBytes: rawSize,
      body: () => _writeRepeatedFrames(
        tls: _tls!,
        frame: frame,
        rawBytesPerFrame: rawSize,
        targetRawBytes: config.quick ? 4 * _mebibyte : 64 * _mebibyte,
        policy: _FlushPolicy.everyFrame,
        sampleRss: true,
      ),
    );
  }

  Future<void> _runMixedChunkSuite() async {
    final transferBytes = config.quick ? 4 * _mebibyte : 64 * _mebibyte;
    final file = await createDeterministicFile(
      _temporaryDirectory!,
      'mixed-$transferBytes.bin',
      transferBytes,
    );
    final chunkSizes = config.quick
        ? const [64 * _kibibyte, 256 * _kibibyte, 1 * _mebibyte]
        : _chunkSizes;
    for (final chunkSize in chunkSizes) {
      await _measure(
        benchmark: 'file-pipeline/chunk-size',
        variant: 'current-writer-mixed-control',
        payloadBytes: chunkSize,
        body: () => _runMixedTransfer(
          file: file,
          fileBytes: transferBytes,
          chunkSize: chunkSize,
        ),
      );
    }
  }

  Future<BenchmarkMeasurement> _runMixedTransfer({
    required File file,
    required int fileBytes,
    required int chunkSize,
  }) async {
    final tls = _tls!;
    final gate = PeerWriteGate();
    final controlFrame = RiftFrameCodec.encodeBytes(jsonPayloadOfSize(1024));
    final chunkCount = (fileBytes / chunkSize).ceil();
    final controlInterval = math.max(1, (chunkCount / 16).ceil());
    final controlLatencies = <int>[];
    final sampler = RssSampler.start();
    final raf = await file.open();
    var offset = 0;
    var chunkIndex = 0;
    var wireBytes = 0;
    var fileReadUs = 0;
    var sha256Us = 0;
    var base64Us = 0;
    var jsonUs = 0;
    var validationUs = 0;
    var framingUs = 0;
    var tlsAddUs = 0;
    var tlsFlushUs = 0;
    var flushCalls = 0;
    var maxChunkUs = 0;
    final receiveStart = tls.receivedBytes;
    final totalWatch = Stopwatch()..start();
    try {
      while (offset < fileBytes) {
        final chunkWatch = Stopwatch()..start();
        final remaining = fileBytes - offset;
        final readSize = math.min(chunkSize, remaining);

        final stage = Stopwatch()..start();
        final bytes = await raf.read(readSize);
        stage.stop();
        fileReadUs += stage.elapsedMicroseconds;
        if (bytes.length != readSize) {
          throw StateError(
            'File benchmark read ${bytes.length} of $readSize bytes.',
          );
        }

        stage
          ..reset()
          ..start();
        final chunkHash = sha256.convert(bytes).toString();
        stage.stop();
        sha256Us += stage.elapsedMicroseconds;

        stage
          ..reset()
          ..start();
        final contentBase64 = base64.encode(bytes);
        stage.stop();
        base64Us += stage.elapsedMicroseconds;

        stage
          ..reset()
          ..start();
        final serialized = Uint8List.fromList(
          utf8.encode(
            json.encode(
              chunkEnvelope(
                rawBytes: bytes,
                chunkSha256: chunkHash,
                chunkIndex: chunkIndex,
                offset: offset,
                isLastChunk: offset + bytes.length == fileBytes,
                contentBase64: contentBase64,
              ),
            ),
          ),
        );
        stage.stop();
        jsonUs += stage.elapsedMicroseconds;

        stage
          ..reset()
          ..start();
        final decoded = json.decode(utf8.decode(serialized));
        if (decoded is! Map<String, dynamic>) {
          throw StateError('Outbound chunk validation produced a non-object.');
        }
        stage.stop();
        validationUs += stage.elapsedMicroseconds;

        stage
          ..reset()
          ..start();
        final frame = RiftFrameCodec.encodeBytes(serialized);
        stage.stop();
        framingUs += stage.elapsedMicroseconds;
        wireBytes += frame.length;

        final bulkWrite = gate.run(() async {
          final addWatch = Stopwatch()..start();
          tls.sender.add(frame);
          addWatch.stop();
          tlsAddUs += addWatch.elapsedMicroseconds;
          final flushWatch = Stopwatch()..start();
          await tls.sender.flush();
          flushWatch.stop();
          tlsFlushUs += flushWatch.elapsedMicroseconds;
          flushCalls++;
        });

        if (chunkIndex % controlInterval == 0) {
          final controlWatch = Stopwatch()..start();
          final controlWrite = gate.run(() async {
            final addWatch = Stopwatch()..start();
            tls.sender.add(controlFrame);
            addWatch.stop();
            tlsAddUs += addWatch.elapsedMicroseconds;
            final flushWatch = Stopwatch()..start();
            await tls.sender.flush();
            flushWatch.stop();
            tlsFlushUs += flushWatch.elapsedMicroseconds;
            flushCalls++;
          });
          wireBytes += controlFrame.length;
          await Future.wait([bulkWrite, controlWrite]);
          controlWatch.stop();
          controlLatencies.add(math.max(1, controlWatch.elapsedMicroseconds));
        } else {
          await bulkWrite;
        }

        offset += bytes.length;
        chunkIndex++;
        chunkWatch.stop();
        maxChunkUs = math.max(maxChunkUs, chunkWatch.elapsedMicroseconds);
      }
      await tls.waitForReceived(receiveStart + wireBytes);
    } finally {
      await raf.close();
      totalWatch.stop();
      sampler.stop();
    }
    if (offset != fileBytes || chunkIndex != chunkCount) {
      throw StateError('File benchmark did not consume the exact input file.');
    }

    final elapsedUs = math.max(1, totalWatch.elapsedMicroseconds);
    return BenchmarkMeasurement(
      elapsed: totalWatch.elapsed,
      operations: chunkCount,
      throughputBytes: fileBytes,
      rawFileBytes: fileBytes,
      wireBytes: wireBytes,
      rssBefore: sampler.rssBefore,
      rssPeak: sampler.rssPeak,
      rssAfter: sampler.rssAfter,
      latenciesUs: controlLatencies,
      metrics: {
        'fileReadUs': fileReadUs,
        'sha256Us': sha256Us,
        'base64Us': base64Us,
        'jsonUs': jsonUs,
        'validationUs': validationUs,
        'framingUs': framingUs,
        'tlsAddUs': tlsAddUs,
        'tlsFlushUs': tlsFlushUs,
        'fileReadPercent': fileReadUs * 100 / elapsedUs,
        'sha256Percent': sha256Us * 100 / elapsedUs,
        'base64Percent': base64Us * 100 / elapsedUs,
        'jsonPercent': jsonUs * 100 / elapsedUs,
        'validationPercent': validationUs * 100 / elapsedUs,
        'framingPercent': framingUs * 100 / elapsedUs,
        'tlsAddPercent': tlsAddUs * 100 / elapsedUs,
        'tlsFlushPercent': tlsFlushUs * 100 / elapsedUs,
        'flushCalls': flushCalls,
        'controlMessages': controlLatencies.length,
        'maxQueuedFrames': 2,
        'maxChunkUs': maxChunkUs,
        'wireAmplification': wireBytes / fileBytes,
      },
    );
  }

  Future<void> _runFileServiceSuite() async {
    final harness = await FileTransferBenchmarkHarness.open();
    try {
      final sizes = config.quick
          ? const [1 * _mebibyte]
          : const [1 * _mebibyte, 16 * _mebibyte, 64 * _mebibyte];
      for (final size in sizes) {
        final file = await createDeterministicFile(
          harness.temporaryDirectory,
          'sender-$size.bin',
          size,
        );
        stderr.writeln(
          'running file-service sender payload=$size '
          'warmup=${config.warmUpIterations} iterations=${config.iterations}',
        );
        for (var i = 0; i < config.warmUpIterations; i++) {
          await harness.runSenderPipeline(
            file: file,
            acceptedChunkSize: FileTransferService.defaultChunkSize,
          );
        }
        final offerMeasurements = <BenchmarkMeasurement>[];
        final activeMeasurements = <BenchmarkMeasurement>[];
        final totalMeasurements = <BenchmarkMeasurement>[];
        for (var i = 0; i < config.iterations; i++) {
          final sampler = RssSampler.start();
          final measurement = await harness.runSenderPipeline(
            file: file,
            acceptedChunkSize: FileTransferService.defaultChunkSize,
          );
          sampler.stop();
          final metrics = <String, num>{
            'messagesGenerated': measurement.activeMessages,
            'chunkMessages': measurement.chunkMessages,
            'maxOutstandingSends': measurement.maxOutstandingSends,
          };
          offerMeasurements.add(
            BenchmarkMeasurement(
              elapsed: measurement.offerElapsed,
              operations: 1,
              throughputBytes: size,
              rawFileBytes: size,
              rssBefore: sampler.rssBefore,
              rssPeak: sampler.rssPeak,
              rssAfter: sampler.rssAfter,
              metrics: metrics,
            ),
          );
          activeMeasurements.add(
            BenchmarkMeasurement(
              elapsed: measurement.activeElapsed,
              operations: measurement.chunkMessages,
              throughputBytes: size,
              rawFileBytes: size,
              wireBytes: measurement.activeWireBytes,
              rssBefore: sampler.rssBefore,
              rssPeak: sampler.rssPeak,
              rssAfter: sampler.rssAfter,
              metrics: metrics,
            ),
          );
          totalMeasurements.add(
            BenchmarkMeasurement(
              elapsed: measurement.totalElapsed,
              operations: measurement.activeMessages + 1,
              throughputBytes: size,
              rawFileBytes: size,
              wireBytes: measurement.activeWireBytes,
              rssBefore: sampler.rssBefore,
              rssPeak: sampler.rssPeak,
              rssAfter: sampler.rssAfter,
              metrics: metrics,
            ),
          );
        }
        _addAggregated(
          benchmark: 'file-service/offer-preparation',
          variant: 'whole-file-hash-and-offer',
          payloadBytes: size,
          measurements: offerMeasurements,
        );
        _addAggregated(
          benchmark: 'file-service/active-transfer',
          variant: 'default-256k',
          payloadBytes: size,
          measurements: activeMeasurements,
        );
        _addAggregated(
          benchmark: 'file-service/total',
          variant: 'default-256k',
          payloadBytes: size,
          measurements: totalMeasurements,
        );
      }
    } finally {
      await harness.close();
    }
  }

  Future<void> _runReceiverSuite() async {
    final sizes = config.quick ? const [256 * _kibibyte] : _cpuSizes;
    final targetBytes = config.quick ? 2 * _mebibyte : 16 * _mebibyte;
    for (final size in sizes) {
      final raw = deterministicBytes(size, seed: 0x52454300 + size);
      final encoded = base64.encode(raw);
      final expectedHash = sha256.convert(raw).toString();
      final operations = math.max(1, (targetBytes / size).ceil());

      await _measure(
        benchmark: 'receiver/base64',
        variant: 'decode',
        payloadBytes: size,
        body: () async {
          var checksum = 0;
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            final decoded = base64.decode(encoded);
            if (decoded.length != size) {
              throw StateError('Base64 receiver benchmark length mismatch.');
            }
            checksum ^= decoded[i % decoded.length];
          }
          watch.stop();
          _consume(checksum);
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: size * operations,
            rawFileBytes: size * operations,
            wireBytes: encoded.length * operations,
          );
        },
      );

      await _measure(
        benchmark: 'receiver/sha256',
        variant: 'verify',
        payloadBytes: size,
        body: () async {
          var checksum = 0;
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            final actual = sha256.convert(raw).toString();
            if (actual != expectedHash) {
              throw StateError('SHA-256 receiver benchmark mismatch.');
            }
            checksum ^= actual.codeUnitAt(i % actual.length);
          }
          watch.stop();
          _consume(checksum);
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: size * operations,
            rawFileBytes: size * operations,
          );
        },
      );

      await _measure(
        benchmark: 'receiver/staging-file',
        variant: 'open-append-close-per-chunk',
        payloadBytes: size,
        body: () async {
          final file = File(
            '${_temporaryDirectory!.path}${Platform.pathSeparator}receiver-$size.tmp',
          );
          if (await file.exists()) await file.delete();
          final sampler = RssSampler.start();
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            final output = await file.open(mode: FileMode.append);
            try {
              await output.writeFrom(raw);
            } finally {
              await output.close();
            }
          }
          watch.stop();
          sampler.stop();
          final written = await file.length();
          await file.delete();
          if (written != size * operations) {
            throw StateError('Staging-file benchmark wrote $written bytes.');
          }
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: written,
            rawFileBytes: written,
            rssBefore: sampler.rssBefore,
            rssPeak: sampler.rssPeak,
            rssAfter: sampler.rssAfter,
          );
        },
      );
    }
  }

  Future<void> _runLoggingSuite() async {
    final tls = await TlsLoopback.open();
    final transport = TransportImpl(tls.senderIdentity, port: 0);
    const peerDeviceId = 'rift-benchmark-peer';
    // The benchmark intentionally uses the transport's existing lifecycle-test seam.
    // ignore: invalid_use_of_visible_for_testing_member
    transport.injectConnectionForTesting(peerDeviceId, tls.sender);
    final payload = jsonPayloadOfSize(2 * _kibibyte);
    final operations = config.quick ? 32 : 128;
    try {
      await _measure(
        benchmark: 'transport/per-message-logging',
        variant: 'production',
        payloadBytes: payload.length,
        body: () async {
          final receiveTarget =
              tls.receivedBytes + (payload.length + 4) * operations;
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            await transport.sendMessage(peerDeviceId, payload);
          }
          await tls.waitForReceived(receiveTarget);
          watch.stop();
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: payload.length * operations,
            wireBytes: (payload.length + 4) * operations,
            metrics: {'logEvents': operations * 2},
          );
        },
      );

      final gate = PeerWriteGate();
      await _measure(
        benchmark: 'transport/per-message-logging',
        variant: 'no-per-message-log-equivalent',
        payloadBytes: payload.length,
        body: () async {
          final receiveTarget =
              tls.receivedBytes + (payload.length + 4) * operations;
          final watch = Stopwatch()..start();
          for (var i = 0; i < operations; i++) {
            final decoded = json.decode(utf8.decode(payload));
            if (decoded is! Map<String, dynamic>) {
              throw StateError('Logging benchmark payload was not an object.');
            }
            final frame = RiftFrameCodec.encodeBytes(payload);
            await gate.run(() async {
              tls.sender.add(frame);
              await tls.sender.flush();
            });
          }
          await tls.waitForReceived(receiveTarget);
          watch.stop();
          return BenchmarkMeasurement(
            elapsed: watch.elapsed,
            operations: operations,
            throughputBytes: payload.length * operations,
            wireBytes: (payload.length + 4) * operations,
            metrics: {'logEvents': 0},
          );
        },
      );
    } finally {
      await transport.stopServer();
      await tls.close();
    }
  }

  Future<BenchmarkMeasurement> _writeRepeatedFrames({
    required TlsLoopback tls,
    required Uint8List frame,
    required int rawBytesPerFrame,
    required int targetRawBytes,
    required _FlushPolicy policy,
    required bool sampleRss,
  }) async {
    final operations = math.max(1, (targetRawBytes / rawBytesPerFrame).ceil());
    final receiveTarget = tls.receivedBytes + frame.length * operations;
    final sampler = RssSampler.start(enabled: sampleRss);
    final latencies = <int>[];
    var addUs = 0;
    var flushUs = 0;
    var flushCalls = 0;
    var bytesSinceFlush = 0;
    final watch = Stopwatch()..start();
    for (var i = 0; i < operations; i++) {
      final operationWatch = Stopwatch()..start();
      final addWatch = Stopwatch()..start();
      tls.sender.add(frame);
      addWatch.stop();
      addUs += addWatch.elapsedMicroseconds;
      bytesSinceFlush += frame.length;
      final isLast = i == operations - 1;
      final shouldFlush = policy.shouldFlush(
        frameIndex: i,
        bytesSinceFlush: bytesSinceFlush,
        isLast: isLast,
      );
      if (shouldFlush) {
        final flushWatch = Stopwatch()..start();
        await tls.sender.flush();
        flushWatch.stop();
        flushUs += flushWatch.elapsedMicroseconds;
        flushCalls++;
        bytesSinceFlush = 0;
      }
      operationWatch.stop();
      if (policy == _FlushPolicy.everyFrame) {
        latencies.add(math.max(1, operationWatch.elapsedMicroseconds));
      }
    }
    await tls.waitForReceived(receiveTarget);
    watch.stop();
    sampler.stop();
    return BenchmarkMeasurement(
      elapsed: watch.elapsed,
      operations: operations,
      throughputBytes: rawBytesPerFrame * operations,
      rawFileBytes: rawBytesPerFrame * operations,
      wireBytes: frame.length * operations,
      rssBefore: sampler.rssBefore,
      rssPeak: sampler.rssPeak,
      rssAfter: sampler.rssAfter,
      latenciesUs: latencies,
      metrics: {
        'addUs': addUs,
        'flushUs': flushUs,
        'flushCalls': flushCalls,
        'frames': operations,
        'wireAmplification':
            frame.length * operations / (rawBytesPerFrame * operations),
      },
    );
  }

  Uint8List _serializedChunk(Uint8List raw) {
    final hash = sha256.convert(raw).toString();
    return Uint8List.fromList(
      utf8.encode(
        json.encode(
          chunkEnvelope(
            rawBytes: raw,
            chunkSha256: hash,
            chunkIndex: 0,
            offset: 0,
            isLastChunk: true,
          ),
        ),
      ),
    );
  }
}

enum _FlushPolicy {
  everyFrame('flush-every-frame'),
  finalOnly('one-final-flush'),
  everyFourFrames('flush-every-4-frames'),
  oneMebibyte('flush-every-1mib');

  const _FlushPolicy(this.label);

  final String label;

  bool shouldFlush({
    required int frameIndex,
    required int bytesSinceFlush,
    required bool isLast,
  }) => switch (this) {
    _FlushPolicy.everyFrame => true,
    _FlushPolicy.finalOnly => isLast,
    _FlushPolicy.everyFourFrames => (frameIndex + 1) % 4 == 0 || isLast,
    _FlushPolicy.oneMebibyte => bytesSinceFlush >= _mebibyte || isLast,
  };
}

int _consumeSink = 0;

void _consume(int value) {
  _consumeSink = (_consumeSink ^ value) & 0x7fffffff;
  if (_consumeSink == -1) throw StateError('Unreachable consume sink.');
}
