import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rift/widgets/device_hub/device_orbit_layout.dart';
import 'package:rift/widgets/device_hub/device_orbit_motion_state.dart';
import 'package:rift/widgets/device_hub/device_orbit_scene.dart';
import 'package:rift/widgets/device_hub/orbit_peer_presentation.dart';

OrbitPeerPresentation _peer(String id) => OrbitPeerPresentation(
      deviceId: id,
      displayName: id,
      platform: 'linux',
      isOnline: true,
    );

void _expectSafeOrbit(Size size, int peerCount) {
  final geometry = DeviceOrbitLayout.calculate(
    size,
    peerCount: peerCount,
  );
  final minimumCoreClearance = (geometry.localCoreSize + geometry.peerSize) / 2;

  for (var step = 0; step < 32; step++) {
    final phase = step / 32;
    final centers = [
      for (var index = 0; index < peerCount; index++)
        DeviceOrbitLayout.peerCenter(
          geometry: geometry,
          index: index,
          peerCount: peerCount,
          phase: phase,
        ),
    ];

    for (final center in centers) {
      expect(
        (center - geometry.center).distance,
        greaterThanOrEqualTo(minimumCoreClearance - 0.001),
        reason: '$peerCount peers at $size and phase $phase overlap the core',
      );
      expect(center.dx - geometry.peerSize / 2, greaterThanOrEqualTo(-0.001));
      expect(center.dy - geometry.peerSize / 2, greaterThanOrEqualTo(-0.001));
      expect(
        center.dx + geometry.peerSize / 2,
        lessThanOrEqualTo(size.width + 0.001),
      );
      expect(
        center.dy + geometry.peerSize / 2,
        lessThanOrEqualTo(size.height + 0.001),
      );
    }

    for (var left = 0; left < centers.length; left++) {
      for (var right = left + 1; right < centers.length; right++) {
        expect(
          (centers[left] - centers[right]).distance,
          greaterThanOrEqualTo(geometry.peerSize - 0.001),
          reason: '$peerCount peers at $size and phase $phase overlap',
        );
      }
    }
  }
}

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

  test('orbit geometry stays clear beside a maximum desktop sidebar', () {
    for (final peerCount in const [1, 4, 8]) {
      _expectSafeOrbit(const Size(468, 620), peerCount);
    }
  });

  test('orbit geometry shrinks safely in short desktop scenes', () {
    for (final peerCount in const [1, 4, 8]) {
      _expectSafeOrbit(const Size(700, 300), peerCount);
    }

    final geometry = DeviceOrbitLayout.calculate(
      const Size(700, 300),
      peerCount: 8,
    );
    expect(geometry.localCoreSize, lessThan(126));
    expect(geometry.peerSize, lessThan(102));
  });

  testWidgets('short desktop orbit renders compact nodes without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(700, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final peers = List<OrbitPeerPresentation>.generate(
      8,
      (index) => OrbitPeerPresentation(
        deviceId: 'peer-$index',
        displayName: 'Long Device Name $index',
        platform: index.isEven ? 'android' : 'linux',
        isOnline: true,
        powerStatus: const OrbitPeerPowerStatus(
          batteryPercent: 87,
          isCharging: true,
        ),
        activity: OrbitPeerActivity.mediaPlaying,
        mediaTitle: 'A long track title',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DeviceOrbitScene(
          localDisplayName: 'Long Local Device Name',
          localPlatform: 'macos',
          peers: peers,
          phase: const AlwaysStoppedAnimation<double>(0),
          scanProgress: const AlwaysStoppedAnimation<double>(0),
          peerKeyPrefix: 'compact-peer',
          peerSemanticRole: 'trusted device',
          onPeerSelected: (_) {},
          onPeerInteractionChanged: (_, __) {},
          onSceneFocusChanged: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const ValueKey('device-hub-local-core'))).width,
      lessThan(90),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('compact-peer-peer-0'))).width,
      lessThan(70),
    );
    expect(tester.takeException(), isNull);
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
        interactingPeerCount: 0,
        membershipTransitioning: true,
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

  testWidgets('peer changes animate and release removed interaction',
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
      isOnline: true,
    );
    var peers = <OrbitPeerPresentation>[peerA];
    final interactionChanges = <String>[];
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
                  onPeerInteractionChanged: (deviceId, interacting) {
                    interactionChanges.add('$deviceId:$interacting');
                  },
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
    expect(enteringScale, inOpenClosedRange(0.65, 1.03));
    await tester.pumpAndSettle();

    final peerAFinder = find.byKey(const ValueKey('test-peer-peer-a'));
    tester
        .widget<InkWell>(
          find.descendant(of: peerAFinder, matching: find.byType(InkWell)),
        )
        .onHover!(true);
    await tester.pump();
    expect(interactionChanges.last, 'peer-a:true');

    updatePeers(() => peers = <OrbitPeerPresentation>[peerB]);
    await tester.pump();
    expect(interactionChanges.last, 'peer-a:false');
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
    expect(interactionChanges.last, 'peer-a:false');
  });

  for (final configuration in const [
    (prefix: 'trusted-reflow', role: 'trusted device'),
    (prefix: 'nearby-reflow', role: 'nearby device'),
  ]) {
    testWidgets(
      '${configuration.role} survivors reflow for add and remove',
      (tester) async {
        final peersById = {
          for (final id in ['peer-a', 'peer-b', 'peer-c', 'peer-d'])
            id: _peer(id),
        };
        var peers = <OrbitPeerPresentation>[
          peersById['peer-a']!,
          peersById['peer-b']!,
          peersById['peer-c']!,
        ];
        final transitionChanges = <bool>[];
        final selections = <String>[];
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
                      phase: const AlwaysStoppedAnimation<double>(0.125),
                      scanProgress: const AlwaysStoppedAnimation<double>(0),
                      peerKeyPrefix: configuration.prefix,
                      peerSemanticRole: configuration.role,
                      onPeerSelected: (peer) => selections.add(peer.deviceId),
                      onPeerInteractionChanged: (_, __) {},
                      onSceneFocusChanged: (_) {},
                      onMembershipTransitionChanged: transitionChanges.add,
                      animatePeerChanges: true,
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final peerBFinder = find.byKey(
          ValueKey('${configuration.prefix}-peer-b'),
        );
        final oldCenter = tester.getCenter(peerBFinder);
        final sceneFinder = find.byType(DeviceOrbitScene);
        final geometry = DeviceOrbitLayout.calculate(
          tester.getSize(sceneFinder),
        );
        final sceneOrigin = tester.getTopLeft(sceneFinder);
        final addedTarget = sceneOrigin +
            DeviceOrbitLayout.peerCenter(
              geometry: geometry,
              index: 1,
              peerCount: 4,
              phase: 0.125,
            );

        updatePeers(() {
          peers = [
            peersById['peer-a']!,
            peersById['peer-b']!,
            peersById['peer-c']!,
            peersById['peer-d']!,
          ];
        });
        await tester.pump();

        expect(transitionChanges, [true]);
        expect(tester.getCenter(peerBFinder), oldCenter);
        expect(oldCenter, isNot(addedTarget));
        final enteringOpacity = tester.widget<Opacity>(
          find.byKey(
            ValueKey('${configuration.prefix}-presence-peer-d'),
          ),
        );
        expect(enteringOpacity.opacity, 0);

        await tester.pump(const Duration(milliseconds: 220));
        final addMidpoint = tester.getCenter(peerBFinder);
        expect(addMidpoint, isNot(oldCenter));
        expect(addMidpoint, isNot(addedTarget));

        await tester.pumpAndSettle();
        expect(tester.getCenter(peerBFinder), addedTarget);
        expect(transitionChanges, [true, false]);

        final fourPeerCenter = tester.getCenter(peerBFinder);
        final removedTarget = sceneOrigin +
            DeviceOrbitLayout.peerCenter(
              geometry: geometry,
              index: 1,
              peerCount: 3,
              phase: 0.125,
            );
        updatePeers(() {
          peers = [
            peersById['peer-a']!,
            peersById['peer-b']!,
            peersById['peer-c']!,
          ];
        });
        await tester.pump();

        expect(tester.getCenter(peerBFinder), fourPeerCenter);
        expect(fourPeerCenter, isNot(removedTarget));
        final leavingFinder = find.byKey(
          ValueKey('${configuration.prefix}-peer-d'),
        );
        expect(leavingFinder, findsOneWidget);
        expect(
          tester
              .widgetList<IgnorePointer>(
                find.ancestor(
                  of: leavingFinder,
                  matching: find.byType(IgnorePointer),
                ),
              )
              .any((widget) => widget.ignoring),
          isTrue,
        );
        await tester.tap(leavingFinder, warnIfMissed: false);
        expect(selections, isEmpty);

        await tester.pump(const Duration(milliseconds: 220));
        final removeMidpoint = tester.getCenter(peerBFinder);
        expect(removeMidpoint, isNot(fourPeerCenter));
        expect(removeMidpoint, isNot(removedTarget));

        await tester.pumpAndSettle();
        expect(tester.getCenter(peerBFinder), removedTarget);
        expect(leavingFinder, findsNothing);
        expect(transitionChanges, [true, false, true, false]);
      },
    );
  }

  testWidgets('pairing handoff prepares again after removing the same peer',
      (tester) async {
    final peer = _peer('peer-repeat');
    var peers = <OrbitPeerPresentation>[];
    PairingOrbitHandoff? handoff;
    late StateSetter updateScene;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: StatefulBuilder(
            builder: (context, setState) {
              updateScene = setState;
              return DeviceOrbitScene(
                localDisplayName: 'Local',
                localPlatform: 'macos',
                peers: peers,
                phase: const AlwaysStoppedAnimation<double>(0),
                scanProgress: const AlwaysStoppedAnimation<double>(0),
                peerKeyPrefix: 'repeat-handoff',
                peerSemanticRole: 'trusted device',
                onPeerSelected: (_) {},
                onPeerInteractionChanged: (_, __) {},
                onSceneFocusChanged: (_) {},
                pairingHandoff: handoff,
                animatePeerChanges: true,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    updateScene(() {
      peers = [peer];
      handoff = PairingOrbitHandoff(
        deviceId: peer.deviceId,
        previousPeers: const [],
        sourceOrigin: const OrbitPeerEntryOrigin(
          index: 0,
          peerCount: 1,
          phase: 0,
        ),
        duration: const Duration(milliseconds: 100),
      );
    });
    await tester.pump();
    await tester.pumpAndSettle();

    updateScene(() => handoff = null);
    await tester.pump();
    updateScene(() => peers = []);
    await tester.pump();
    await tester.pumpAndSettle();

    const secondOrigin = OrbitPeerEntryOrigin(
      index: 0,
      peerCount: 1,
      phase: 0.25,
    );
    updateScene(() {
      peers = [peer];
      handoff = PairingOrbitHandoff(
        deviceId: peer.deviceId,
        previousPeers: const [],
        sourceOrigin: secondOrigin,
        duration: const Duration(milliseconds: 100),
      );
    });
    await tester.pump();

    final sceneFinder = find.byType(DeviceOrbitScene);
    final geometry = DeviceOrbitLayout.calculate(
      tester.getSize(sceneFinder),
      peerCount: 1,
    );
    final expectedCenter = tester.getTopLeft(sceneFinder) +
        DeviceOrbitLayout.peerCenter(
          geometry: geometry,
          index: secondOrigin.index,
          peerCount: secondOrigin.peerCount,
          phase: secondOrigin.phase,
        );
    final actualCenter = tester.getCenter(
      find.byKey(const ValueKey('repeat-handoff-peer-repeat')),
    );
    expect(actualCenter.dx, closeTo(expectedCenter.dx, 0.01));
    expect(actualCenter.dy, closeTo(expectedCenter.dy, 0.01));
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion changes membership without peer travel',
      (tester) async {
    final peerA = _peer('peer-a');
    final peerB = _peer('peer-b');
    var peers = <OrbitPeerPresentation>[peerA];
    final transitionChanges = <bool>[];
    late StateSetter updatePeers;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (context, setState) {
              updatePeers = setState;
              return DeviceOrbitScene(
                localDisplayName: 'Local',
                localPlatform: 'macos',
                peers: peers,
                phase: const AlwaysStoppedAnimation<double>(0),
                scanProgress: const AlwaysStoppedAnimation<double>(0),
                peerKeyPrefix: 'reduced-peer',
                peerSemanticRole: 'nearby device',
                onPeerSelected: (_) {},
                onPeerInteractionChanged: (_, __) {},
                onSceneFocusChanged: (_) {},
                onMembershipTransitionChanged: transitionChanges.add,
                animatePeerChanges: true,
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    updatePeers(() => peers = [peerA, peerB]);
    await tester.pump();

    expect(transitionChanges, isEmpty);
    expect(find.byKey(const ValueKey('reduced-peer-peer-b')), findsOneWidget);
    expect(
      tester
          .widget<Opacity>(
            find.byKey(const ValueKey('reduced-peer-presence-peer-b')),
          )
          .opacity,
      1,
    );
  });
}
