import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/widgets/device_hub/device_orbit_layout.dart';
import 'package:rift/widgets/device_hub/device_orbit_motion_state.dart';
import 'package:rift/widgets/device_hub/device_orbit_scene.dart';
import 'package:rift/widgets/device_hub/orbit_peer_presentation.dart';

void main() {
  test('orbit geometry moves coherently with phase', () {
    final geometry = DeviceOrbitLayout.calculate(const Size(900, 620));
    final phaseZero = DeviceOrbitLayout.peerCenter(
      geometry: geometry,
      index: 0,
      peerCount: 4,
      phase: 0,
    );
    final phaseQuarter = DeviceOrbitLayout.peerCenter(
      geometry: geometry,
      index: 0,
      peerCount: 4,
      phase: 0.25,
    );

    expect(phaseQuarter, isNot(phaseZero));
    expect(
      DeviceOrbitLayout.peerCenter(
        geometry: geometry,
        index: 0,
        peerCount: 4,
        phase: 0,
      ),
      phaseZero,
    );
  });

  test('orbit pause reasons compose', () {
    const moving = DeviceOrbitMotionState(
      reducedMotion: false,
      hasFocusedPeer: false,
      hasKeyboardFocus: false,
      interactingPeerCount: 0,
    );
    expect(moving.isPaused, isFalse);

    for (final paused in const [
      DeviceOrbitMotionState(
        reducedMotion: true,
        hasFocusedPeer: false,
        hasKeyboardFocus: false,
        interactingPeerCount: 0,
      ),
      DeviceOrbitMotionState(
        reducedMotion: false,
        hasFocusedPeer: true,
        hasKeyboardFocus: false,
        interactingPeerCount: 0,
      ),
      DeviceOrbitMotionState(
        reducedMotion: false,
        hasFocusedPeer: false,
        hasKeyboardFocus: true,
        interactingPeerCount: 0,
      ),
      DeviceOrbitMotionState(
        reducedMotion: false,
        hasFocusedPeer: false,
        hasKeyboardFocus: false,
        interactingPeerCount: 2,
      ),
    ]) {
      expect(paused.isPaused, isTrue);
    }
  });

  testWidgets('newly paired entry completes without motion when disabled',
      (tester) async {
    String? completedDeviceId;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: SizedBox(
            width: 900,
            height: 620,
            child: DeviceOrbitScene(
              localDisplayName: 'Local',
              localPlatform: 'macos',
              peers: const [
                OrbitPeerPresentation(
                  deviceId: 'peer-new',
                  displayName: 'New Peer',
                  platform: 'android',
                  isOnline: true,
                ),
              ],
              phase: const AlwaysStoppedAnimation<double>(0),
              scanProgress: const AlwaysStoppedAnimation<double>(0),
              peerKeyPrefix: 'test-peer',
              peerSemanticRole: 'trusted device',
              onPeerSelected: (_) {},
              onPeerInteractionChanged: (_, __) {},
              onSceneFocusChanged: (_) {},
              recentlyPairedDeviceId: 'peer-new',
              onRecentlyPairedAnimationCompleted: (deviceId) {
                completedDeviceId = deviceId;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(completedDeviceId, 'peer-new');
    expect(tester.takeException(), isNull);
  });

  testWidgets('orbit slots stay stable when arrival order changes',
      (tester) async {
    const peerA = OrbitPeerPresentation(
      deviceId: 'peer-a',
      displayName: 'Peer A',
      platform: 'linux',
      isOnline: true,
    );
    const peerB = OrbitPeerPresentation(
      deviceId: 'peer-b',
      displayName: 'Peer B',
      platform: 'android',
      isOnline: false,
    );

    Widget build(List<OrbitPeerPresentation> peers, double phase) {
      return MaterialApp(
        home: SizedBox(
          width: 900,
          height: 620,
          child: DeviceOrbitScene(
            localDisplayName: 'Local',
            localPlatform: 'macos',
            peers: peers,
            phase: AlwaysStoppedAnimation<double>(phase),
            scanProgress: const AlwaysStoppedAnimation<double>(0),
            peerKeyPrefix: 'test-peer',
            peerSemanticRole: 'trusted device',
            onPeerSelected: (_) {},
            onPeerInteractionChanged: (_, __) {},
            onSceneFocusChanged: (_) {},
          ),
        ),
      );
    }

    await tester.pumpWidget(build(const [peerB, peerA], 0));
    final firstA = tester.getCenter(
      find.byKey(const ValueKey('test-peer-peer-a')),
    );
    final firstB = tester.getCenter(
      find.byKey(const ValueKey('test-peer-peer-b')),
    );

    await tester.pumpWidget(build(const [peerA, peerB], 0));
    expect(
      tester.getCenter(find.byKey(const ValueKey('test-peer-peer-a'))),
      firstA,
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('test-peer-peer-b'))),
      firstB,
    );

    await tester.pumpWidget(build(const [peerA, peerB], 0.25));
    expect(
      tester.getCenter(find.byKey(const ValueKey('test-peer-peer-a'))),
      isNot(firstA),
    );
  });

  testWidgets('peer changes fade and scale in and out', (tester) async {
    const peerA = OrbitPeerPresentation(
      deviceId: 'peer-a',
      displayName: 'Peer A',
      platform: 'linux',
      isOnline: true,
    );
    const peerB = OrbitPeerPresentation(
      deviceId: 'peer-b',
      displayName: 'Peer B',
      platform: 'android',
      isOnline: true,
    );
    var peers = <OrbitPeerPresentation>[peerA];
    late StateSetter updatePeers;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: SizedBox(
            width: 900,
            height: 620,
            child: StatefulBuilder(
              builder: (context, setState) {
                updatePeers = setState;
                return DeviceOrbitScene(
                  localDisplayName: 'Local',
                  localPlatform: 'macos',
                  peers: peers,
                  phase: const AlwaysStoppedAnimation<double>(0),
                  scanProgress: const AlwaysStoppedAnimation<double>(0),
                  peerKeyPrefix: 'test-peer',
                  peerSemanticRole: 'nearby device',
                  onPeerSelected: (_) {},
                  onPeerInteractionChanged: (_, __) {},
                  onSceneFocusChanged: (_) {},
                  animatePeerChanges: true,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    updatePeers(() => peers = <OrbitPeerPresentation>[peerA, peerB]);
    await tester.pump();
    final enteringFade = find.byKey(
      const ValueKey('test-peer-presence-peer-b'),
    );
    expect(enteringFade, findsOneWidget);
    expect(tester.widget<Opacity>(enteringFade).opacity, 0);

    await tester.pump(const Duration(milliseconds: 140));
    final enteringOpacity = tester.widget<Opacity>(enteringFade).opacity;
    final enteringScale = tester
        .widget<Transform>(
          find.byKey(
            const ValueKey('test-peer-presence-scale-peer-b'),
          ),
        )
        .transform
        .getMaxScaleOnAxis();
    expect(enteringOpacity, inOpenClosedRange(0, 1));
    expect(enteringScale, inOpenClosedRange(0.86, 1));
    await tester.pumpAndSettle();

    updatePeers(() => peers = <OrbitPeerPresentation>[peerB]);
    await tester.pump();
    final exitingFade = find.byKey(
      const ValueKey('test-peer-presence-peer-a'),
    );
    expect(
      find.byKey(const ValueKey('test-peer-peer-a')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 140));
    expect(
      tester.widget<Opacity>(exitingFade).opacity,
      inOpenClosedRange(0, 1),
    );

    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('test-peer-peer-a')),
      findsNothing,
    );
  });
}
