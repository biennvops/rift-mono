# Conformance Test Harness

This directory contains protocol conformance tests backed by declarative JSON
test cases. The Dart runner is implemented and executable today; the .NET
runner remains a separate follow-up.

## Structure

- `testcases/`: Declarative JSON test cases with binary artifacts referenced by path.
- `schema.md`: Documentation for the JSON test-case schema.
- `runners/dotnet/`: C# test runner skeleton for the daemon-cs implementation.
- `runners/dart/`: Dart test runner that executes the current vector suites.

## Adding a Runner

Runners must parse the test cases in `testcases/` and map them to their
implementation's internal APIs. The runner's only job is to execute the inputs
and assert they match `expected`.

To run the Dart conformance vectors locally:

```bash
cd tests-conformance
dart pub get
dart run runners/dart/runner.dart
```
