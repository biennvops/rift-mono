import 'dart:ui' as ui;

import 'package:daemon_dart/daemon_dart.dart';
import 'package:flutter/services.dart';

/// Background isolate entrypoint for the Android daemon.
///
/// This exists because `daemon-dart` uses Flutter plugins (e.g. `nsd`) and
/// plugin channels are not usable from a spawned isolate unless the isolate
/// initializes the background binary messenger and registers plugins.
void androidDaemonIsolateEntrypoint(Map<String, dynamic> args) {
  final token = args['rootIsolateToken'];
  if (token is! ui.RootIsolateToken) {
    throw StateError('Missing RootIsolateToken for Android daemon isolate');
  }

  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  ui.DartPluginRegistrant.ensureInitialized();

  // Forward to the real daemon entrypoint (pure Dart, but uses plugins).
  RiftDaemon.isolateEntryPoint(args);
}

