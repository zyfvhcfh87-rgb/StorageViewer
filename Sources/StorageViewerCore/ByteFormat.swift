import Foundation

public enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    public static func bytes(_ value: Int64) -> String {
        let negative = value < 0
        let rawMagnitude = value.magnitude
        if rawMagnitude < 1024 {
            return (negative ? "-" : "") + formatGrouped(rawMagnitude) + " B"
        }

        var magnitude = Double(rawMagnitude)
        var unit = 0
        while magnitude >= 1024, unit < units.count - 1 {
            magnitude /= 1024
            unit += 1
        }

        // Handle rounding boundary crossings (e.g. 9.996 KB -> 10.0 KB, 1023.6 KB -> 1.00 MB).
        var digits: Int
        if magnitude >= 100 {
            digits = 0
            if magnitude.rounded(.toNearestOrEven) >= 1024, unit < units.count - 1 {
                magnitude /= 1024
                unit += 1
                digits = 2
            }
        } else if magnitude >= 10 {
            digits = (magnitude * 10).rounded(.toNearestOrEven) >= 1000 ? 0 : 1
        } else {
            digits = (magnitude * 100).rounded(.toNearestOrEven) >= 1000 ? 1 : 2
        }

        let number = formatFixed(magnitude, digits: digits)
        return (negative ? "-" : "") + number + " " + units[unit]
    }

    public static func count(_ value: Int) -> String {
        let grouped = formatGrouped(UInt64(value.magnitude))
        return value < 0 ? "-" + grouped : grouped
    }

    /// One decimal, with a floor so tiny shares do not display as zero.
    public static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0, part > 0 else { return "0%" }
        let value = (Double(part) / Double(whole)) * 100
        if value < 0.1 { return "<0.1%" }
        return formatFixed(value, digits: 1) + "%"
    }

    private static func formatFixed(_ value: Double, digits: Int) -> String {
        guard value.isFinite, value >= 0, value < 1e15 else {
            return String(format: "%.\(digits)f", value)
        }
        switch digits {
        case 0:
            return String(UInt64(value.rounded(.toNearestOrEven)))
        case 1:
            let scaled = UInt64((value * 10).rounded(.toNearestOrEven))
            return "\(scaled / 10).\(scaled % 10)"
        case 2:
            let scaled = UInt64((value * 100).rounded(.toNearestOrEven))
            let frac = scaled % 100
            return frac < 10 ? "\(scaled / 100).0\(frac)" : "\(scaled / 100).\(frac)"
        default:
            return String(format: "%.\(digits)f", value)
        }
    }

    private static func formatGrouped(_ value: UInt64) -> String {
        if value < 1_000 {
            return String(value)
        }
        var buffer: [UInt8] = []
        buffer.reserveCapacity(26)
        var remaining = value
        var groupCount = 0
        while remaining > 0 {
            if groupCount == 3 {
                buffer.append(0x2C) // ','
                groupCount = 0
            }
            buffer.append(0x30 &+ UInt8(remaining % 10))
            remaining /= 10
            groupCount += 1
        }
        buffer.reverse()
        return String(decoding: buffer, as: UTF8.self)
    }
}
