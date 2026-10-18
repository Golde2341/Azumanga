import Testing

@Suite("Smoke")
struct SmokeTests {
    @Test("Test target is wired up")
    func testTargetRuns() {
        #expect(Bool(true))
    }
}
