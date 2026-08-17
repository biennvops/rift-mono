import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

typedef BenchmarkBody = Future<BenchmarkMeasurement> Function();

class BenchmarkDefinition {
  const BenchmarkDefinition({
    required this.benchmark,
    required this.variant,
    required this.payloadBytes,
    required this.warmUpIterations,
    required this.iterations,
    required this.body,
  });

  final String benchmark;
  final String variant;
  final int payloadBytes;
  final int warmUpIterations;
  final int iterations;
  final BenchmarkBody body;
}

class BenchmarkMeasurement {
  const BenchmarkMeasurement({
    required this.elapsed,
    required this.operations,
    required this.throughputBytes,
    this.rawFileBytes = 0,
    this.wireBytes = 0,
    this.rssBefore = 0,
    this.rssPeak = 0,
    this.rssAfter = 0,
    this.latenciesUs = const [],
    this.metrics = const {},
  });

  final Duration elapsed;
  final int operations;
  final int throughputBytes;
  final int rawFileBytes;
  final int wireBytes;
  final int rssBefore;
  final int rssPeak;
  final int rssAfter;
  final List<int> latenciesUs;
  final Map<String, num> metrics;
}

class BenchmarkResult {
  const BenchmarkResult({
    required this.benchmark,
    required this.variant,
    required this.payloadBytes,
    required this.operations,
    required this.iterations,
    required this.medianUs,
    required this.p95Us,
    required this.p99Us,
    required this.minUs,
    required this.maxUs,
    required this.elapsedUs,
    required this.throughputBytesPerSecond,
    required this.rawThroughputBytesPerSecond,
    required this.wireThroughputBytesPerSecond,
    required this.rawFileBytes,
    required this.wireBytes,
    required this.rssBefore,
    required this.rssPeak,
    required this.rssAfter,
    required this.metrics,
  });

  final String benchmark;
  final String variant;
  final int payloadBytes;
  final int operations;
  final int iterations;
  final double medianUs;
  final double p95Us;
  final double p99Us;
  final int minUs;
  final int maxUs;
  final double elapsedUs;
  final double throughputBytesPerSecond;
  final double rawThroughputBytesPerSecond;
  final double wireThroughputBytesPerSecond;
  final int rawFileBytes;
  final int wireBytes;
  final int rssBefore;
  final int rssPeak;
  final int rssAfter;
  final Map<String, double> metrics;

  String get key => '$benchmark\u0000$variant\u0000$payloadBytes';

  Map<String, Object> toJson() => {
    'benchmark': benchmark,
    'variant': variant,
    'payloadBytes': payloadBytes,
    'operations': operations,
    'iterations': iterations,
    'medianUs': medianUs,
    'p95Us': p95Us,
    'p99Us': p99Us,
    'minUs': minUs,
    'maxUs': maxUs,
    'elapsedUs': elapsedUs,
    'throughputBytesPerSecond': throughputBytesPerSecond,
    'rawThroughputBytesPerSecond': rawThroughputBytesPerSecond,
    'wireThroughputBytesPerSecond': wireThroughputBytesPerSecond,
    'rawFileBytes': rawFileBytes,
    'wireBytes': wireBytes,
    'rssBefore': rssBefore,
    'rssPeak': rssPeak,
    'rssAfter': rssAfter,
    'metrics': metrics,
  };

  factory BenchmarkResult.fromJson(Map<String, dynamic> json) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    int integer(String key) => (json[key] as num?)?.toInt() ?? 0;
    final rawMetrics = json['metrics'];
    final metrics = <String, double>{};
    if (rawMetrics is Map<String, dynamic>) {
      for (final entry in rawMetrics.entries) {
        final value = entry.value;
        if (value is num) metrics[entry.key] = value.toDouble();
      }
    }
    return BenchmarkResult(
      benchmark: json['benchmark'] as String,
      variant: json['variant'] as String,
      payloadBytes: integer('payloadBytes'),
      operations: integer('operations'),
      iterations: integer('iterations'),
      medianUs: number('medianUs'),
      p95Us: number('p95Us'),
      p99Us: number('p99Us'),
      minUs: integer('minUs'),
      maxUs: integer('maxUs'),
      elapsedUs: number('elapsedUs'),
      throughputBytesPerSecond: number('throughputBytesPerSecond'),
      rawThroughputBytesPerSecond: number('rawThroughputBytesPerSecond'),
      wireThroughputBytesPerSecond: number('wireThroughputBytesPerSecond'),
      rawFileBytes: integer('rawFileBytes'),
      wireBytes: integer('wireBytes'),
      rssBefore: integer('rssBefore'),
      rssPeak: integer('rssPeak'),
      rssAfter: integer('rssAfter'),
      metrics: metrics,
    );
  }
}

