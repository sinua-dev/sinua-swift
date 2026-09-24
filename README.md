# Sinua for iOS

The SwiftPM package: the Rust geometry engine, a SwiftUI view, and the voice
sources that drive it. iOS 15+.

```swift
import Sinua

SinuaView(pattern: "breathing", size: 64)
```

## Products

| Product | What it is |
|---|---|
| `Sinua` | The SwiftUI `SinuaView` and the paint contract. This is what an app imports. It carries the voice *types* (`VoiceSource`, `VoiceOverrides`, `AgentState`, from the internal `SinuaVoiceTypes` target) but no audio I/O, so an app that only draws doesn't link the microphone code. |
| `SinuaVoice` | Voice sources: microphone, test tone, and the SDK-free parts of every vendor adapter. Re-exports the voice types, so `import SinuaVoice` alone is enough for them. |
| `CoreEngine` | The generated UniFFI bindings over the Rust engine. `Sinua` depends on it; an app normally does not import it directly. |
| `SinuaGeminiLive` | Gemini Live over its WebSocket. Foundation only, no third-party SDK. |
| `SinuaElevenLabs` | ElevenLabs Agents over its WebSocket. Foundation only, no third-party SDK. |

Two more vendors live in their own packages, because each pulls an SDK that an
app shouldn't carry unless it uses it:

- [`packages/ios-livekit`](../ios-livekit) — `SinuaLiveKit`, on `client-sdk-swift`.
- [`packages/ios-openai`](../ios-openai) — `SinuaOpenAI`, on LiveKit's prefixed
  WebRTC build.

## Adding it

Until the repository is published, add it by path:

```swift
.package(path: "../sinua/packages/ios")
```

Once it is, from the distribution repository (the monorepo's `packages/ios` with
the engine as a released binary; `scripts/release/swift-dist.mjs`):

```swift
.package(url: "https://github.com/sinua-dev/sinua-swift", from: "0.1.0-beta.5")
```

The engine is a `.binaryTarget(path:)` pointing at `core_engineFFI.xcframework`,
which is built from `crates/core_engine` by `./build.sh` and is **not** checked
in. That path-based binary target only resolves inside this repository; a
released package needs `.binaryTarget(url:checksum:)` against a hosted zip — see
[`docs/publishing.md`](../../docs/publishing.md).

## Building and testing

```sh
./build.sh                       # cargo + uniffi -> core_engineFFI.xcframework
xcodebuild test -scheme Sinua-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  -only-testing:CoreEngineTests -only-testing:SinuaVoiceTests \
  -only-testing:SinuaTests -only-testing:SinuaGeminiLiveTests \
  -only-testing:SinuaElevenLabsTests
```

Always pass `-only-testing:` — an unfiltered run once hung in `simctl diagnose`
when another process shared the simulator.

The geometry is checked against the same golden vectors as every other platform
(`spec/orbs-golden.json`, `spec/sinua-golden.json`), and the voice analysis
against byte-level fixtures captured from Chrome (`spec/voice-golden.json`), so
the numbers this package produces are the numbers the Web produces.

## What is not verified

Everything here runs against fakes: fake audio devices, a test-driven clock, and
in-process fake servers on localhost. **No vendor session has ever run against
the real service, and no physical device has ever run this code** — simulator
only. The tests never open a microphone or play sound.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](../../NOTICE).
