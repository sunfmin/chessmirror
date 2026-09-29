@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: a 门 is only how the text is got (`FetchPlan`), and one plan per door. The pipeline
/// behind them is the same; what used to vary was a `switch` over site names in three places.
/// A door's failures name themselves (docs/adr/0014).
@Suite struct DoorwayTests {
    // ------------------------------------------------------------------ the plans

    /// A 国象联盟 share link is recognised in one place, and its plan carries the game: nothing
    /// is fetched.
    @Test func aShareLinkCarriesItsGameAndAsksForNothing() throws {
        #expect(ImportDoors.Door.recognising(chesseaseShareLink) == .chessease)
        let plan = try #require(
            try PGNImport.Site.chessease.fetchPlan(for: chesseaseShareLink, count: 10).get()
        )
        guard case .carried(let pgn) = plan else {
            Issue.record("a share link's plan carries the game, got \(plan)")
            return
        }
        #expect(pgn.contains("[White"), "and it is the game itself")
    }

    /// The plain link door takes any link — including a 国象联盟 share link, which is a link
    /// that carries its game with it. One sniff, not two.
    @Test func theLinkDoorHandsAShareLinkToTheSameSniff() throws {
        let plan = try #require(
            try ImportDoors.Door.link.fetchPlan(for: chesseaseShareLink, count: 10).get()
        )
        guard case .carried = plan else {
            Issue.record("the link door routes a share link through the one sniff, got \(plan)")
            return
        }
    }

    /// A lichess username is one download; a lichess link is a candidate list; the wrong kind
    /// of thing typed into the wrong field is the door's failure to name.
    @Test func lichessSaysWhatItNeedsFromWhatWasTyped() throws {
        let recent = try #require(try PGNImport.Site.lichess.fetchPlan(for: "sunfmin", count: 10).get())
        guard case .recentLichess(let url) = recent else {
            Issue.record("a username is a recent-games download, got \(recent)")
            return
        }
        #expect(url.absoluteString.contains("sunfmin"))

        let link = try #require(
            try PGNImport.Site.lichess.fetchPlan(for: "https://lichess.org/abc123", count: 10).get()
        )
        guard case .links = link else {
            Issue.record("a link is a candidate list, got \(link)")
            return
        }

        #expect(
            PGNImport.Site.lichess.fetchPlan(for: "not a name!!", count: 10)
                == .failure(.notAPlayer(.lichess))
        )
    }

    /// chess.com hands games over a month at a time, so its plan is the archives list plus how
    /// many games are wanted — not a URL to one download.
    @Test func chessComSaysItWalksMonthsBack() throws {
        let plan = try #require(try PGNImport.Site.chessCom.fetchPlan(for: "sunfmin", count: 10).get())
        guard case .recentChessCom(let archives, let many, _) = plan else {
            Issue.record("chess.com is a month walk, got \(plan)")
            return
        }
        #expect(archives.absoluteString.contains("sunfmin"))
        #expect(many == 10)
    }

    // ------------------------------------------------------------------ the failures name themselves

    /// A chess.com archives list that will not parse is the site handing back something we
    /// cannot read as a list of games — not "what came down is not a PGN", which is what this
    /// used to say and what the player had no way to act on.
    @Test func anArchivesListThatWillNotParseSaysSo() async throws {
        let archives = try #require(PGNImport.chessComArchivesURL(user: "sunfmin"))
        let fetcher = ScriptedFetcher([archives.absoluteString: .success("not json at all")])
        do {
            _ = try await FetchPlan.recentChessCom(archives: archives, many: 10)
                .text(fetching: fetcher, asked: "sunfmin")
            Issue.record("a list that will not parse should refuse")
        } catch let failure as PGNImport.Error {
            #expect(failure == .unreadableArchives(.chessCom, "sunfmin"))
            #expect(failure.isAboutInput, "and the sheet marks the field for it")
        }
    }

    /// An empty archives list is 「这里没有对局」 and not a parse failure — two different
    /// silences, told apart at the door.
    @Test func anEmptyArchivesListSaysThereAreNoGames() async throws {
        let archives = try #require(PGNImport.chessComArchivesURL(user: "sunfmin"))
        let list = #"{"archives":[]}"#
        let fetcher = ScriptedFetcher([archives.absoluteString: .success(list)])
        do {
            _ = try await FetchPlan.recentChessCom(archives: archives, many: 10)
                .text(fetching: fetcher, asked: "sunfmin")
            Issue.record("an empty list is not a plan")
        } catch let failure as PGNImport.Error {
            #expect(failure == .noGames(.chessCom, "sunfmin"))
        }
    }

    /// A link that downloads nothing PGN-shaped is 「不是 PGN」; one that downloads a block that
    /// will not parse is 「读不出局」. Two different silences, told apart once — this used to be
    /// decided twice over the same text before `read` ran the cut a third time.
    @Test func aLinkWithNothingInItAndALinkWithNoReadableGamesAreToldApart() async throws {
        let candidates = try #require(PGNImport.candidateURLs(for: "https://example.com/g"))
        let url = try #require(candidates.first)

        do {
            _ = try await FetchPlan.links(candidates)
                .text(fetching: ScriptedFetcher([url.absoluteString: .success("")]), asked: nil)
            Issue.record("nothing came down at all")
        } catch let failure as PGNImport.Error {
            #expect(failure == .notPGN, "no blocks at all is not a game record")
        }

        do {
            _ = try await FetchPlan.links(candidates)
                .text(
                    fetching: ScriptedFetcher([url.absoluteString: .success("<html></html>")]),
                    asked: nil
                )
            Issue.record("an HTML page is not readable as a game")
        } catch let failure as PGNImport.Error {
            #expect(failure == .noReadableGames, "a block that will not parse is the other silence")
        }
    }
}
