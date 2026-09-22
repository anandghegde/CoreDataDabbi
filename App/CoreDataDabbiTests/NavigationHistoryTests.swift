import Testing

@testable import CoreDataDabbi

@MainActor
@Suite struct NavigationHistoryTests {
    @Test func goesBackAndForward() {
        let history = NavigationHistory()
        history.show(BrowseLocation(entity: "A"))
        history.show(BrowseLocation(entity: "B"))
        history.show(BrowseLocation(entity: "C"))
        #expect(history.canGoBack && !history.canGoForward)

        history.goBack()
        #expect(history.current?.entity == "B")
        history.goBack()
        #expect(history.current?.entity == "A")
        #expect(!history.canGoBack)

        history.goForward()
        #expect(history.current?.entity == "B")
        #expect(history.canGoForward)
    }

    @Test func showingSomethingNewForgetsWhatWasAhead() {
        let history = NavigationHistory()
        history.show(BrowseLocation(entity: "A"))
        history.show(BrowseLocation(entity: "B"))
        history.goBack()
        history.show(BrowseLocation(entity: "C"))
        #expect(!history.canGoForward)
        #expect(history.behind.map(\.entity) == ["A"])
    }

    @Test func showingTheSamePlaceTwiceIsOnePlace() {
        let history = NavigationHistory()
        history.show(BrowseLocation(entity: "A"))
        history.show(BrowseLocation(entity: "A"))
        #expect(!history.canGoBack)
    }

    @Test func amendingChangesThePlaceWithoutLeavingIt() {
        let history = NavigationHistory()
        history.show(BrowseLocation(entity: "A"))
        history.amend { $0.trail = ["Employee#1"] }
        #expect(history.current?.trail == ["Employee#1"])
        #expect(!history.canGoBack)
    }

    @Test func forgetsTheOldestPlaces() {
        let history = NavigationHistory()
        for index in 0...(NavigationHistory.limit + 10) { history.show(BrowseLocation(entity: "E\(index)")) }
        #expect(history.behind.count == NavigationHistory.limit)
        #expect(history.behind.first?.entity == "E10")
    }

    @Test func resettingStartsOver() {
        let history = NavigationHistory()
        history.show(BrowseLocation(entity: "A"))
        history.show(BrowseLocation(entity: "B"))
        history.reset(to: BrowseLocation(entity: "Z"))
        #expect(history.current?.entity == "Z")
        #expect(!history.canGoBack && !history.canGoForward)
    }
}
