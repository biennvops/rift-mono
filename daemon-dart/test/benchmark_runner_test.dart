import 'dart:convert';

import 'package:test/test.dart';

import '../benchmark/support/benchmark_runner.dart';

void main() {
  group('BenchmarkRunner', () {
    test('aggregates latency percentiles, throughput, RSS, and metrics', () {
      const definition = BenchmarkDefinition(
        benchmark: 'test/aggregate',
        variant: 'baseline',
        payloadBytes: 100,
        warmUpIterations: 0,
        iterations: 5,
        body: _unreachableBody,
      );
      final result = BenchmarkRunner.aggregate(definition, [
        _measurement(10, rssPeak: 110, metric: 1),
        _measurement(20, rssPeak: 120, metric: 2),
        _measurement(30, rssPeak: 130, metric: 3),
        _measurement(40, rssPeak: 140, metric: 4),
        _measurement(50, rssPeak: 150, metric: 5),
      ]);

      expect(result.medianUs, 30);
      expect(result.p95Us, 50);
      expect(result.p99Us, 50);
      expect(result.minUs, 10);
      expect(result.maxUs, 50);
      expect(result.operations, 2);
      expect(result.rawFileBytes, 100);
      expect(result.wireBytes, 140);
      expect(result.rssBefore, 100);
      expect(result.rssPeak, 150);
      expect(result.rssAfter, 105);
      expect(result.metrics['stageUs'], 3);
      expect(result.throughputBytesPerSecond, closeTo(6666666.67, 0.01));
    });

    test(
      'uses operation latencies instead of iteration elapsed when supplied',
      () {
        const definition = BenchmarkDefinition(
          benchmark: 'test/latencies',
          variant: 'mixed',
          payloadBytes: 1,
          warmUpIterations: 0,
          iterations: 1,
          body: _unreachableBody,
        );
        final result = BenchmarkRunner.aggregate(definition, const [
          BenchmarkMeasurement(
            elapsed: Duration(milliseconds: 1),
            operations: 3,
            throughputBytes: 3,
            latenciesUs: [100, 300, 200],
          ),
        ]);

        expect(result.medianUs, 200);
        expect(result.p95Us, 300);
        expect(result.elapsedUs, 1000);
      },
    );

    test('round-trips structured reports and compares matching keys', () {
      final baselineResult = BenchmarkRunner.aggregate(
        const BenchmarkDefinition(
          benchmark: 'test/compare',
          variant: 'baseline',
          payloadBytes: 100,
          warmUpIterations: 0,
          iterations: 1,
          body: _unreachableBody,
        ),
        [_measurement(20, rssPeak: 100, metric: 1)],
      );
      final currentResult = BenchmarkRunner.aggregate(
        const BenchmarkDefinition(
          benchmark: 'test/compare',
          variant: 'baseline',
          payloadBytes: 100,
          warmUpIterations: 0,
          iterations: 1,
          body: _unreachableBody,
        ),
        [_measurement(10, rssPeak: 110, metric: 1)],
      );
      final baseline = BenchmarkReport(
        environment: const {'runtimeMode': 'test'},
        results: [baselineResult],
      );
      final decoded = BenchmarkReport.decode(json.encode(baseline.toJson()));
      final comparisons = compareReports(
        BenchmarkReport(
          environment: const {'runtimeMode': 'test'},
          results: [currentResult],
        ),
        decoded,
      );

      expect(decoded.results.single.key, baselineResult.key);
      expect(comparisons, hasLength(1));
      expect(comparisons.single.throughputDelta, 100);
      expect(comparisons.single.medianLatencyDelta, -50);
      expect(comparisons.single.p95LatencyDelta, -50);
      expect(comparisons.single.rssPeakDelta, 10);
    });
  });
}

Future<BenchmarkMeasurement> _unreachableBody() => throw UnsupportedError(
  'The aggregate tests do not execute benchmark bodies.',
);

BenchmarkMeasurement _measurement(
  int elapsedUs, {
  required int rssPeak,
  required int metric,
}) => BenchmarkMeasurement(
  elapsed: Duration(microseconds: elapsedUs),
  operations: 2,
  throughputBytes: 200,
  rawFileBytes: 100,
  wireBytes: 140,
  rssBefore: 100,
  rssPeak: rssPeak,
  rssAfter: 105,
  metrics: {'stageUs': metric},
);
