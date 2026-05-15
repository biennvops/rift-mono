## Issues worth resolving before your team starts planning

**1. The "Daemon Core on Android" section creates a contradiction with the standalone-process requirement.**

The register now says both "Both daemons are runnable as standalone console processes for CI testing" and "On Android, hosted inside a dedicated background Dart isolate spawned by a Flutter foreground service." These aren't actually in conflict, but the register never explains *how* the same Dart code runs in both modes. The natural answer is that the daemon is a pure Dart library (`rift_daemon` package, say) with two thin entry points: a `bin/riftd.dart` standalone CLI for development/CI, and an isolate entrypoint invoked by the Flutter foreground service on Android. Worth stating explicitly in Task Package 1 or in the Daemon Core section, because otherwise during planning your team will ask "wait, is the daemon a separate Dart package or part of the Flutter app?" and the answer affects how the repository is structured.

**2. The repository/package structure is implied but never stated, and it matters for planning.**

Across the document you reference `Rift.Core` (C#), `rift_core` (Dart), the C# daemon, the Dart daemon, the Flutter app, and the protocol spec — but you never say whether these live in one monorepo, multiple repos, or how the Flutter app depends on the Dart daemon code. Some choices your team needs to make explicitly during planning:

- One monorepo or separate repos per language?
- Does the Flutter app depend on the Dart daemon as a path dependency (monorepo) or a published package?
- Where does the protocol specification document live, and where do the cross-language test vectors live?
- How is the C# daemon built and packaged on a developer's Mac/Linux machine versus the Windows Service installer?

I'd recommend a monorepo with top-level directories like `spec/`, `daemon-cs/`, `daemon-dart/`, `app-flutter/`, `tests-conformance/`, `tests-interop/` — but that's a planning decision, not something the register needs to mandate. Worth raising as an open planning question rather than leaving implicit.

**3. There's a remaining ambiguity about *which device* generates the X.509 certificate and *when*.**

The register says identity is generated "on first run" but doesn't address what happens for the protocol-spec conformance test vectors. If conformance tests need deterministic test inputs (a known Ed25519 keypair, a known certificate), the spec needs to include test vectors with fixed cryptographic material — and someone needs to generate those vectors as part of authoring the spec. This is a small thing, but it'll come up early in Task Package 1 when the team realizes the protocol specification needs example bytes, not just structural definitions. Worth flagging in planning so it doesn't surprise anyone.

**4. The "intent lifecycle" terminology overlaps confusingly with general English usage of "intent."**

This is purely a naming thing, but I want to flag it because Android has a first-class concept called `Intent` (the IPC message type used for activity launching, broadcasts, etc.) and the Kotlin shim section of your project will be working with Android `Intent` objects routinely. Having a *Rift* `Intent` that means "any cross-device action" alongside *Android* `Intent` that means "IPC message" will create real confusion in the Kotlin shim code and in code review conversations.

Consider renaming Rift's `Intent` to something less collision-prone — `Action`, `Operation`, `Task`, `Request`, or `Transaction` are all candidates. The register uses `Intent` heavily so this would be a search-and-replace across multiple sections, but it's much easier to do now than after the team has written code. If you keep `Intent`, at minimum the implementation should namespace it (e.g., `RiftIntent` in Kotlin to disambiguate from `android.content.Intent`).

**5. The clipboard offer's "hash" field needs its purpose specified.**

You say clipboard offers carry "content type, size, hash — never the actual content." What is the hash *for*? Is it for content integrity verification after fetch (verify the fetched content matches the advertised hash)? Is it for deduplication (if I see the same hash from multiple devices, suppress duplicates)? Is it for offer identity (a stable ID derived from content)? Each of these implies a different hash algorithm choice and different security properties:

- Integrity verification: needs to be cryptographically strong (SHA-256 or better), needs to be verified after fetch, and protects against a paired-but-compromised peer modifying content between offer and fetch.
- Deduplication: could be weaker (even a CRC), and is a UX feature not a security feature.
- Offer identity: needs to be unique enough, but doesn't need cryptographic properties.

The protocol specification will need to nail this down. Worth deciding now so the threat model knows what the hash protects against, and so your team isn't relitigating it during implementation.

**6. The pairing protocol's "ephemeral key exchange" is mentioned but unspecified.**

Task Package 2 says "Implement the complete pairing flow: ephemeral key exchange, full Ed25519 cryptographic fingerprint display and verification..." but you don't say *what kind* of ephemeral key exchange. Is this:

- A separate ECDH exchange to establish a session key for some out-of-TLS purpose?
- Just shorthand for the TLS handshake's ephemeral keys?
- Something for a pairing-specific channel before TLS is established?

If pairing happens over already-established mutual TLS (which is the simplest and most defensible design — both sides present certificates, both verify the Ed25519 extension, both display fingerprints, both accept), then there's no separate "ephemeral key exchange" and the phrase is misleading. If pairing happens over an unauthenticated channel that's separately key-exchanged, that's a much more complex design that probably introduces vulnerability classes you don't want.

My guess is you mean the first (pairing over mutual TLS, with the "ephemeral" part referring to TLS 1.3's ephemeral key exchange). If so, drop the "ephemeral key exchange" phrase as it's redundant with TLS. If not, the register should be more specific. This is the kind of thing a security-aware reviewer will ask about.

## Issues worth knowing but not blocking planning

**7. The `clipboard_watcher` package situation on Windows isn't great.**

I noted in my earlier verification that the Windows clipboard packages are community-maintained. `clipboard_watcher` specifically has had reliability issues with the standard Windows clipboard API (`AddClipboardFormatListener` requires a window handle and a message loop, which Flutter apps have but in non-obvious ways). The register acknowledges "with platform-channel fallbacks where needed" which is the right hedge. Just expect that Task Package 5 may need real C++ code in the Windows runner shim rather than relying entirely on a pub.dev package. Not a register problem, just something to mention to whoever owns Task Package 5.

**8. The Dart daemon's TLS 1.3 negotiation is not actually under your direct control.**

Dart's `SecureSocket` uses BoringSSL underneath, which supports TLS 1.3, but you can't easily inspect the negotiated protocol version or cipher suite from Dart, and you can't force TLS 1.3 only (rejecting TLS 1.2 connections). If a peer somehow negotiates TLS 1.2 with your Dart daemon, the daemon will accept it. For your threat model this probably doesn't matter — mutual TLS 1.2 with ECDSA P-256 is still secure for this use case — but if your security architecture document claims "TLS 1.3 only," that's not strictly enforceable on the Dart side. The C# side via `SslStream` *can* enforce TLS 1.3 minimum.

The honest framing in the security architecture is "TLS 1.3 preferred, TLS 1.2 with strong cipher suites acceptable as a fallback the Dart implementation cannot prevent." I'd soften the register's "Mutual TLS 1.3" language to "Mutual TLS (1.3 preferred, 1.2 minimum)" in the protocol specification, even if you keep the shorter "TLS 1.3" framing in the user-facing overview.

**9. The protocol specification should be versioned from day one.**

The KDE Connect CVE-2025-66270 affected "protocol version 8" — KDE Connect at least has a version number in its protocol, which is what enabled them to issue a fixed version 9 (or whatever it is now). Your register doesn't currently say the Rift protocol is versioned. It should be — every protocol message should carry a protocol version, and the spec should commit to a versioning policy (semantic versioning of the protocol, minimum supported version negotiated during capability exchange, etc.).

This is a one-line addition to the protocol specification objective, but worth flagging in planning because protocol versioning is one of those things that's trivial to add at design time and very painful to retrofit later.

**10. There's no mention of how peers handle clock skew, but the trust model assumes timestamps.**

The register mentions TTLs for clipboard offers ("default 120 seconds") and "last seen time" for presence. Both depend on time. Two devices with significantly skewed clocks will disagree about whether an offer has expired. This isn't a security problem (you're not using timestamps for cryptographic purposes), but it's a correctness problem your team will hit during testing. Worth flagging: either explicitly use relative time (each device measures TTL from its own clock when the offer arrived) or document that absolute timestamps are assumed coarse and not relied on. Easy to handle, but easy to forget.

**11. The "Admin/Developer" role is essentially absent from the rest of the design.**

The Roles section defines AD as someone who "configures daemon behavior, monitors node health and security event logs, manages trust policies and capability permissions." But the rest of the register doesn't actually describe any AD-specific UI, tooling, or interface. The Flutter app's UI section lists end-user features only. There's no admin dashboard, no policy configuration UI, no node health monitoring screen.

You have three options: (a) remove the AD role from the document since it's not actually a distinct user persona in your MVP, (b) explicitly add it as future work, or (c) clarify that AD activities happen through configuration files, the JSON-RPC API directly (via a CLI tool), or the same Flutter UI that end-users use (with no separate AD-only features). Option (c) is probably the truth — there isn't really a separate AD role in a peer-to-peer trust mesh, every user is both — but the register should reflect that rather than implying a role that doesn't have first-class support.

**12. "Material 3" vs "Material Design 3" inconsistency.**

You use both phrasings interchangeably. Pick one. Minor, but documents read more professionally when terminology is consistent.

## Issues I deliberately did not raise

I want to flag these so you know I considered them and decided they're fine:

- **No mention of CI infrastructure choice (GitHub Actions, GitLab CI, etc.).** This is a planning detail your team picks, not something the register needs to commit to.
- **No mention of code coverage targets.** Capstone registers don't usually need these and adding numbers (e.g., "80% coverage") creates hostages to fortune similar to the 100ms latency issue from before.
- **No mention of accessibility, internationalization, or localization in the Flutter app.** For a security/protocol-focused capstone these are reasonable to omit. If your university expects accessibility in all student projects, add a one-line commitment, but it's not standard.
- **No mention of CI runner OS for the C# daemon.** The standalone-console-process requirement implicitly says ".NET runs on Linux CI runners" which it does (and which is standard for .NET projects). Fine to leave implicit.
- **No discussion of how the team will divide the work.** That's literally the planning meeting you're about to have, not something the register should pre-decide.
