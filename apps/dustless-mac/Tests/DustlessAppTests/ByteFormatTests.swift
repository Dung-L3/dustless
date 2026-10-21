import Testing
import Foundation
import DustlessKit
@Suite("byte formatting")
struct ByteFormatTests {
    @Test func boundariesAreExact() {
        #expect(ByteFormat.string(0) == "0 B")
        #expect(ByteFormat.string(1023) == "1023 B")
        #expect(ByteFormat.string(1024) == "1.0 KB")
        #expect(ByteFormat.string(1_048_576) == "1.0 MB")
        #expect(ByteFormat.string(1_073_741_824) == "1.0 GB")
    }

    @Test(arguments: [UInt64(0), 1, 999, 1023, 1024, 1025, 1_048_575, 1_048_576, 1_099_511_627_776])
    func neverProducesNaNOrEmptyOrNegative(_ value: UInt64) {
        let text = ByteFormat.string(value)
        #expect(!text.isEmpty, "empty for \(value)")
        #expect(!text.lowercased().contains("nan"), "NaN for \(value)")
        #expect(!text.contains("-"), "negative for \(value)")
    }

    @Test func veryLargeValueStaysReadable() {
        let text = ByteFormat.string(5_000_000_000_000_000_000)
        #expect(text.contains("TB") || text.contains("PB"))
    }
}
