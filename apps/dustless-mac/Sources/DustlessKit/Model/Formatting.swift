import Foundation

public enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    public static func string(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 B" }
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let number: String
        if index == 0 {
            number = "\(Int(value))"
        } else if value >= 100 {
            number = "\(Int(value.rounded()))"
        } else {
            number = String(format: "%.1f", value)
        }
        return "\(number) \(units[index])"
    }
}

public enum Duration {
    public static func milliseconds(_ value: Int) -> String {
        value < 1000 ? "\(value) ms" : String(format: "%.1f s", Double(value) / 1000)
    }

    public static func days(_ value: Double) -> String {
        value < 1 ? "today" : "\(Int(value.rounded()))d old"
    }
}
