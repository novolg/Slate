import Foundation
import SlateCore

func runProbeChecks() async {
    await checkAsync("probe: 24 fps fixture has exact frame timing") {
        let m = try await ClipProbe.probe(url: try fixture("c24.mp4"))
        expectEqual(m.frames.count, 120)
        expectEqual(m.frames.pts.first, Rational.zero)
        expectEqual(m.frames.exactFrameDuration, Rational(1, 24))
        expectEqual(m.frames.clipEnd, Rational(5))
        expectEqual(m.frames.timescale, 12288)
        expectEqual(m.width, 640)
        expectEqual(m.height, 360)
        expectEqual(m.codec, fourCC("avc1"))
        expect(m.audio == nil)
    }

    await checkAsync("probe: 48 fps fixture is exact 1/48") {
        let m = try await ClipProbe.probe(url: try fixture("c48.mp4"))
        expectEqual(m.frames.exactFrameDuration, Rational(1, 48))
        expect(m.frames.count > 200, "count \(m.frames.count)")
    }

    await checkAsync("probe: audio format is read") {
        let m = try await ClipProbe.probe(url: try fixture("c24_a.mp4"))
        expectEqual(m.audio, AudioFormat(sampleRate: 44100, channels: 1))
    }

    await checkAsync("probe: 23.976 at timescale 90000 is not copyable at 1001/24000") {
        let m = try await ClipProbe.probe(url: try fixture("j23976.mp4"))
        expectEqual(m.frames.timescale, 90000)
        expect(m.frames.exactFrameDuration != Rational(1001, 24000),
               "90000 cannot hold 1001/24000 exactly")
    }
}
