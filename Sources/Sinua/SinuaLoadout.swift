import CoreEngine
import SwiftUI

/// An end user's choice for a character (FX Spec 1.13, design note 25): small, so the app
/// stores it in its own account and passes it back next launch. `wear`: ids from the spec's
/// `wardrobe` (or its `cosmetics`), one per slot; `palette`: a `wardrobe.palettes` name or a
/// built-in palette (`sunset`, `ocean`, ...); `iris`: an eye colour by name, a `wardrobe.irises`
/// name or a catalog one (`catalog:eyes-hazel`, design note 27); `eyeStyle`: `auto`, `shape`,
/// `glossy`, `pixel`, `dot`.
public struct SinuaLoadout: Codable, Equatable, Sendable {
    /// The loadout format, 1.
    public var loadout: Int
    public var wear: [String]?
    public var palette: String?
    public var eyeStyle: String?
    public var iris: String?

    public init(wear: [String]? = nil, palette: String? = nil, eyeStyle: String? = nil, iris: String? = nil) {
        loadout = 1
        self.wear = wear
        self.palette = palette
        self.eyeStyle = eyeStyle
        self.iris = iris
    }

    /// A stored loadout read back: every field may be missing (an older or newer app wrote it).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loadout = (try? c.decodeIfPresent(Int.self, forKey: .loadout)) ?? 1
        wear = try? c.decodeIfPresent([String].self, forKey: .wear)
        palette = try? c.decodeIfPresent(String.self, forKey: .palette)
        eyeStyle = try? c.decodeIfPresent(String.self, forKey: .eyeStyle)
        iris = try? c.decodeIfPresent(String.self, forKey: .iris)
    }

    /// The loadout as JSON (what the engine reads, and what to store).
    public var json: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// `spec` with this loadout applied: what the spec no longer offers is skipped and warns.
    public func apply(to spec: String) -> (spec: String, warnings: [FxDiagnostic]) {
        let r = applyLoadout(spec: spec, loadout: json)
        return (r.spec, r.diagnostics)
    }
}

/// One wardrobe item for a picker: whether it fits a character, and why not.
public struct SinuaCosmeticFit: Equatable, Sendable {
    public let id: String
    public let fits: Bool
    /// A key to translate: `fits`, `no-slot` or `not-made-for`.
    public let reason: String
    /// The reason in English ("" when it fits).
    public let why: String

    /// What `spec`'s wardrobe offers `character` (a built-in id, or the spec's own recipe's id).
    public static func list(spec: String, character: String) -> [SinuaCosmeticFit] {
        // The engine carries each row in the diagnostic record: path = id, severity = reason.
        cosmeticsFor(spec: spec, character: character).map {
            SinuaCosmeticFit(id: $0.path, fits: $0.severity == "fits", reason: $0.severity, why: $0.message)
        }
    }
}

/// Thumbnails for a picker screen (design note 25).
public enum SinuaThumbnail {
    /// `spec` wearing `loadout`, still (no blink, no glance), `size` points across at `scale`,
    /// turned `turnYaw` radians (0 = facing). Transparent around the character; nil if the spec
    /// doesn't resolve. iOS 16+ (SwiftUI's `ImageRenderer`); on iOS 15 draw `frameStill`'s frame
    /// with `FxPaint.draw` yourself.
    @available(iOS 16.0, *)
    @MainActor
    public static func image(
        spec: String, loadout: SinuaLoadout? = nil, size: Double = 128, scale: Double = 2,
        dark: Bool = false, turnYaw: Double = 0
    ) -> CGImage? {
        guard
            let frame = frameStill(
                spec: spec, loadout: loadout?.json ?? "", size: UInt32(max(1, size.rounded())), turnYaw: turnYaw)
        else { return nil }
        let view = Canvas { context, box in
            var c = context
            FxPaint.draw(frame, into: &c, size: box, engineSize: size, dark: dark)
        }
        .frame(width: size, height: size)
        let r = ImageRenderer(content: view)
        r.scale = scale
        return r.cgImage
    }
}

/// Sinua's catalog pack (FX Spec 1.13, design note 26): ready cosmetics and palettes, free
/// with the runtime. After `SinuaCatalog.load()` a spec may say `"cosmetics": ["catalog:crown"]`
/// or `"palette": "catalog:berry"`. A brand loads its own pack with `loadCatalog(json:)`, from a
/// bundled file or a URL.
public enum SinuaCatalog {
    /// The pack's JSON (a resource of this package; nil where it isn't bundled, e.g. React
    /// Native, whose apps pass the pack from JS).
    public static var json: String? {
        #if SWIFT_PACKAGE
            guard let url = Bundle.module.url(forResource: "catalog-1", withExtension: "json") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        #else
            return nil
        #endif
    }

    /// Loads the pack into the engine (again is harmless: it replaces itself). Problems, if any.
    @discardableResult
    public static func load() -> [FxDiagnostic] {
        guard let json else {
            return [FxDiagnostic(severity: "error", path: "", message: "the catalog resource isn't bundled")]
        }
        return loadCatalog(json: json)
    }
}
