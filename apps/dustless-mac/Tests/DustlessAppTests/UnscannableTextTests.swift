import Testing
import Foundation
import DustlessKit

@Suite("unscannable text logic")
struct UnscannableTextTests {
    @Test func emptyWhenZeroUnscannable() throws {
        let summary = UnscannableSummary(absent: 0, noAccess: 0, notSupported: 0, error: 0)
        let report = try makeReport(summary: summary)
        #expect(try UnscannableText.bannerParts(report: report, lang: .en) == nil)
        #expect(try UnscannableText.bannerParts(report: report, lang: .vi) == nil)
        #expect(try UnscannableText.bannerParts(report: report, lang: .zh) == nil)
    }

    @Test func singleReasonProducesSentenceParts() throws {
        let summary = UnscannableSummary(absent: 3, noAccess: 0, notSupported: 0, error: 0)
        let report = try makeReport(summary: summary)
        let parts = try #require(UnscannableText.bannerParts(report: report, lang: .en))
        #expect(parts.count == 3)
        #expect(parts.reasonLabels == ["absent"])
    }

    @Test func eachReasonCodeMapsToLocalizedLabel() throws {
        let summary = UnscannableSummary(absent: 1, noAccess: 2, notSupported: 3, error: 4)
        let report = try makeReport(summary: summary)

        let enParts = try #require(UnscannableText.bannerParts(report: report, lang: .en))
        #expect(enParts.reasonLabels == ["absent", "no access", "not supported", "error"])

        let viParts = try #require(UnscannableText.bannerParts(report: report, lang: .vi))
        #expect(viParts.reasonLabels == ["thiếu", "không truy cập", "không hỗ trợ", "lỗi"])

        let zhParts = try #require(UnscannableText.bannerParts(report: report, lang: .zh))
        #expect(zhParts.reasonLabels == ["缺失", "无访问权限", "不支持", "错误"])
    }

    @Test func mixedReasonsListEachLabelOnce() throws {
        let summary = UnscannableSummary(absent: 2, noAccess: 1, notSupported: 0, error: 1)
        let report = try makeReport(summary: summary)
        let parts = try #require(UnscannableText.bannerParts(report: report, lang: .en))
        #expect(parts.count == 4)
        #expect(parts.reasonLabels == ["absent", "no access", "error"])
    }

    @Test func reasonsPresentReturnsOnlyNonZeroReasons() {
        let summary = UnscannableSummary(absent: 0, noAccess: 2, notSupported: 0, error: 1)
        let reasons = UnscannableText.reasonsPresent(in: summary)
        #expect(reasons == [.noAccess, .error])
    }

    @Test func reasonsPresentReturnsEmptyWhenAllZero() {
        let summary = UnscannableSummary(absent: 0, noAccess: 0, notSupported: 0, error: 0)
        let reasons = UnscannableText.reasonsPresent(in: summary)
        #expect(reasons.isEmpty)
    }
}

private func makeReport(summary: UnscannableSummary) throws -> ScanReport {
    let totals = try JSONDecoder().decode(TierTotals.self, from: Data(#"""
    {"green":{"count":0,"bytes":0},"yellow":{"count":0,"bytes":0},"red":{"count":0,"bytes":0},"blocked":{"count":0,"bytes":0}}
    """#.utf8))
    return ScanReport(
        findings: [],
        totals: totals,
        reclaimable: 0,
        freeBefore: 0,
        platform: "mac",
        scannedMs: 0,
        unscannable: [],
        unscannableSummary: summary
    )
}
