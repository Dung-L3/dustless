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
        #expect(parts.reasonLabels == ["the path is not on this machine"])
    }

    @Test func eachReasonCodeMapsToLocalizedLabel() throws {
        let summary = UnscannableSummary(absent: 1, noAccess: 2, notSupported: 3, error: 4)
        let report = try makeReport(summary: summary)

        let enParts = try #require(UnscannableText.bannerParts(report: report, lang: .en))
        #expect(enParts.reasonLabels == ["the path is not on this machine", "the app is not allowed to read it", "the tool it needs is not installed", "it failed, and the reason is given"])

        let viParts = try #require(UnscannableText.bannerParts(report: report, lang: .vi))
        #expect(viParts.reasonLabels == ["đường dẫn không có trên máy này", "ứng dụng không được phép đọc", "công cụ nó cần chưa được cài", "nó lỗi, lý do được ghi bên dưới"])

        let zhParts = try #require(UnscannableText.bannerParts(report: report, lang: .zh))
        #expect(zhParts.reasonLabels == ["该路径不在本机上", "应用无权读取它", "它需要的工具未安装", "它失败了，原因见下"])
    }

    @Test func mixedReasonsListEachLabelOnce() throws {
        let summary = UnscannableSummary(absent: 2, noAccess: 1, notSupported: 0, error: 1)
        let report = try makeReport(summary: summary)
        let parts = try #require(UnscannableText.bannerParts(report: report, lang: .en))
        #expect(parts.count == 4)
        #expect(parts.reasonLabels == ["the path is not on this machine", "the app is not allowed to read it", "it failed, and the reason is given"])
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

    @Test func redResolvesToLocalizedLabel() throws {
        let summary = UnscannableSummary(absent: 0, noAccess: 0, notSupported: 0, error: 0, red: 2)
        let report = try makeReport(summary: summary)
        let en = try #require(UnscannableText.bannerParts(report: report, lang: .en))
        #expect(en.reasonLabels == ["it is on the red list, so it will never be deleted"])
        let vi = try #require(UnscannableText.bannerParts(report: report, lang: .vi))
        #expect(vi.reasonLabels == ["nó nằm trong danh sách đỏ, sẽ không bao giờ bị xóa"])
        let zh = try #require(UnscannableText.bannerParts(report: report, lang: .zh))
        #expect(zh.reasonLabels == ["它在红名单中，永远不会被删除"])
    }

    @Test func protectedResolvesToLocalizedLabel() throws {
        let summary = UnscannableSummary(absent: 0, noAccess: 0, notSupported: 0, error: 0, red: 0, protected: 2)
        let report = try makeReport(summary: summary)
        let en = try #require(UnscannableText.bannerParts(report: report, lang: .en))
        #expect(en.reasonLabels == ["it is outside the range that may be deleted"])
        let vi = try #require(UnscannableText.bannerParts(report: report, lang: .vi))
        #expect(vi.reasonLabels == ["nó nằm ngoài phạm vi có thể xóa"])
        let zh = try #require(UnscannableText.bannerParts(report: report, lang: .zh))
        #expect(zh.reasonLabels == ["它在可删除范围之外"])
    }

    @Test func aReportCarryingTheProtectedReasonDecodes() throws {
        let json = Data(#"""
        {"absent":0,"no_access":0,"not_supported":0,"error":0,"red":0,"protected":1}
        """#.utf8)
        let summary = try JSONDecoder().decode(UnscannableSummary.self, from: json)
        #expect(summary.protected == 1)
        #expect(summary.total == 1)
        #expect(UnscannableText.reasonsPresent(in: summary) == [.protected])
        let reason = try JSONDecoder().decode(UnscannableReason.self, from: Data(#""protected""#.utf8))
        #expect(reason == .protected)
    }

    @Test func aReportWithoutTheProtectedCountStillDecodes() throws {
        let json = Data(#"""
        {"absent":1,"no_access":0,"not_supported":0,"error":0,"red":0}
        """#.utf8)
        let summary = try JSONDecoder().decode(UnscannableSummary.self, from: json)
        #expect(summary.protected == 0)
        #expect(summary.total == 1)
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
