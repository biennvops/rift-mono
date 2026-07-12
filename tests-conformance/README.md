# Conformance Test Harness

This directory contains declarative protocol conformance tests shared across
Rift implementations.

## Purpose

- validate implementation behavior against the written protocol
- keep vectors and test cases independent from daemon internals
- support multiple runners over the same declarative cases

## Structure

- `testcases/` - declarative JSON test cases
- `schema.md` - test case schema documentation
- `runners/dart/` - executable Dart runner
- `runners/dotnet/` - .NET runner work-in-progress

## Run The Dart Runner

```bash
cd tests-conformance
dart pub get
dart run runners/dart/runner.dart
```

## Related Inputs

- `../spec/doc/protocol.md`
- `../spec/vectors/README.md`
