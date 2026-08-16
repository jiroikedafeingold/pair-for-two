// Protocol v1 conformance check for the iOS side.
//
// The app target has no unit-test bundle (creating one needs a manual Xcode action), so this
// is the protocol's test: a standalone Swift program compiled against the real model sources.
// Run it with tools/verify-protocol.sh.
//
// It asserts every rule in PROTOCOL.md, checks the legacy/v1 dual-format behaviour that lets
// old and new iOS builds interoperate, and regenerates fixtures/protocol-v1/*.json — the same
// bytes the Android :core module tests itself against.

import Foundation

func fail(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }

let snap = PlayerSnapshot(
    matchID: UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!,
    you: .one, phase: .pegging, yourSeat: .pone, dealer: .two,
    yourHand: [Card(rank: .five, suit: .clubs), Card(rank: .king, suit: .hearts)],
    opponentHandCount: 3,
    opponentHand: nil, crib: nil, cribCount: 4, cribOwners: nil,
    starter: Card(rank: .jack, suit: .spades), starterCutLifted: true,
    playSequence: [PlayedCard(card: Card(rank: .ace, suit: .diamonds), player: .two)],
    runningCount: 1, lapCardCount: 1, whoseTurn: .one, lastToPlay: .two,
    yourScore: 61, opponentScore: 58,
    flags: [ScoreFlag(.fifteen, points: 2, detail: "Fifteen 2"),
            ScoreFlag(.hisHeels, points: 2, detail: "His Heels")],
    scoringMode: .feedback,
    cutForDeal: [.one: Card(rank: .three, suit: .hearts), .two: Card(rank: .queen, suit: .clubs)],
    winner: nil, yourName: "Jiro", opponentName: "Sam", yourColorID: 2, opponentColorID: 7,
    playersWithClaims: [.two, .one],
    claimTick: 4, lastClaimPlayer: .two, lastClaimAmount: 3,
    pegEventTick: 2, lastPegEvent: PegEvent(kind: .thirtyOne, scorer: .one, points: 2),
    scoreLog: [Claim(player: .one, amount: 2, phase: .showPone)]
)

let messages: [GameMessage] = [
    .hello(name: "Jiro", colorID: 2, playerToken: UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!),
    .assignSeat(.two), .snapshot(snap),
    .intentCut(index: 17),
    .intentDiscard([Card(rank: .four, suit: .spades), Card(rank: .ten, suit: .hearts)]),
    .intentPlay(Card(rank: .seven, suit: .clubs)),
    .intentGo, .intentLiftCut(index: 9), .intentRevealStarter,
    .claimPoints(player: .one, amount: 6), .undo(player: .two),
    .advance, .playAgain,
    .updateIdentity(name: "Sam", colorID: 11), .setScoringMode(0), .quitGame,
]

// 1. v1 round-trip: re-encoding a decoded message must be byte-stable.
for m in messages {
    let d = try WireCodec.encode(m, as: .v1)
    guard let back = WireCodec.decode(d) else { fail("v1 decode returned nil for \(m)") }
    let again = try WireCodec.encode(back, as: .v1)
    let a = try JSONSerialization.jsonObject(with: d) as! [String: Any]
    let b = try JSONSerialization.jsonObject(with: again) as! [String: Any]
    guard NSDictionary(dictionary: a).isEqual(to: b) else {
        fail("v1 round-trip differs for \(m)\n  \(String(data: d, encoding: .utf8)!)\n  \(String(data: again, encoding: .utf8)!)")
    }
}
print("✓ v1 round-trip: \(messages.count) message types")

// 2. Legacy round-trip still works (old iOS builds must keep talking to new ones).
for m in messages {
    let d = try WireCodec.encode(m, as: .legacy)
    guard WireCodec.decode(d) != nil else { fail("legacy decode returned nil") }
    if WireCodec.isV1(d) { fail("legacy frame misdetected as v1: \(String(data: d, encoding: .utf8)!)") }
}
print("✓ legacy round-trip + not misdetected as v1")

// 3. Format sniffing and version announcement.
let helloV1 = try WireCodec.encode(messages[0], as: .v1)
let helloLegacy = try WireCodec.encode(messages[0], as: .legacy)
guard WireCodec.isV1(helloV1) else { fail("v1 hello not detected as v1") }
guard WireCodec.announcedVersion(helloV1) == 1 else { fail("v1 hello should announce protocol 1") }
guard WireCodec.announcedVersion(helloLegacy) == nil else { fail("legacy hello must announce nothing") }
guard WireCodec.announcedVersion(try WireCodec.encode(.advance, as: .v1)) == nil else { fail("non-hello announced a version") }
print("✓ format sniff + version handshake")

// 4. Snapshot fidelity — every field survives the trip.
guard case let .snapshot(rt)? = WireCodec.decode(try WireCodec.encode(.snapshot(snap), as: .v1)) else {
    fail("snapshot did not decode")
}
guard rt == snap else { fail("snapshot changed across round-trip") }
print("✓ snapshot equality across round-trip")

