import Foundation
import CoreMedia

public enum FPSMode: Equatable {
    case mixed
    /// Constant output cadence with this exact frame duration (1/24, 1001/24000, …).
    case constant(frameDuration: Rational)
}

public enum ConstantStrategy: Equatable {
    case selective
    case reencodeAll
}

public struct AudioFormat: Equatable {
    public var sampleRate: Double
    public var channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Probed facts about one clip file.
public struct ClipMedia: Equatable {
    public var frames: FrameTable
    public var width: Int
    public var height: Int
    public var codec: FourCharCode
    public var nominalFPS: Double
    /// Bits per second, as reported by the track.
    public var estimatedDataRate: Float
    public var audio: AudioFormat?

    public init(frames: FrameTable, width: Int, height: Int, codec: FourCharCode,
                nominalFPS: Double, estimatedDataRate: Float, audio: AudioFormat?) {
        self.frames = frames
        self.width = width
        self.height = height
        self.codec = codec
        self.nominalFPS = nominalFPS
        self.estimatedDataRate = estimatedDataRate
        self.audio = audio
    }

    public var hasAudio: Bool { audio != nil }
}

public struct Clip: Identifiable, Equatable {
    public let id: UUID
    public var url: URL
    public var segments: [Segment]
    /// nil when the file is missing or unreadable.
    public var media: ClipMedia?

    public init(id: UUID = UUID(), url: URL, segments: [Segment], media: ClipMedia?) {
        self.id = id
        self.url = url
        self.segments = segments
        self.media = media
    }
}

public struct Project: Equatable {
    public var clips: [Clip]
    public var fpsMode: FPSMode
    public var constantStrategy: ConstantStrategy

    public init(clips: [Clip] = [],
                fpsMode: FPSMode = .constant(frameDuration: Rational(1, 24)),
                constantStrategy: ConstantStrategy = .reencodeAll) {
        self.clips = clips
        self.fpsMode = fpsMode
        self.constantStrategy = constantStrategy
    }
}

/// "avc1" → FourCharCode.
public func fourCC(_ s: String) -> FourCharCode {
    precondition(s.utf8.count == 4, "fourCC needs 4 ASCII characters")
    return s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}

/// The frame durations the fps picker offers.
public enum FrameRateChoice {
    /// Unique frame durations, ascending (so the fastest fps comes first). Exact-CFR clips
    /// give their exact `d`. Only if no clip is exact CFR, each clip falls back to
    /// `Rational.frameDuration(fps: nominalFPS)`. Clips without media are ignored.
    public static func candidates(for clips: [Clip]) -> [Rational] {
        let medias = clips.compactMap(\.media)
        var exact = medias.compactMap { $0.frames.exactFrameDuration }
        if exact.isEmpty {
            exact = medias.map { Rational.frameDuration(fps: $0.nominalFPS) }
        }
        return Array(Set(exact)).sorted()
    }

    /// The default Constant target: the highest fps present.
    public static func highest(for clips: [Clip]) -> Rational? {
        candidates(for: clips).first
    }
}