class BenchmarkRunner {
  Future<BenchmarkResult> run(BenchmarkDefinition definition) async {
    for (var i = 0; i < definition.warmUpIterations; i++) {
      await definition.body();
    }

    final measurements = <BenchmarkMeasurement>[];
    for (var i = 0; i < definition.iterations; i++) {
      measurements.add(await definition.body());
    }
    return aggregate(definition, measurements);
  }

  static BenchmarkResult aggregate(
    BenchmarkDefinition definition,
    List<BenchmarkMeasurement> measurements,
  ) {
    if (measurements.isEmpty) {
      throw ArgumentError.value(
        measurements,
        'measurements',
        'must not be empty',
      );
    }

    final latencies = <int>[];
    for (final measurement in measurements) {
      if (measurement.latenciesUs.isEmpty) {
        latencies.add(math.max(1, measurement.elapsed.inMicroseconds));
      } else {
        latencies.addAll(
          measurement.latenciesUs.map((value) => math.max(1, value)),
        );
      }
    }
    latencies.sort();

    final elapsedValues =
        measurements
            .map(
              (measurement) => math.max(1, measurement.elapsed.inMicroseconds),
            )
            .toList(growable: false)
          ..sort();
    final throughputValues =
        measurements
            .map(
              (measurement) =>
                  measurement.throughputBytes *
                  Duration.microsecondsPerSecond /
                  math.max(1, measurement.elapsed.inMicroseconds),
            )
            .toList(growable: false)
          ..sort();
    final rawThroughputValues =
        measurements
            .map(
              (measurement) =>
                  measurement.rawFileBytes *
                  Duration.microsecondsPerSecond /
                  math.max(1, measurement.elapsed.inMicroseconds),
            )
            .toList(growable: false)
          ..sort();
    final wireThroughputValues =
        measurements
            .map(
              (measurement) =>
                  measurement.wireBytes *
                  Duration.microsecondsPerSecond /
                  math.max(1, measurement.elapsed.inMicroseconds),
            )
            .toList(growable: false)
          ..sort();

    final metricNames = measurements
        .expand((measurement) => measurement.metrics.keys)
        .toSet();
    final metrics = <String, double>{};
    for (final name in metricNames) {
      final values =
          measurements
              .map((measurement) => measurement.metrics[name]?.toDouble())
              .whereType<double>()
              .toList(growable: false)
            ..sort();
      metrics[name] = _median(values);
    }

    return BenchmarkResult(
      benchmark: definition.benchmark,
      variant: definition.variant,
      payloadBytes: definition.payloadBytes,
      operations: _medianInt(
        measurements.map((measurement) => measurement.operations).toList(),
      ),
      iterations: measurements.length,
      medianUs: _median(latencies.map((value) => value.toDouble()).toList()),
      p95Us: _percentile(latencies, 0.95).toDouble(),
      p99Us: _percentile(latencies, 0.99).toDouble(),
      minUs: latencies.first,
      maxUs: latencies.last,
      elapsedUs: _median(
        elapsedValues.map((value) => value.toDouble()).toList(),
      ),
      throughputBytesPerSecond: _median(throughputValues),
      rawThroughputBytesPerSecond: _median(rawThroughputValues),
      wireThroughputBytesPerSecond: _median(wireThroughputValues),
      rawFileBytes: _medianInt(
        measurements.map((measurement) => measurement.rawFileBytes).toList(),
      ),
      wireBytes: _medianInt(
        measurements.map((measurement) => measurement.wireBytes).toList(),
      ),
      rssBefore: _medianInt(
        measurements.map((measurement) => measurement.rssBefore).toList(),
      ),
      rssPeak: measurements
          .map((measurement) => measurement.rssPeak)
          .reduce(math.max),
      rssAfter: _medianInt(
        measurements.map((measurement) => measurement.rssAfter).toList(),
      ),
      metrics: metrics,
    );
  }

  static double _median(List<double> values) {
    if (values.isEmpty) return 0;
    values.sort();
    final middle = values.length ~/ 2;
    if (values.length.isOdd) return values[middle];
    return (values[middle - 1] + values[middle]) / 2;
  }

  static int _medianInt(List<int> values) {
    if (values.isEmpty) return 0;
    values.sort();
    return values[(values.length - 1) ~/ 2];
  }

  static int _percentile(List<int> sortedValues, double percentile) {
    final rank = (percentile * sortedValues.length).ceil() - 1;
    return sortedValues[rank.clamp(0, sortedValues.length - 1)];
  }
}

