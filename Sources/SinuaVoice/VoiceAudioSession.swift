import AVFoundation
import Foundation

/// How a WebRTC voice source sets up the app's audio session (design note 30, V1/V2).
/// Without it LiveKitWebRTC's engine stays in the default category: no mic frames go out
/// and nothing plays.
public enum VoiceAudioSession: Sendable, Equatable {
    /// Play and record, loudspeaker by default (headphones and Bluetooth still win): the
    /// `.videoChat` mode, as LiveKit's own fixed configuration. `.voiceChat` scales the
    /// volume for the earpiece, so it is very quiet on the speaker.
    case speaker
    /// Play and record through the earpiece, a phone call's `.voiceChat` mode.
    case receiver
    /// The app sets the session up itself; the source never touches it.
    case unmanaged

    /// What the source applies, or nil for `.unmanaged`.
    public var policy: AudioSessionPolicy? {
        switch self {
        case .speaker:
            AudioSessionPolicy(
                category: .playAndRecord, mode: .videoChat,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        case .receiver:
            AudioSessionPolicy(
                category: .playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        case .unmanaged:
            nil
        }
    }
}

/// A category, mode and options for the session. Never `overrideOutputAudioPort(.speaker)`:
/// it would beat headphones and Bluetooth; `.defaultToSpeaker` routes correctly.
public struct AudioSessionPolicy: Sendable, Equatable {
    public let category: AVAudioSession.Category
    public let mode: AVAudioSession.Mode
    public let options: AVAudioSession.CategoryOptions
}

/// Who holds the app's audio session among Sinua's voice sources (design note 30): the
/// first source to claim it activates it, the last to release it deactivates it, so one
/// source's disconnect never cuts another's audio, and a source that never activated the
/// session (`.unmanaged`) never touches it.
public final class AudioSessionClaims: @unchecked Sendable {
    public static let shared = AudioSessionClaims()
    private var holders = 0
    private let lock = NSLock()

    public init() {}

    /// Before a source connects: runs `activate` when no other source holds the session.
    /// A failed activation claims nothing.
    public func claim(_ activate: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if holders == 0 { try activate() }
        holders += 1
    }

    /// When a source that claimed the session is done: the last release runs `deactivate`.
    public func release(_ deactivate: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { deactivate() }
    }
}
