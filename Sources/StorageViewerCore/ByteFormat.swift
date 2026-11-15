import Foundation

public enum ByteFormat {
    public static func bytes(_ value: Int64) -> String {
        let negative = value < 0
        var magnitude = Double(negative ? -value : value)
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var unit = 0
        while magnitude >= 1024, unit < units.count - 1 {
            magnitude /= 1024
            unit += 1
        }
        let number: String
        if unit == 0 {
            number = countFormatter.string(from: NSNumber(value: Int64(magnitude))) ?? "0"
        } else if magnitude >= 100 {
            number = fraction(magnitude, digits: 0)
        } else if magnitude >= 10 {
            number = fraction(magnitude, digits: 1)
        } else {
            number = fraction(magnitude, digits: 2)
        }
        return (negative ? "-" : "") + number + " " + units[unit]
    }

    public static func count(_ value: Int) -> String {
        lockedString(countFormatter, NSNumber(value: value)) ?? "\(value)"
    }

    /// One decimal, with a floor so tiny shares do not display as zero.
    public static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0, part > 0 else { return "0%" }
        let value = (Double(part) / Double(whole)) * 100
        if value < 0.1 { return "<0.1%" }
        let digits = fraction(value, digits: 1)
        return digits + "%"
    }

    private static func fraction(_ value: Double, digits: Int) -> String {
        let formatter = fractionFormatters[digits]
        return lockedString(formatter, NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    private static func lockedString(_ formatter: NumberFormatter, _ number: NSNumber) -> String? {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return formatter.string(from: number)
    }

    private static let formatterLock = NSLock()

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let fractionFormatters: [NumberFormatter] = (0...2).map { digits in
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.usesGroupingSeparator = false
        return formatter
    }
}
