import Foundation
import SlateCore

func runValidatorChecks() async {
    let d = Rational(1, 24)
    let perfect = (0..<48).map { d * $0 }
    let perfectDur = Array(repeating: d, count: 48)

    func issues(_ pts: [Rational], _ durs: [Rational], end: Rational = Rational(2)) -> [String] {
        CadenceValidator.cadenceIssues(pts: pts, durations: durs, videoEnd: end, frameDuration: d, expectedFrames: 48)
    }

    check("validator: a perfect grid has no issues") {
        expect(issues(perfect, perfectDur).isEmpty)
    }

    check("validator: shifted, missing frames and a short track end are reported") {
        var shifted = perfect
        shifted[10] = shifted[10] + Rational(1, 12288)
        expect(!issues(shifted, perfectDur).isEmpty)
        expect(!issues(Array(perfect.dropLast()), Array(perfectDur.dropLast())).isEmpty)
        expect(!issues(perfect, perfectDur, end: Rational(2) - Rational(1, 100)).isEmpty)
    }

    check("validator: a wrong middle or final sample duration is reported with perfect pts and track end") {
        var middle = perfectDur
        middle[20] = Rational(1, 48)
        expect(!issues(perfect, middle).isEmpty, "middle duration")
        var final = perfectDur
        final[47] = Rational(1, 48)
        expect(!issues(perfect, final).isEmpty, "final duration")
        var zero = perfectDur
        zero[5] = .zero
        expect(!issues(perfect, zero).isEmpty, "missing duration")
    }

    check("validator: fallback fills only missing durations and keeps a wrong decoded one") {
        let table = FrameTable.uniform(count: 4, frameDuration: d, timescale: 12288)
        let decoded: [(pts: Rational, duration: Rational)] = [
            (d * 0, d), (d * 1, d / Rational(2)), (d * 2, .zero), (d * 3, d),
        ]
        let merged = CadenceValidator.mergeDurations(decoded: decoded, table: table)
        expectEqual(merged, [d, d / Rational(2), d, d])
        let found = CadenceValidator.cadenceIssues(pts: decoded.map(\.pts), durations: merged,
                                                   videoEnd: d * 4, frameDuration: d, expectedFrames: 4)
        expect(!found.isEmpty, "the half-length frame must be reported")
    }

    check("validator: audio start and end within one AAC packet") {
        let ok = CadenceValidator.audioIssues(firstAudioPTS: .zero, audioEnd: Rational(2) + Rational(1, 100),
                                              videoEnd: Rational(2), sampleRate: 44100)
        expect(ok.isEmpty, "\(ok)")
        let late = CadenceValidator.audioIssues(firstAudioPTS: Rational(1, 10), audioEnd: Rational(2),
                                                videoEnd: Rational(2), sampleRate: 44100)
        expect(!late.isEmpty)
        expect(!CadenceValidator.audioIssues(firstAudioPTS: nil, audioEnd: nil, videoEnd: Rational(2), sampleRate: 44100).isEmpty)
    }

    check("validator: mixed checks count and duration") {
        expect(CadenceValidator.mixedIssues(frameCount: 10, expectedFrames: 10, duration: Rational(1), expectedDuration: Rational(1)).isEmpty)
        expect(!CadenceValidator.mixedIssues(frameCount: 9, expectedFrames: 10, duration: Rational(1), expectedDuration: Rational(1)).isEmpty)
        expect(!CadenceValidator.mixedIssues(frameCount: 10, expectedFrames: 10, duration: Rational(11, 10), expectedDuration: Rational(1)).isEmpty)
    }

    await checkAsync("validator: the 24 fps fixture itself passes a Constant-24 check") {
        let report = try await CadenceValidator.validate(url: try fixture("c24_a.mp4"), frameDuration: d,
                                                         expectedFrames: 120, expectedDuration: Rational(5),
                                                         audioSampleRate: 44100)
        expect(report.ok, "\(report.issues)")
        expectEqual(report.frameCount, 120)
    }
}
