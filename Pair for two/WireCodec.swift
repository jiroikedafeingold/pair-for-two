import Foundation

/// Encoding and decoding of `GameMessage` for the wire.
///
/// **Why this exists.** The models' derived `Codable` is not usable as a cross-platform
/// contract: Swift encodes `[PlayerID: Int]` as a flat, *unordered* `["two",5,"one",3]`
/// array (because `PlayerID` isn't `CodingKeyRepresentable`), and encodes enums with
/// associated values externally-tagged as `{"hello":{…}}`. kotlinx.serialization on Android
/// produces neither. `PROTOCOL.md` pins an explicit format; this file implements it.
///
/// **Why a separate DTO layer rather than `CodingKeys` on the models.** Keeping the mapping
/// here means renaming a property on `PlayerSnapshot` can't silently change the bytes a
/// shipped client depends on — it breaks this file's compilation instead.
///
/// Note `GameState` is deliberately untouched: it never crosses the wire (only the redacted
/// `PlayerSnapshot` does) and its derived `Codable` is the on-disk save format in
/// `Persistence.swift`. Changing it would invalidate saved games.
nonisolated enum WireCodec {

    /// Protocol version announced in `hello` and required of peers.
    static let version = 1

    /// Which encoding to use when writing. See `PROTOCOL.md` → Legacy format.
    enum Format: Sendable {
        /// Pre-v1 derived `Codable`. Only spoken to older iOS builds.
        case legacy
        /// Explicit cross-platform protocol v1.
        case v1
    }

    // MARK: Encoding

    static func encode(_ message: GameMessage, as format: Format) throws -> Data {
        switch format {
        case .legacy: return try JSONEncoder().encode(message)
        case .v1:     return try JSONSerialization.data(withJSONObject: v1Object(message))
        }
    }

    // MARK: Decoding

    /// Decodes either format, choosing by shape rather than by expectation — a peer can send
    /// legacy and v1 in the same session (its `hello` is legacy, later frames v1).
    static func decode(_ data: Data) -> GameMessage? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tag = object["t"] as? String {
            return v1Message(tag: tag, object)
        }
        return try? JSONDecoder().decode(GameMessage.self, from: data)
    }

    /// Whether `data` is a protocol-v1 frame. A root-level `"t"` is the discriminator; the
    /// legacy format never has one (its root key is the case name).
    static func isV1(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["t"] is String
    }

    /// The `protocol` a peer announced in its `hello`, if any. Absent means a legacy peer.
    static func announcedVersion(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["t"] as? String == "hello" else { return nil }
        return object["protocol"] as? Int
    }

    // MARK: - Format negotiation

    /// Tracks which format the peer understands, so we never send v1 to a build that predates it.
    ///
    /// Starts pessimistic at `.legacy` and upgrades to `.v1` the moment the peer's `hello`
    /// announces `"protocol": 1`. A legacy peer never sends that field, so it keeps receiving
    /// exactly the bytes it does today; Android always announces, so it gets v1 from our first
    /// reply onward.
    ///
    /// Lock-guarded because `GameCenterTransport.send(_:)` is `nonisolated` and callable from
    /// any thread, while the GameKit/Multipeer delegate callbacks that observe `hello` arrive on
    /// their own queues.
    nonisolated final class Negotiator: Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var _format: Format = .legacy

        var format: Format {
            lock.lock(); defer { lock.unlock() }
            return _format
        }

        /// Inspect an inbound frame; upgrade to v1 once the peer announces it.
        func observe(_ data: Data) {
            guard let announced = WireCodec.announcedVersion(data), announced >= 1 else { return }
            lock.lock(); _format = .v1; lock.unlock()
        }

        /// Drop back to the pessimistic default — used when a transport rebuilds its session and
        /// may be talking to a different peer.
        func reset() {
            lock.lock(); _format = .legacy; lock.unlock()
        }
    }

    // MARK: - v1 message → JSON

    private static func v1Object(_ message: GameMessage) -> [String: Any] {
        switch message {
        case let .hello(name, colorID, playerToken):
            return ["t": "hello", "protocol": version, "name": name, "colorID": colorID,
                    "playerToken": uuid(playerToken)]
        case let .assignSeat(player):
            return ["t": "assignSeat", "player": player.rawValue]
        case let .snapshot(snapshot):
            return ["t": "snapshot", "snapshot": snapshotObject(snapshot)]
        case let .intentCut(index):
            return ["t": "intentCut", "index": index]
        case let .intentDiscard(cards):
            return ["t": "intentDiscard", "cards": cards.map(cardObject)]
        case let .intentPlay(card):
            return ["t": "intentPlay", "card": cardObject(card)]
        case .intentGo:
            return ["t": "intentGo"]
        case let .intentLiftCut(index):
            return ["t": "intentLiftCut", "index": index]
        case .intentRevealStarter:
            return ["t": "intentRevealStarter"]
        case let .claimPoints(player, amount):
            return ["t": "claimPoints", "player": player.rawValue, "amount": amount]
        case let .undo(player):
            return ["t": "undo", "player": player.rawValue]
        case .advance:
            return ["t": "advance"]
        case .playAgain:
            return ["t": "playAgain"]
        case let .updateIdentity(name, colorID):
            return ["t": "updateIdentity", "name": name, "colorID": colorID]
        case let .setScoringMode(mode):
            return ["t": "setScoringMode", "mode": mode]
        case .quitGame:
            return ["t": "quitGame"]
        }
    }

    // MARK: - JSON → v1 message

    private static func v1Message(tag: String, _ o: [String: Any]) -> GameMessage? {
        switch tag {
        case "hello":
            guard let name = o["name"] as? String,
                  let colorID = o["colorID"] as? Int,
                  let token = (o["playerToken"] as? String).flatMap(UUID.init(uuidString:))
            else { return nil }
            return .hello(name: name, colorID: colorID, playerToken: token)
        case "assignSeat":
            guard let p = player(o["player"]) else { return nil }
            return .assignSeat(p)
        case "snapshot":
            guard let s = o["snapshot"] as? [String: Any], let snap = snapshot(s) else { return nil }
            return .snapshot(snap)
        case "intentCut":
            guard let i = o["index"] as? Int else { return nil }
            return .intentCut(index: i)
        case "intentDiscard":
            guard let raw = o["cards"] as? [[String: Any]] else { return nil }
            let cards = raw.compactMap(card)
            guard cards.count == raw.count else { return nil }
            return .intentDiscard(cards)
        case "intentPlay":
            guard let c = (o["card"] as? [String: Any]).flatMap(card) else { return nil }
            return .intentPlay(c)
        case "intentGo":
            return .intentGo
        case "intentLiftCut":
            guard let i = o["index"] as? Int else { return nil }
            return .intentLiftCut(index: i)
        case "intentRevealStarter":
            return .intentRevealStarter
        case "claimPoints":
            guard let p = player(o["player"]), let amount = o["amount"] as? Int else { return nil }
            return .claimPoints(player: p, amount: amount)
        case "undo":
            guard let p = player(o["player"]) else { return nil }
            return .undo(player: p)
        case "advance":
            return .advance
        case "playAgain":
            return .playAgain
        case "updateIdentity":
            guard let name = o["name"] as? String, let colorID = o["colorID"] as? Int else { return nil }
            return .updateIdentity(name: name, colorID: colorID)
        case "setScoringMode":
            guard let mode = o["mode"] as? Int else { return nil }
            return .setScoringMode(mode)
        case "quitGame":
            return .quitGame
        default:
            return nil   // unknown message from a newer peer — ignore rather than crash
        }
    }

    // MARK: - Leaf encoders

    /// Lowercase canonical UUID. `UUID.uuidString` is uppercase; the protocol says lowercase.
    private static func uuid(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func cardObject(_ c: Card) -> [String: Any] {
        ["rank": c.rank.rawValue, "suit": c.suit.rawValue]
    }

    private static func card(_ o: [String: Any]) -> Card? {
        guard let r = o["rank"] as? Int, let rank = Rank(rawValue: r),
              let s = o["suit"] as? String, let suit = Suit(rawValue: s) else { return nil }
        return Card(rank: rank, suit: suit)
    }

    private static func player(_ any: Any?) -> PlayerID? {
        (any as? String).flatMap(PlayerID.init(rawValue:))
    }

    /// `[PlayerID: T]` as a JSON object keyed by raw value — not Swift's flat array.
    private static func playerMap<T>(_ dict: [PlayerID: T], _ transform: (T) -> Any) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict { out[k.rawValue] = transform(v) }
        return out
    }

    /// Sorted so the bytes don't depend on `Set` iteration order.
    private static func playerSet(_ set: Set<PlayerID>) -> [String] {
        PlayerID.allCases.filter(set.contains).map(\.rawValue)
    }

    private static func flagObject(_ f: ScoreFlag) -> [String: Any] {
        ["kind": f.kind.rawValue, "points": f.points, "detail": f.detail]
    }

    private static func flag(_ o: [String: Any]) -> ScoreFlag? {
        guard let k = o["kind"] as? String, let kind = ScoreFlag.Kind(rawValue: k),
              let points = o["points"] as? Int, let detail = o["detail"] as? String else { return nil }
        return ScoreFlag(kind, points: points, detail: detail)
    }

    private static func playedObject(_ p: PlayedCard) -> [String: Any] {
        ["card": cardObject(p.card), "player": p.player.rawValue]
    }

    private static func played(_ o: [String: Any]) -> PlayedCard? {
        guard let c = (o["card"] as? [String: Any]).flatMap(card),
              let p = player(o["player"]) else { return nil }
        return PlayedCard(card: c, player: p)
    }

    /// `[Card: PlayerID]` as an array of `{card, player}` — a `Card` can't be a JSON object key.
    /// Sorted by the display order so the bytes don't depend on dictionary iteration order.
    private static func cardOwners(_ dict: [Card: PlayerID]) -> [[String: Any]] {
        dict.sorted { $0.key.displaySortKey < $1.key.displaySortKey }
            .map { ["card": cardObject($0.key), "player": $0.value.rawValue] }
    }

    private static func cardOwnerMap(_ raw: [[String: Any]]) -> [Card: PlayerID] {
        var out: [Card: PlayerID] = [:]
        for entry in raw {
            guard let c = (entry["card"] as? [String: Any]).flatMap(card),
                  let p = player(entry["player"]) else { continue }
            out[c] = p
        }
        return out
    }

    private static func claimObject(_ c: Claim) -> [String: Any] {
        ["player": c.player.rawValue, "amount": c.amount, "phase": c.phase.rawValue]
    }

    private static func claim(_ o: [String: Any]) -> Claim? {
        guard let p = player(o["player"]), let amount = o["amount"] as? Int,
              let ph = o["phase"] as? String, let phase = GamePhase(rawValue: ph) else { return nil }
        return Claim(player: p, amount: amount, phase: phase)
    }

    private static func pegObject(_ e: PegEvent) -> [String: Any] {
        ["kind": e.kind.rawValue, "scorer": e.scorer.rawValue, "points": e.points]
    }

    private static func peg(_ o: [String: Any]) -> PegEvent? {
        guard let k = o["kind"] as? String, let kind = PegEvent.Kind(rawValue: k),
              let scorer = player(o["scorer"]), let points = o["points"] as? Int else { return nil }
        return PegEvent(kind: kind, scorer: scorer, points: points)
    }

    // MARK: - Snapshot

    private static func snapshotObject(_ s: PlayerSnapshot) -> [String: Any] {
        // Required keys.
        var o: [String: Any] = [
            "matchID": uuid(s.matchID),
            "you": s.you.rawValue,
            "phase": s.phase.rawValue,
            "yourSeat": s.yourSeat.rawValue,
            "dealer": s.dealer.rawValue,
            "yourHand": s.yourHand.map(cardObject),
            "opponentHandCount": s.opponentHandCount,
            "cribCount": s.cribCount,
            "starterCutLifted": s.starterCutLifted,
            "playSequence": s.playSequence.map(playedObject),
            "runningCount": s.runningCount,
            "lapCardCount": s.lapCardCount,
            "yourScore": s.yourScore,
            "opponentScore": s.opponentScore,
            "flags": s.flags.map(flagObject),
            "scoringMode": s.scoringMode.rawValue,
            "cutForDeal": playerMap(s.cutForDeal, cardObject),
            "yourName": s.yourName,
            "opponentName": s.opponentName,
            "yourColorID": s.yourColorID,
            "opponentColorID": s.opponentColorID,
            "playersWithClaims": playerSet(s.playersWithClaims),
            "claimTick": s.claimTick,
            "lastClaimAmount": s.lastClaimAmount,
            "pegEventTick": s.pegEventTick,
            "scoreLog": s.scoreLog.map(claimObject),
        ]
        // Optionals: omit the key entirely rather than emitting null.
        if let v = s.opponentHand   { o["opponentHand"] = v.map(cardObject) }
        if let v = s.crib           { o["crib"] = v.map(cardObject) }
        if let v = s.cribOwners     { o["cribOwners"] = cardOwners(v) }
        if let v = s.starter        { o["starter"] = cardObject(v) }
        if let v = s.whoseTurn      { o["whoseTurn"] = v.rawValue }
        if let v = s.lastToPlay     { o["lastToPlay"] = v.rawValue }
        if let v = s.winner         { o["winner"] = v.rawValue }
        if let v = s.lastClaimPlayer { o["lastClaimPlayer"] = v.rawValue }
        if let v = s.lastPegEvent   { o["lastPegEvent"] = pegObject(v) }
        return o
    }

    private static func snapshot(_ o: [String: Any]) -> PlayerSnapshot? {
        guard let matchID = (o["matchID"] as? String).flatMap(UUID.init(uuidString:)),
              let you = player(o["you"]),
              let ph = o["phase"] as? String, let phase = GamePhase(rawValue: ph),
              let st = o["yourSeat"] as? String, let yourSeat = Seat(rawValue: st),
              let dealer = player(o["dealer"]),
              let yourHandRaw = o["yourHand"] as? [[String: Any]],
              let opponentHandCount = o["opponentHandCount"] as? Int,
              let cribCount = o["cribCount"] as? Int,
              let starterCutLifted = o["starterCutLifted"] as? Bool,
              let playRaw = o["playSequence"] as? [[String: Any]],
              let runningCount = o["runningCount"] as? Int,
              let lapCardCount = o["lapCardCount"] as? Int,
              let yourScore = o["yourScore"] as? Int,
              let opponentScore = o["opponentScore"] as? Int,
              let flagsRaw = o["flags"] as? [[String: Any]],
              let modeRaw = o["scoringMode"] as? Int,
              let cutRaw = o["cutForDeal"] as? [String: [String: Any]],
              let yourName = o["yourName"] as? String,
              let opponentName = o["opponentName"] as? String,
              let yourColorID = o["yourColorID"] as? Int,
              let opponentColorID = o["opponentColorID"] as? Int,
              let claimsRaw = o["playersWithClaims"] as? [String],
              let claimTick = o["claimTick"] as? Int,
              let lastClaimAmount = o["lastClaimAmount"] as? Int,
              let pegEventTick = o["pegEventTick"] as? Int
        else { return nil }

        var cutForDeal: [PlayerID: Card] = [:]
        for (k, v) in cutRaw {
            guard let p = PlayerID(rawValue: k), let c = card(v) else { return nil }
            cutForDeal[p] = c
        }

        return PlayerSnapshot(
            matchID: matchID,
            you: you,
            phase: phase,
            yourSeat: yourSeat,
            dealer: dealer,
            yourHand: yourHandRaw.compactMap(card),
            opponentHandCount: opponentHandCount,
            opponentHand: (o["opponentHand"] as? [[String: Any]])?.compactMap(card),
            crib: (o["crib"] as? [[String: Any]])?.compactMap(card),
            cribCount: cribCount,
            cribOwners: (o["cribOwners"] as? [[String: Any]]).map(cardOwnerMap),
            starter: (o["starter"] as? [String: Any]).flatMap(card),
            starterCutLifted: starterCutLifted,
            playSequence: playRaw.compactMap(played),
            runningCount: runningCount,
            lapCardCount: lapCardCount,
            whoseTurn: player(o["whoseTurn"]),
            lastToPlay: player(o["lastToPlay"]),
            yourScore: yourScore,
            opponentScore: opponentScore,
            flags: flagsRaw.compactMap(flag),
            scoringMode: ScoringMode(rawValue: modeRaw) ?? .off,
            cutForDeal: cutForDeal,
            winner: player(o["winner"]),
            yourName: yourName,
            opponentName: opponentName,
            yourColorID: yourColorID,
            opponentColorID: opponentColorID,
            playersWithClaims: Set(claimsRaw.compactMap(PlayerID.init(rawValue:))),
            claimTick: claimTick,
            lastClaimPlayer: player(o["lastClaimPlayer"]),
            lastClaimAmount: lastClaimAmount,
            pegEventTick: pegEventTick,
            lastPegEvent: (o["lastPegEvent"] as? [String: Any]).flatMap(peg),
            scoreLog: (o["scoreLog"] as? [[String: Any]])?.compactMap(claim) ?? []
        )
    }
}
