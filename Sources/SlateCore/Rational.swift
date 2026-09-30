import Foundation
import CoreMedia

/// Exact rational number for all timing math. Always reduced, denominator > 0.
/// Overflow is a programming error (values here are small: seconds × timescales).
public struct Rational: Hashable, Comparable, CustomStringConvertible {
    public let num: Int64
    public let den: Int64

    public init(_ num: Int64, _ den: Int64 = 1) {
        precondition(den != 0, "Rational: zero denominator")
        let sign: Int64 = den < 0 ? -1 : 1
        let g = Rational.gcd(Swift.abs(num), Swift.abs(den))
        let divisor = g == 0 ? 1 : g
        self.num = sign * (num / divisor)
        self.den = sign * (den / divisor)
    }

    public init(_ time: CMTime) {
        precondition(time.isNumeric, "Rational: non-numeric CMTime \(time)")
        self.init(time.value, Int64(time.timescale))
    }

    public static let zero = Rational(0)

    public static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = Swift.abs(a)
        var y = Swift.abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Least common multiple, or nil on overflow.
    public static func lcm(_ a: Int64, _ b: Int64) -> Int64? {
        if a == 0 || b == 0 { return 0 }
        let (r, overflow) = (Swift.abs(a) / gcd(a, b)).multipliedReportingOverflow(by: Swift.abs(b))
        return overflow ? nil : r
    }

    private static func mul(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.multipliedReportingOverflow(by: b)
        precondition(!o, "Rational overflow")
        return r
    }

    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.addingReportingOverflow(b)
        precondition(!o, "Rational overflow")
        return r
    }

    public static func + (l: Rational, r: Rational) -> Rational {
        let g = gcd(l.den, r.den)
        let lScale = r.den / g
        let rScale = l.den / g
        return Rational(add(mul(l.num, lScale), mul(r.num, rScale)), mul(l.den, lScale))
    }

    public static prefix func - (x: Rational) -> Rational { Rational(-x.num, x.den) }

    public static func - (l: Rational, r: Rational) -> Rational { l + (-r) }

    public static func * (l: Rational, r: Rational) -> Rational {
        let g1 = gcd(l.num, r.den)
        let g2 = gcd(r.num, l.den)
        let a = g1 == 0 ? 1 : g1
        let b = g2 == 0 ? 1 : g2
        return Rational(mul(l.num / a, r.num / b), mul(l.den / b, r.den / a))
    }

    public static func * (l: Rational, n: Int) -> Rational { l * Rational(Int64(n)) }

    public static func / (l: Rational, r: Rational) -> Rational {
        precondition(r.num != 0, "Rational: division by zero")
        return l * Rational(r.den, r.num)
    }

    public static func < (l: Rational, r: Rational) -> Bool { (l - r).num < 0 }

    /// Largest integer ≤ self.
    public func floor() -> Int64 {
        let q = num / den
        return (num % den != 0 && num < 0) ? q - 1 : q
    }

    /// Round half up: floor(self + 1/2).
    public func rounded() -> Int64 { (self + Rational(1, 2)).floor() }

    public var magnitude: Rational { Rational(Swift.abs(num), den) }

    public var seconds: Double { Double(num) / Double(den) }

    /// CMTime with the reduced denominator as timescale.
    public var cmTime: CMTime {
        precondition(den <= Int64(Int32.max), "Rational: denominator too large for CMTime")
        return CMTime(value: num, timescale: Int32(den))
    }

    /// CMTime in `timescale`, or nil if self is not a whole number of ticks.
    public func cmTime(timescale: Int32) -> CMTime? {
        let scaled = self * Rational(Int64(timescale))
        guard scaled.den == 1 else { return nil }
        return CMTime(value: scaled.num, timescale: timescale)
    }

    /// Exact frame duration for a nominal fps (handles NTSC rates).
    public static func frameDuration(fps: Double) -> Rational {
        let ntsc: [(Int64, Int64)] = [(24000, 1001), (30000, 1001), (48000, 1001), (60000, 1001), (120000, 1001)]
        for (n, d) in ntsc where Swift.abs(fps - Double(n) / Double(d)) < 0.001 {
            return Rational(d, n)
        }
        let whole = fps.rounded()
        if whole > 0, Swift.abs(fps - whole) < 0.001 {
            return Rational(1, Int64(whole))
        }
        return Rational(1000, Int64((fps * 1000).rounded()))
    }

    public var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }
}
