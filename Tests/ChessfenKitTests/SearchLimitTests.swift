@testable import ChessfenKit
import Testing

/// Contract: the 搜索预算 is time, depth and which end stops the search; every live search reads
/// the one the app set; a 复判 goes past it by a fixed rule; and it survives the store as one
/// line (CONTEXT.md, docs/adr/0039, docs/adr/0041).
@Suite struct SearchLimitTests {
    @Test("the standard budget is ten seconds or depth twenty, and 复判 is depth 28 within a minute")
    func theStandardBudget() {
        let standard = SearchLimit.standard
        #expect(standard.budget == .timeOrDepth(.seconds(10), 20))
        #expect(standard.deeper.budget == .timeOrDepth(.seconds(60), 28))
        #expect(standard.deeper.depth == 28)
        #expect(PositionSearches.limit == standard, "the kit runs on it until the app says otherwise")
        #expect(PositionSearches.budget == standard.budget)
        #expect(PositionSearches.deeper == standard.deeper.budget)
        #expect(PositionSearches.deeperDepth == 28)
        #expect(PositionSearches.depth == 20)
    }

    @Test("either end alone is a budget of that end alone, and 复判 keeps the same rule")
    func oneEndAlone() {
        let byTime = SearchLimit(seconds: 5, depth: 12, stop: .time)
        #expect(byTime.budget == .time(.seconds(5)))
        #expect(byTime.deeper.budget == .time(.seconds(30)))
        let byDepth = SearchLimit(seconds: 5, depth: 12, stop: .depth)
        #expect(byDepth.budget == .depth(12))
        #expect(byDepth.deeper.budget == .depth(20))
        #expect(SearchLimit(seconds: 5, depth: 12).budget == .timeOrDepth(.seconds(5), 12))
    }

    @Test("it is said as the ends that count")
    func theLabel() {
        Speech.speaking(.chinese) {
            #expect(SearchLimit.standard.label == "10 秒 / 20 层")
            #expect(SearchLimit(seconds: 5, depth: 12, stop: .time).label == "5 秒")
            #expect(SearchLimit(seconds: 5, depth: 12, stop: .depth).label == "12 层")
        }
        Speech.speaking(.english) {
            #expect(SearchLimit.standard.label == "10 s / depth 20")
            #expect(SearchLimit(seconds: 30, depth: 24, stop: .depth).label == "depth 24")
        }
    }

    @Test("one line for the stores, and back")
    func theText() {
        let chosen = SearchLimit(seconds: 15, depth: 22, stop: .depth)
        #expect(chosen.text == "15 22 depth")
        #expect(SearchLimit(text: chosen.text) == chosen)
        #expect(SearchLimit(text: SearchLimit.standard.text) == .standard)
        #expect(SearchLimit(text: "0 20 either") == nil)
        #expect(SearchLimit(text: "10 20 whenever") == nil)
        #expect(SearchLimit(text: "10 20") == nil)
        #expect(SearchLimit(text: "") == nil)
    }
}
