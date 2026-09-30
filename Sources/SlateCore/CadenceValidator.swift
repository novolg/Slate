import Foundation
import AVFoundation
import CoreMedia

public struct CadenceReport: Equatable {
    public let frameCount: Int
    public let videoDuration: Rational
    public let issues: [String]

    public init(frameCount: Int, videoDuration: Rational, issues: [String]) {
        self.frameCount = frameCount
        self.videoDuration = videoDuration
        self.issues = issues
    }

    public var ok: Bool { issues.isEmpty }
}

public enum CadenceValidator {
    /// Constant mode: frame n at exactly n·d, every sample duration exactly d
    /// (including the last), count as planned, and the track ends at the last frame's end.
    /// `durations[i]` is the reported duration of the frame at `pts[i]`.
    public static func cadenceIssues(pts: [Rational], durations: [Rational], videoEnd: Rational,
                                     frameDuration d: Rational, expectedFrames: Int) -> [String] {
        var issues: [String] = []
        if pts.count != expectedFrames {
            issues.append("frame count \(pts.count), expected \(expectedFrames)")
        }
        if durations.count != pts.count {
            issues.append("\(durations.count) durations for \(pts.count) frames")
        }
        var bad = 0
        for (n, p) in pts.enumerated() where p != d * n {
            if bad < 5 { issues.append("frame \(n) at \(p), expected \(d * n)") }
            bad += 1
        }
        if bad > 5 { issues.append("\(bad - 5) more frames off the grid") }
        var badDur = 0
        for (n, dur) in durations.enumerated() where dur != d {
            if badDur < 5 { issues.append("frame \(n) lasts \(dur), expected \(d)") }
            badDur += 1
        }
        if badDur > 5 { issues.append("\(badDur - 5) more frames with a wrong duration") }
        if let last = pts.last, videoEnd - last != d {
            issues.append("track ends \(videoEnd - last) after the last frame, expected \(d)")
        }
        return issues
    }

    /// Mixed mode: frame count, exact total duration and (when given) the exact pts list.
    public static func mixedIssues(frameCount: Int, expectedFrames: Int, duration: Rational,
                                   expectedDuration: Rational, pts: [Rational]? = nil,
                                   expectedPTS: [Rational]? = nil) -> [String] {
        var issues: [String] = []
        if frameCount != expectedFrames {
            issues.append("frame count \(frameCount), expected \(expectedFrames)")
        }
        if duration != expectedDuration {
            issues.append("duration \(duration.seconds) s, expected \(expectedDuration.seconds) s")
        }
        if let pts, let expectedPTS {
            var bad = 0
            for (n, pair) in zip(pts, expectedPTS).enumerated() where pair.0 != pair.1 {
                if bad < 5 { issues.append("frame \(n) at \(pair.0), expected \(pair.1)") }
                bad += 1
            }
            if bad > 5 { issues.append("\(bad - 5) more frames off the expected time") }
        }
        return issues
    }

    /// Audio must start at 0 and end with the video, each within one AAC packet (1024 samples).
    public static func audioIssues(firstAudioPTS: Rational?, audioEnd: Rational?, videoEnd: Rational,
                                   sampleRate: Double) -> [String] {
        guard let first = firstAudioPTS, let end = audioEnd else { return ["no decodable audio"] }
        let packet = Rational(1024, Int64(sampleRate.rounded()))
        var issues: [String] = []
        if first.magnitude > packet {
            issues.append("audio starts at \(first.seconds) s (priming not compensated?)")
        }
        if (end - videoEnd).magnitude > packet {
            issues.append("audio ends at \(end.seconds) s, video at \(videoEnd.seconds) s")
        }
        return issues
    }

    /// Decode the file (edit lists applied) and check it.
    /// `frameDuration` nil means Mixed mode.
    public static func validate(url: URL, frameDuration: Rational?, expectedFrames: Int,
                                expectedDuration: Rational, audioSampleRate: Double?,
                                expectedPTS: [Rational]? = nil) async throws -> CadenceReport {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipProbeError.noVideoTrack
        }
        let videoRange = try await videoTrack.load(.timeRange)
        let video = try decodedTimes(asset: asset, track: videoTrack, settings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        try Task.checkCancellation()
        let videoEnd = Rational(videoRange.end)
        let pts = video.map(\.pts)

        var issues: [String] = []
        if let d = frameDuration {
            issues += cadenceIssues(pts: pts, durations: try await frameDurations(asset: asset, track: videoTrack, decoded: video),
                                    videoEnd: videoEnd, frameDuration: d, expectedFrames: expectedFrames)
        } else {
            issues += mixedIssues(frameCount: pts.count, expectedFrames: expectedFrames,
                                  duration: videoEnd - (pts.first ?? .zero), expectedDuration: expectedDuration,
                                  pts: pts, expectedPTS: expectedPTS)
        }

        try Task.checkCancellation()
        if let sampleRate = audioSampleRate {
            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                let audio = try decodedTimes(asset: asset, track: audioTrack, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                ])
                issues += audioIssues(firstAudioPTS: audio.first?.pts,
                                      audioEnd: audio.last.map { $0.pts + $0.duration },
                                      videoEnd: videoEnd, sampleRate: sampleRate)
            } else {
                issues.append("no audio track")
            }
        }
        return CadenceReport(frameCount: pts.count, videoDuration: videoEnd, issues: issues)
    }

    /// Duration of each decoded frame. Every duration the decoder reports is kept as is
    /// (so a wrong one is still caught). Only missing entries (0) are filled from the
    /// sample table, matched by pts. A frame missing in both sources stays 0 and fails.
    static func frameDurations(asset: AVAsset, track: AVAssetTrack,
                               decoded: [(pts: Rational, duration: Rational)]) async throws -> [Rational] {
        if decoded.allSatisfy({ $0.duration > .zero }) {
            return decoded.map(\.duration)
        }
        let table = try await ClipProbe.readFrameTable(asset: asset, track: track)
        return mergeDurations(decoded: decoded, table: table)
    }

    /// Pure merge used above. Public for checks.
    public static func mergeDurations(decoded: [(pts: Rational, duration: Rational)],
                                      table: FrameTable) -> [Rational] {
        var byPTS: [Rational: Rational] = [:]
        for (p, d) in zip(table.pts, table.durations) { byPTS[p] = d }
        return decoded.map { $0.duration > .zero ? $0.duration : (byPTS[$0.pts] ?? .zero) }
    }

    static func decodedTimes(asset: AVAsset, track: AVAssetTrack,
                             settings: [String: Any]) throws -> [(pts: Rational, duration: Rational)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ClipProbeError.readerFailed("cannot add output") }
        reader.add(output)
        guard reader.startReading() else {
            throw ClipProbeError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }
        var out: [(pts: Rational, duration: Rational)] = []
        var seen = 0
        while let buffer = output.copyNextSampleBuffer() {
            seen += 1
            if seen % 64 == 0 { try Task.checkCancellation() }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard pts.isNumeric else { continue }
            let dur = CMSampleBufferGetDuration(buffer)
            out.append((Rational(pts), dur.isNumeric ? Rational(dur) : .zero))
        }
        if reader.status == .failed {
            throw ClipProbeError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        return out.sorted { $0.pts < $1.pts }
    }
}
