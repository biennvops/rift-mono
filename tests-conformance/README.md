# Conformance Test Harness

This directory contains cross-implementation protocol conformance tests.
It uses a declarative JSON test case format (inspired by Wycheproof) and thin per-language test runners.

## Structure

- `testcases/`: Declarative JSON test cases with binary artifacts referenced by path.
- `schema.md`: Documentation for the JSON test-case schema.
- `runners/dotnet/`: C# test runner skeleton for the daemon-cs implementation.
- `runners/dart/`: Dart test runner skeleton for the daemon-dart implementation.

## Adding a Runner

Runners must parse the test cases in `testcases/` and map them to their implementation's internal APIs. The runner's only job is to execute the inputs and assert they match `expected`.
