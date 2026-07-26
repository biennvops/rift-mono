import 'dart:ui' as ui;

import 'package:daemon_dart/daemon_dart.dart';
import 'package:flutter/services.dart';

import 'android_native_peer_transport.dart';

/// Background isolate entrypoint for the Android daemon.
///
/// The daemon isolate itself must stay plugin-free on Android release builds:
/// MethodChannel-based plugins such as `nsd` must run on the root isolate.
/// Discovery is bridged from the root isolate in
/// `android_root_discovery_bridge.dart`.
void androidDaemonIsolateEntrypoint(Map<String, dynamic> args) {
  final token = args['rootIsolateToken'];
  if (token is! ui.RootIsolateToken) {
    throw StateError('Missing RootIsolateToken for Android daemon isolate');
  }

  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  // Do not call DartPluginRegistrant.ensureInitialized() here. Registering the
  // full plugin set would re-register `nsd` on the background isolate and
  // crash release builds with "Background isolates do not support
  // setMessageHandler()". The daemon isolate uses pure Dart services only.
  RiftDaemon.isolateEntryPoint(
    args,
    peerTransportFactory: (identityManager, port) =>
        AndroidNativePeerTransport(identityManager, port: port),
  );
}