// 5. The specific encodings PROTOCOL.md pins.
let so = try JSONSerialization.jsonObject(with: try WireCodec.encode(.snapshot(snap), as: .v1)) as! [String: Any]
let s = so["snapshot"] as! [String: Any]
guard let cut = s["cutForDeal"] as? [String: Any], cut["one"] != nil, cut["two"] != nil else {
    fail("cutForDeal must be an object keyed by player")
}
guard s["playersWithClaims"] as? [String] == ["one", "two"] else { fail("playersWithClaims must be sorted") }
guard s["matchID"] as? String == "6ba7b810-9dad-11d1-80b4-00c04fd430c8" else { fail("UUID must be lowercase") }
guard s["opponentHand"] == nil, s["crib"] == nil, s["winner"] == nil else { fail("absent optionals must be omitted") }
guard s["scoringMode"] as? Int == 1 else { fail("scoringMode must be its Int raw value") }
guard let c = (s["yourHand"] as? [[String: Any]])?.first,
      c["rank"] as? Int == 5, c["suit"] as? String == "clubs" else { fail("card encoding wrong") }
print("✓ PROTOCOL.md encoding rules")

// 5b. The crib's ownership map: an array of {card, player} in display order, present only with the
// revealed crib (a Card can't be a JSON object key, so it is not a Map like cutForDeal).
let cribCards = [Card(rank: .ten, suit: .hearts), Card(rank: .four, suit: .spades)]
let cribSnap = PlayerSnapshot(
    matchID: snap.matchID, you: .one, phase: .showCrib, yourSeat: .pone, dealer: .two,
    yourHand: snap.yourHand, opponentHandCount: 4, opponentHand: snap.yourHand,
    crib: cribCards, cribCount: cribCards.count,
    cribOwners: [cribCards[0]: .one, cribCards[1]: .two],
    starter: snap.starter, starterCutLifted: true,
    playSequence: snap.playSequence, runningCount: 0, lapCardCount: 0,
    whoseTurn: nil, lastToPlay: .two, yourScore: 61, opponentScore: 58,
    flags: [], scoringMode: .feedback, cutForDeal: snap.cutForDeal, winner: nil,
    yourName: "Jiro", opponentName: "Sam", yourColorID: 2, opponentColorID: 7,
    playersWithClaims: [.one, .two], claimTick: 4, lastClaimPlayer: .two, lastClaimAmount: 3,
    pegEventTick: 3, lastPegEvent: PegEvent(kind: .lastCard, scorer: .two, points: 1),
    scoreLog: []
)
guard case let .snapshot(cribRT)? = WireCodec.decode(try WireCodec.encode(.snapshot(cribSnap), as: .v1)),
      cribRT == cribSnap else { fail("crib snapshot changed across round-trip") }
let cs = (try JSONSerialization.jsonObject(with: try WireCodec.encode(.snapshot(cribSnap), as: .v1))
          as! [String: Any])["snapshot"] as! [String: Any]
guard let owners = cs["cribOwners"] as? [[String: Any]], owners.count == 2,
      (owners[0]["card"] as? [String: Any])?["rank"] as? Int == 4, owners[0]["player"] as? String == "two",
      (owners[1]["card"] as? [String: Any])?["rank"] as? Int == 10, owners[1]["player"] as? String == "one"
else { fail("cribOwners must be [{card,player}] sorted by display order") }
guard (cs["lastPegEvent"] as? [String: Any])?["kind"] as? String == "lastCard" else {
    fail("PegEvent kind lastCard must encode by name")
}
print("✓ cribOwners + lastCard peg event")

// 6. Robustness: junk and unknown tags must not crash or misdecode.
guard WireCodec.decode(Data("not json".utf8)) == nil else { fail("junk decoded") }
guard WireCodec.decode(Data(#"{"t":"someFutureMessage","x":1}"#.utf8)) == nil else { fail("unknown tag decoded") }
print("✓ junk and unknown-tag frames rejected cleanly")


// 7. Negotiator: pessimistic until the peer announces v1.
let n = WireCodec.Negotiator()
guard case .legacy = n.format else { fail("negotiator must start at legacy") }
n.observe(try WireCodec.encode(.advance, as: .v1))          // non-hello must not upgrade
guard case .legacy = n.format else { fail("non-hello upgraded the format") }
n.observe(helloLegacy)                                       // legacy hello must not upgrade
guard case .legacy = n.format else { fail("legacy hello upgraded the format") }
n.observe(helloV1)
guard case .v1 = n.format else { fail("v1 hello should have upgraded the format") }
n.reset()
guard case .legacy = n.format else { fail("reset should return to legacy") }
print("✓ negotiator upgrades only on a v1 hello")

// 8. Emit golden fixtures for the Android side to verify against.
let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./fixtures")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
func name(_ m: GameMessage) -> String {
    let o = try! JSONSerialization.jsonObject(with: try! WireCodec.encode(m, as: .v1)) as! [String: Any]
    return o["t"] as! String
}
for m in messages {
    let obj = try JSONSerialization.jsonObject(with: try WireCodec.encode(m, as: .v1))
    let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try pretty.write(to: dir.appendingPathComponent("\(name(m)).json"))
}
print("✓ wrote \(messages.count) golden fixtures to \(dir.path)")

print("\nALL CHECKS PASSED")
