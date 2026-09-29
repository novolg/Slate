import Foundation
import CoreMedia
import SlateCore

func runRationalChecks() {
    check("rational: normalizes sign and gcd") {
        expectEqual(Rational(2, 4), Rational(1, 2))
        expectEqual(Rational(-1, -2), Rational(1, 2))
        expectEqual(Rational(1, -2), Rational(-1, 2))
        expectEqual(Rational(0, 7), Rational.zero)
    }

    check("rational: arithmetic is exact") {
        expectEqual(Rational(1, 24) + Rational(1, 48), Rational(1, 16))
        expectEqual(Rational(1, 24) - Rational(1, 48), Rational(1, 48))
        expectEqual(Rational(1001, 24000) * 240, Rational(1001, 100))
        expectEqual(Rational(5, 24) / Rational(1, 48), Rational(10))
        expect(Rational(1, 3) < Rational(1, 2))
        expect(Rational(-1, 2) < Rational.zero)
    }

    check("rational: floor and round-half-up") {
        expectEqual(Rational(-1, 2).floor(), -1)
        expectEqual(Rational(7, 2).floor(), 3)
        expectEqual(Rational(5, 2).rounded(), 3)
        expectEqual(Rational(1, 2).rounded(), 1)
        expectEqual(Rational(-1, 2).rounded(), 0)
        expectEqual(Rational(149, 100).rounded(), 1)
    }

    check("rational: CMTime conversion") {
        expectEqual(Rational(CMTime(value: 1001, timescale: 24000)), Rational(1001, 24000))
        expectEqual(Rational(1, 24).cmTime(timescale: 12288), CMTime(value: 512, timescale: 12288))
        expect(Rational(1, 7).cmTime(timescale: 12288) == nil)
        expectEqual(Rational(3, 2).cmTime, CMTime(value: 3, timescale: 2))
    }

    check("rational: frame duration from fps") {
        expectEqual(Rational.frameDuration(fps: 23.976), Rational(1001, 24000))
        expectEqual(Rational.frameDuration(fps: 29.97), Rational(1001, 30000))
        expectEqual(Rational.frameDuration(fps: 24), Rational(1, 24))
        expectEqual(Rational.frameDuration(fps: 48.0), Rational(1, 48))
    }

    check("rational: gcd and lcm") {
        expectEqual(Rational.gcd(12288, 24), 24)
        expectEqual(Rational.lcm(12288, 24), 12288)
        expectEqual(Rational.lcm(24000, 90000), 360000)
        expect(Rational.lcm(Int64.max, Int64.max - 1) == nil, "consecutive numbers are coprime; the product overflows")
    }
}