class RssSampler {
  RssSampler._(this.rssBefore, this._timer) : rssPeak = rssBefore;

  final int rssBefore;
  int rssPeak;
  int rssAfter = 0;
  Timer? _timer;

  static RssSampler start({
    bool enabled = true,
    Duration interval = const Duration(milliseconds: 10),
  }) {
    final before = ProcessInfo.currentRss;
    if (!enabled) return RssSampler._(before, null);
    late final RssSampler sampler;
    final timer = Timer.periodic(interval, (_) {
      sampler.rssPeak = math.max(sampler.rssPeak, ProcessInfo.currentRss);
    });
    sampler = RssSampler._(before, timer);
    return sampler;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    rssAfter = ProcessInfo.currentRss;
    rssPeak = math.max(rssPeak, rssAfter);
  }
}

class BenchmarkReport {
  const BenchmarkReport({required this.environment, required this.results});

  final Map<String, Object> environment;
  final List<BenchmarkResult> results;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'environment': environment,
    'results': results.map((result) => result.toJson()).toList(growable: false),
  };

  String encodeJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory BenchmarkReport.decode(String source) {
    final decoded = json.decode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Benchmark report must be a JSON object.');
    }
    final rawEnvironment = decoded['environment'];
    final rawResults = decoded['results'];
    if (rawEnvironment is! Map<String, dynamic> || rawResults is! List) {
      throw const FormatException(
        'Benchmark report is missing environment or results.',
      );
    }
    return BenchmarkReport(
      environment: rawEnvironment.map(
        (key, value) => MapEntry(key, value as Object),
      ),
      results: rawResults
          .map(
            (result) => BenchmarkResult.fromJson(
              (result as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
    );
  }
}

Map<String, Object> benchmarkEnvironment({
  required int warmUpIterations,
  required int iterations,
  required bool quick,
  required Iterable<String> suites,
}) => {
  'dartVersion': Platform.version,
  'operatingSystem': Platform.operatingSystem,
  'operatingSystemVersion': Platform.operatingSystemVersion,
  'architecture': Abi.current().toString(),
  'processorCount': Platform.numberOfProcessors,
  'runtimeMode': const bool.fromEnvironment('dart.vm.product')
      ? 'aot-product'
      : 'jit',
  'executable': Platform.executable,
  'warmUpIterations': warmUpIterations,
  'iterations': iterations,
  'quick': quick,
  'suites': suites.toList(growable: false),
  'timestampUtc': DateTime.now().toUtc().toIso8601String(),
};

class BenchmarkComparison {
  const BenchmarkComparison({required this.current, required this.baseline});

  final BenchmarkResult current;
  final BenchmarkResult baseline;

  double? get throughputDelta => _percentDelta(
    current.throughputBytesPerSecond,
    baseline.throughputBytesPerSecond,
  );

  double? get medianLatencyDelta =>
      _percentDelta(current.medianUs, baseline.medianUs);

  double? get p95LatencyDelta => _percentDelta(current.p95Us, baseline.p95Us);

  double? get rssPeakDelta =>
      _percentDelta(current.rssPeak.toDouble(), baseline.rssPeak.toDouble());

  static double? _percentDelta(double current, double baseline) {
    if (baseline == 0) return null;
    return ((current - baseline) / baseline) * 100;
  }
}

List<BenchmarkComparison> compareReports(
  BenchmarkReport current,
  BenchmarkReport baseline,
) {
  final baselineByKey = {
    for (final result in baseline.results) result.key: result,
  };
  return current.results
      .where((result) => baselineByKey.containsKey(result.key))
      .map(
        (result) => BenchmarkComparison(
          current: result,
          baseline: baselineByKey[result.key]!,
        ),
      )
      .toList(growable: false);
}

String formatBytes(double bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB'];
  var value = bytes;
  var unit = 0;
  while (value.abs() >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String formatRate(double bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

String formatDurationUs(double microseconds) {
  if (microseconds >= Duration.microsecondsPerSecond) {
    return '${(microseconds / Duration.microsecondsPerSecond).toStringAsFixed(2)} s';
  }
  if (microseconds >= Duration.microsecondsPerMillisecond) {
    return '${(microseconds / Duration.microsecondsPerMillisecond).toStringAsFixed(2)} ms';
  }
  return '${microseconds.toStringAsFixed(1)} us';
}

String formatPercent(double? value) {
  if (value == null || !value.isFinite) return 'n/a';
  final prefix = value >= 0 ? '+' : '';
  return '$prefix${value.toStringAsFixed(1)}%';
}
