import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'support/benchmark_runner.dart';
import 'support/benchmark_workloads.dart';

Future<void> main(List<String> arguments) async {
  late final _BenchmarkOptions options;
  try {
    options = _BenchmarkOptions.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('Use --help for usage.');
    exitCode = 64;
    return;
  }

  if (options.help) {
    stdout.write(_usage);
    return;
  }

  try {
    final results = await runZoned(
      () => RiftBenchmarkWorkloads(
        BenchmarkWorkloadConfig(
          warmUpIterations: options.warmUpIterations,
          iterations: options.iterations,
          quick: options.quick,
          suites: options.suites,
        ),
      ).run(),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => stderr.writeln(line),
      ),
    );
    final report = BenchmarkReport(
      environment: benchmarkEnvironment(
        warmUpIterations: options.warmUpIterations,
        iterations: options.iterations,
        quick: options.quick,
        suites: options.suites,
      ),
      results: results,
    );
    final baseline = options.comparePath == null
        ? null
        : BenchmarkReport.decode(
            await File(options.comparePath!).readAsString(),
          );
    final comparisons = baseline == null
        ? const <BenchmarkComparison>[]
        : compareReports(report, baseline);

    if (options.json) {
      final output = report.toJson();
      if (baseline != null) {
        output['comparison'] = comparisons
            .map(
              (comparison) => {
                'benchmark': comparison.current.benchmark,
                'variant': comparison.current.variant,
                'payloadBytes': comparison.current.payloadBytes,
                'throughputPercent': comparison.throughputDelta,
                'medianLatencyPercent': comparison.medianLatencyDelta,
                'p95LatencyPercent': comparison.p95LatencyDelta,
                'rssPeakPercent': comparison.rssPeakDelta,
              },
            )
            .toList(growable: false);
      }
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
    } else {
      _writeHumanReport(report, comparisons);
    }
  } on Object catch (error, stackTrace) {
    stderr.writeln('Benchmark failed: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

void _writeHumanReport(
  BenchmarkReport report,
  List<BenchmarkComparison> comparisons,
) {
  stdout.writeln('Rift transport and file-transfer benchmark');
  for (final entry in report.environment.entries) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }
  stdout.writeln();

  for (final result in report.results) {
    stdout.writeln(
      '${result.benchmark}/${result.variant}/${formatBytes(result.payloadBytes.toDouble())}',
    );
    stdout.writeln('  iterations:       ${result.iterations}');
    stdout.writeln('  operations:       ${result.operations}');
    stdout.writeln('  median latency:   ${formatDurationUs(result.medianUs)}');
    stdout.writeln('  p95 latency:      ${formatDurationUs(result.p95Us)}');
    stdout.writeln('  p99 latency:      ${formatDurationUs(result.p99Us)}');
    stdout.writeln('  elapsed:          ${formatDurationUs(result.elapsedUs)}');
    stdout.writeln(
      '  throughput:       ${formatRate(result.throughputBytesPerSecond)}',
    );
    if (result.rawFileBytes > 0) {
      stdout.writeln(
        '  raw throughput:   ${formatRate(result.rawThroughputBytesPerSecond)}',
      );
    }
    if (result.wireBytes > 0) {
      stdout.writeln(
        '  wire throughput:  ${formatRate(result.wireThroughputBytesPerSecond)}',
      );
      stdout.writeln(
        '  wire bytes:       ${formatBytes(result.wireBytes.toDouble())}',
      );
    }
    if (result.rssPeak > 0) {
      stdout.writeln(
        '  RSS start/peak/end: '
        '${formatBytes(result.rssBefore.toDouble())} / '
        '${formatBytes(result.rssPeak.toDouble())} / '
        '${formatBytes(result.rssAfter.toDouble())}',
      );
    }
    final metricNames = result.metrics.keys.toList()..sort();
    for (final name in metricNames) {
      final value = result.metrics[name]!;
      final formatted = name.endsWith('Us')
          ? formatDurationUs(value)
          : name.endsWith('Percent')
          ? '${value.toStringAsFixed(1)}%'
          : value.toStringAsFixed(2);
      stdout.writeln('  $name: $formatted');
    }
    stdout.writeln();
  }

  if (comparisons.isNotEmpty) {
    stdout.writeln('Comparison with baseline');
    for (final comparison in comparisons) {
      stdout.writeln(
        '${comparison.current.benchmark}/${comparison.current.variant}/'
        '${formatBytes(comparison.current.payloadBytes.toDouble())}',
      );
      stdout.writeln(
        '  throughput:     ${formatPercent(comparison.throughputDelta)}',
      );
      stdout.writeln(
        '  median latency: ${formatPercent(comparison.medianLatencyDelta)}',
      );
      stdout.writeln(
        '  p95 latency:    ${formatPercent(comparison.p95LatencyDelta)}',
      );
      stdout.writeln(
        '  peak RSS:       ${formatPercent(comparison.rssPeakDelta)}',
      );
    }
  }
}

class _BenchmarkOptions {
  const _BenchmarkOptions({
    required this.json,
    required this.quick,
    required this.help,
    required this.comparePath,
    required this.warmUpIterations,
    required this.iterations,
    required this.suites,
  });

  final bool json;
  final bool quick;
  final bool help;
  final String? comparePath;
  final int warmUpIterations;
  final int iterations;
  final Set<String> suites;

  static _BenchmarkOptions parse(List<String> arguments) {
    var json = false;
    var quick = false;
    var help = false;
    String? comparePath;
    int? warmUpIterations;
    int? iterations;
    final suites = <String>{};

    String valueAfter(int index, String option) {
      if (index + 1 >= arguments.length) {
        throw FormatException('$option requires a value.');
      }
      return arguments[index + 1];
    }

    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (argument == '--json') {
        json = true;
      } else if (argument == '--quick') {
        quick = true;
      } else if (argument == '--help' || argument == '-h') {
        help = true;
      } else if (argument == '--compare') {
        comparePath = valueAfter(i, argument);
        i++;
      } else if (argument.startsWith('--compare=')) {
        comparePath = argument.substring('--compare='.length);
      } else if (argument == '--warmup') {
        warmUpIterations = _positiveOrZero(valueAfter(i, argument), argument);
        i++;
      } else if (argument.startsWith('--warmup=')) {
        warmUpIterations = _positiveOrZero(
          argument.substring('--warmup='.length),
          '--warmup',
        );
      } else if (argument == '--iterations') {
        iterations = _positive(valueAfter(i, argument), argument);
        i++;
      } else if (argument.startsWith('--iterations=')) {
        iterations = _positive(
          argument.substring('--iterations='.length),
          '--iterations',
        );
      } else if (argument == '--suite') {
        _addSuites(suites, valueAfter(i, argument));
        i++;
      } else if (argument.startsWith('--suite=')) {
        _addSuites(suites, argument.substring('--suite='.length));
      } else {
        throw FormatException('Unknown option: $argument');
      }
    }

    final resolvedSuites = suites.isEmpty ? {...benchmarkSuites} : suites;
    final unknownSuites = resolvedSuites.difference(benchmarkSuites);
    if (unknownSuites.isNotEmpty) {
      throw FormatException(
        'Unknown benchmark suite(s): ${unknownSuites.join(', ')}',
      );
    }
    if (comparePath != null && comparePath.trim().isEmpty) {
      throw const FormatException('--compare requires a non-empty path.');
    }

    return _BenchmarkOptions(
      json: json,
      quick: quick,
      help: help,
      comparePath: comparePath,
      warmUpIterations: warmUpIterations ?? (quick ? 1 : 2),
      iterations: iterations ?? (quick ? 1 : 5),
      suites: resolvedSuites,
    );
  }

  static int _positive(String source, String option) {
    final value = int.tryParse(source);
    if (value == null || value <= 0) {
      throw FormatException('$option must be a positive integer.');
    }
    return value;
  }

  static int _positiveOrZero(String source, String option) {
    final value = int.tryParse(source);
    if (value == null || value < 0) {
      throw FormatException('$option must be a non-negative integer.');
    }
    return value;
  }

  static void _addSuites(Set<String> suites, String source) {
    for (final suite in source.split(',')) {
      final trimmed = suite.trim();
      if (trimmed.isEmpty) {
        throw const FormatException('--suite contains an empty suite name.');
      }
      suites.add(trimmed);
    }
  }
}

const _usage = '''
Rift transport and file-transfer benchmark

Usage:
  dart run benchmark/transport_file_transfer_benchmark.dart [options]

Options:
  --json                 Write a machine-readable JSON report.
  --compare PATH         Compare matching results with a prior JSON report.
  --quick                Use smoke-sized workloads (one warm-up/iteration).
  --warmup N             Override warm-up iteration count (default: 2).
  --iterations N         Override measured iteration count (default: 5).
  --suite NAME[,NAME]    Run selected suites; may be repeated.
  --help, -h             Show this help.

Suites:
  cpu, tls, flush, control, bulk, mixed, file-service, receiver, logging

Examples:
  dart run benchmark/transport_file_transfer_benchmark.dart --quick
  dart run benchmark/transport_file_transfer_benchmark.dart --json > /tmp/rift-baseline.json
  dart run benchmark/transport_file_transfer_benchmark.dart --compare /tmp/rift-baseline.json
''';
