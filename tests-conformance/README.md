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

The current CI job builds the C# daemon but executes the declarative cases only
through the Dart runner. Until the .NET runner is implemented and runs the same
manifest, this harness must not be cited as cross-implementation vector parity.

## Run The Dart Runner

```bash
cd tests-conformance
dart pub get
dart run runners/dart/runner.dart
```

## Related Inputs

- `../spec/doc/protocol.md`
- `../spec/vectors/README.md`
