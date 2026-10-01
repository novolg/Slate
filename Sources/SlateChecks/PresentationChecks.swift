import Foundation
import SlateCore

func runPresentationChecks() {
    let whole = [(Rational.zero, Rational(5))]

    check("presentation: fps text is exact and short") {
        expectEqual(ClipPresentation.fpsText(Rational(1, 24)), "24 fps")
        expectEqual(ClipPresentation.fpsText(Rational(1, 48)), "48 fps")
        expectEqual(ClipPresentation.fpsText(Rational(1001, 24000)), "23.976 fps")
        expectEqual(ClipPresentation.fpsText(Rational(1001, 30000)), "29.97 fps")
    }

    check("presentation: card shows kept / total seconds, index and audio") {
        let a = TestData.clip(TestData.media(TestData.c24, audio: true), keep: [(.zero, Rational(5, 2))])
        let plan = ExportPlanner.plan(Project(clips: [a]))
        let card = ClipPresentation.card(for: a, index: 3, plan: plan)
        expectEqual(card.index, 3)
        expectEqual(card.keptText, "2.5 / 5.0 s")
        expectEqual(card.fpsText, "24 fps")
        expect(card.hasAudio)
        expectEqual(card.tone, ClipCardInfo.Tone.normal)
    }

    check("presentation: in Constant mode only clips whose own timing would not copy are yellow") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c48), keep: whole)
        var jm = TestData.media(TestData.jittered23976(count: 120))
        jm.nominalFPS = 24000.0 / 1001.0
        let j = TestData.clip(jm, keep: [(.zero, Rational(4))])
        let plan = ExportPlanner.plan(Project(clips: [a, b, j], fpsMode: .constant(frameDuration: Rational(1, 24))))
        expectEqual(ClipPresentation.card(for: a, index: 1, plan: plan).tone, ClipCardInfo.Tone.normal)
        let cb = ClipPresentation.card(for: b, index: 2, plan: plan)
        expectEqual(cb.tone, ClipCardInfo.Tone.warning)
        expect(cb.tooltip.contains("48 fps") && cb.tooltip.contains("24 fps"), cb.tooltip)
        let cj = ClipPresentation.card(for: j, index: 3, plan: plan)
        expectEqual(cj.tone, ClipCardInfo.Tone.warning)
        expect(cj.tooltip.contains("not exact"), cj.tooltip)
    }

    check("presentation: Mixed mode has no yellow badges") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c48), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: .mixed))
        for (i, c) in [a, b].enumerated() {
            expectEqual(ClipPresentation.card(for: c, index: i + 1, plan: plan).tone, ClipCardInfo.Tone.normal)
        }
    }

    check("presentation: missing or blocked clips are red with a reason") {
        let ok = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let gone = TestData.clip(nil, keep: whole)
        let small = TestData.clip(TestData.media(TestData.c24, width: 320, height: 180), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [ok, gone, small]))
        let cg = ClipPresentation.card(for: gone, index: 2, plan: plan)
        expectEqual(cg.tone, ClipCardInfo.Tone.error)
        expectEqual(cg.fpsText, "—")
        let cs = ClipPresentation.card(for: small, index: 3, plan: plan)
        expectEqual(cs.tone, ClipCardInfo.Tone.error)
        expect(cs.tooltip.contains("Frame size"), cs.tooltip)
    }

    check("presentation: a clip with an unusable nominal fps does not crash the card") {
        var jm = TestData.media(TestData.jittered23976(count: 120))
        jm.nominalFPS = 0
        let j = TestData.clip(jm, keep: [(.zero, Rational(4))])
        let plan = ExportPlanner.plan(Project(clips: [j]))
        expectEqual(ClipPresentation.card(for: j, index: 1, plan: plan).fpsText, "—")
    }

    check("presentation: plan rows explain each clip and count sub-frame selections") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let tiny = TestData.clip(TestData.media(TestData.c24), keep: [(.zero, Rational(1, 100)), (Rational(1), Rational(2))])
        let empty = TestData.clip(TestData.media(TestData.c24), keep: [])
        let plan = ExportPlanner.plan(Project(clips: [a, tiny, empty]))
        let rows = ClipPresentation.rows(plan, project: Project(clips: [a, tiny, empty]))
        expectEqual(rows.count, 3)
        expect(rows[0].text.hasPrefix("Re-encode"), rows[0].text)
        expect(rows[1].text.contains("shorter than one frame"), rows[1].text)
        expect(rows[2].text.contains("Skipped"), rows[2].text)
    }

    check("presentation: blocker texts name the clip; summary and mode text read well") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let gone = TestData.clip(nil, keep: whole)
        let project = Project(clips: [a, gone])
        let plan = ExportPlanner.plan(project)
        let texts = ClipPresentation.blockerTexts(plan, project: project)
        expect(texts.contains { $0.contains(gone.url.lastPathComponent) }, "\(texts)")
        expectEqual(ClipPresentation.blockerTexts(ExportPlanner.plan(Project()), project: Project()), ["Add at least one clip."])
        let ok = ExportPlanner.plan(Project(clips: [a]))
        expectEqual(ClipPresentation.summary(ok), "5.0 s · 120 frames")
        expect(ClipPresentation.modeText(ok).hasPrefix("Constant 24 fps"))
        expect(ClipPresentation.modeText(ExportPlanner.plan(Project(clips: [a], fpsMode: .mixed))).hasPrefix("Mixed"))
    }

    check("presentation: default output name") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c24), keep: whole)
        expectEqual(ClipPresentation.defaultOutputName(project: Project(clips: [a]), documentName: nil),
                    "\(a.url.deletingPathExtension().lastPathComponent) — trimmed.mp4")
        expectEqual(ClipPresentation.defaultOutputName(project: Project(clips: [a, b]), documentName: nil), "Slate export.mp4")
        expectEqual(ClipPresentation.defaultOutputName(project: Project(clips: [a, b]), documentName: "Trailer"), "Trailer.mp4")
    }

    check("presentation: the Mixed label is the ruled text") {
        expectEqual(ClipPresentation.mixedLabel,
                    "Apple players only (QuickTime, Safari, Final Cut). For upload or other players use Constant.")
    }
}
