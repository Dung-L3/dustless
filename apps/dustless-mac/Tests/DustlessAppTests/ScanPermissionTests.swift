import Testing
@testable import DustlessApp

@Suite("scan permission")
struct ScanPermissionTests {
    @Test @MainActor func dismissingARequiredNoticeOnlyClearsThatNotice() {
        let required = ScanStore(preview: ScanStore.Preview(scanPermission: .required))
        required.dismissPermissionNotice()
        #expect(required.scanPermission == .none)

        let waiting = ScanStore(preview: ScanStore.Preview(scanPermission: .waiting))
        waiting.dismissPermissionNotice()
        #expect(waiting.scanPermission == .waiting)
    }
}
