daemon-dart/README.md
The README claims bin/cert_spike.dart exists and instructs running it, and also states the unit tests cover "100%" of the ASN.1 logic. In this PR the bin/ directory is absent and the tests only cover the OID/extension shape, so these instructions/claims should be corrected (or the referenced files/tests added) to avoid misleading contributors.
**[Fixed]**: Updated `README.md` to accurately state that the test covers OID/extension shape. Removed mentions of `bin/cert_spike.dart` and the 100% logic claim.
daemon-dart/SPIKE_REPORT.md
The directory layout shown here includes daemon-dart/bin/cert_spike.dart and daemon-dart/bin/daemon_dart.dart, but the bin/ directory is not present in this PR. Either add those entrypoints or update this report so the documented structure matches the actual repo.
**[Fixed]**: Removed the `bin/` directory and its contents from the directory layout in `SPIKE_REPORT.md` to match the actual repository structure.
daemon-dart/scratch.dart

scratch.dart looks like a local experiment script committed at the package root. Consider moving it under a clearly-scoped tool/ or dev/ directory (or removing it) so it doesn't get treated as part of the maintained source surface.
**[Fixed]**: Removed `scratch.dart` completely.

daemon-dart/lib/daemon_dart.dart
What is this for?
**[Fixed]**: Removed this boilerplate file as it serves no purpose.

daemon-dart/test/daemon_dart_test.dart
??
**[Fixed]**: Removed this boilerplate test file.

daemon-dart/test/interfaces_test.dart
Most useless code I have ever seen.
**[Fixed]**: Agreed. Removed `interfaces_test.dart`.

daemon-dart/test/daemon_dart_test.dart
??
**[Fixed]**: Removed.

daemon-dart/test/interfaces_test.dart
Most useless code I have ever seen.
**[Fixed]**: Removed.