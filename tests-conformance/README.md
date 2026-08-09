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
- `runners/dotnet/` - executable .NET runner

## Run The Runners

```bash
cd tests-conformance
flutter pub get
dart run runners/dart/runner.dart
dotnet restore runners/dotnet/Rift.Conformance.Runner.csproj
dotnet run --project runners/dotnet/Rift.Conformance.Runner.csproj --no-restore -- "$PWD"
```

Both runners execute the shared notification-sync vectors, including malformed,
oversized, hash-mismatched, and structurally invalid PNG metadata.

## Related Inputs

- `../spec/doc/protocol.md`
- `../spec/vectors/README.md`
