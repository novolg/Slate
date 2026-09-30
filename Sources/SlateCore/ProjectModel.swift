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

    public init(clips: [Clip] = [], fpsMode: FPSMode = .mixed, constantStrategy: ConstantStrategy = .selective) {
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
