# Pair for two — wire protocol v1

**This file must be byte-identical in both repos:**
`~/Projects/Pair for two/PROTOCOL.md` and `~/Projects/PairForTwoAndroid/PROTOCOL.md`.

It is the contract between the iOS app (Swift) and the Android app (Kotlin). It is owned by
neither language's serialization defaults — see [Why explicit](#why-explicit).

---

## Why explicit

Swift's derived `Codable` and kotlinx.serialization disagree on three things that appear
throughout this app's messages:

| | Swift derived `Codable` | kotlinx.serialization default |
| --- | --- | --- |
| `[PlayerID: Int]` | `["two",5,"one",3]` — a **flat, unordered array** | `{"one":3,"two":5}` — an object |
| enum with associated values | `{"hello":{…}}` — externally tagged | `{"type":"hello",…}` — internally tagged, key `type` |
| `UUID` | `"6BA7B810-…"` — uppercase | n/a |

The Swift behaviour for dictionaries is because `PlayerID` does not conform to
`CodingKeyRepresentable`; the ordering follows `Dictionary` iteration order and is **not
stable between runs**. None of it is suitable as a cross-platform contract, so v1 pins the
format below and both sides implement it deliberately.

---

## Transport framing

**Newline-delimited JSON over a TCP stream.** One message per line, terminated by `\n`
(0x0A). Encoded JSON never contains a raw newline, so the framing is unambiguous, is
debuggable with `nc`, and avoids a length-prefix endianness question.

- Encoding is UTF-8, no BOM.
- Readers must tolerate `\r\n` and ignore blank lines.
- Readers must ignore unknown object keys (forward compatibility).
- A line that fails to parse is dropped, not fatal — a corrupt frame must not kill the session.

Over MultipeerConnectivity and Game Center each message is already a discrete datagram, so
no framing is added there; the JSON body is identical.

---

## Handshake and versioning

The first message each side sends is `hello`, carrying `"protocol": 1`.

- A peer that sends **no** `protocol` field is speaking the **legacy** iOS format
  (see [Legacy](#legacy-format-ios-only)).
- A peer whose `protocol` is greater than this build supports → show "update one of your
  apps" and refuse the match, rather than failing to decode later at a random moment.

---

## Encoding rules

| Type | Wire form |
| --- | --- |
| `PlayerID` | `"one"` \| `"two"` |
| `Seat` | `"dealer"` \| `"pone"` |
| `GamePhase` | `"connecting"`, `"cutForDeal"`, `"dealing"`, `"discardToCrib"`, `"cutStarter"`, `"pegging"`, `"showPone"`, `"showDealer"`, `"showCrib"`, `"handComplete"`, `"gameOver"` |
| `ScoringMode` | Int: `0` auto, `1` feedback, `2` off |
| `Rank` | Int `1`…`13` (Ace = 1, King = 13) |
| `Suit` | `"spades"` \| `"hearts"` \| `"diamonds"` \| `"clubs"` |
| `Card` | `{"rank":1,"suit":"spades"}` |
| `Map<PlayerID, T>` | JSON **object** keyed by the player's wire name: `{"one":0,"two":0}` |
| `Set<PlayerID>` | JSON array, **sorted** `one` before `two`: `["one","two"]` |
| `UUID` | **Lowercase** canonical string, e.g. `"6ba7b810-9dad-11d1-80b4-00c04fd430c8"` |
| Absent optional | **Omit the key.** Never emit `null`. |
| `ScoreFlag.Kind` | `"fifteen"`, `"pair"`, `"run"`, `"flush"`, `"nobs"`, `"hisHeels"`, `"thirtyOne"`, `"go"`, `"lastCard"` |
| `PegEvent.Kind` | `"go"` \| `"thirtyOne"` \| `"lastCard"` |
| `Map<Card, PlayerID>` | JSON **array** of `{"card":Card,"player":PlayerID}` — a `Card` can't be an object key — **sorted** by rank then suit (spades, hearts, diamonds, clubs) |

Arrays preserve order; `playSequence` order is meaningful.

---

## Envelope

Every message is a JSON object with a `"t"` discriminator:

```json
{"t":"intentPlay","card":{"rank":1,"suit":"spades"}}
```

`t` must be the message's own key; there is no nesting under a case name.

---

## Messages

### Handshake / lifecycle

| `t` | Fields | Direction |
| --- | --- | --- |
| `hello` | `protocol` Int, `name` String, `colorID` Int, `playerToken` UUID | both |
| `assignSeat` | `player` PlayerID | host → guest |
| `snapshot` | `snapshot` [PlayerSnapshot](#playersnapshot) | host → guest |

```json
{"t":"hello","protocol":1,"name":"Jiro","colorID":2,"playerToken":"6ba7b810-9dad-11d1-80b4-00c04fd430c8"}
{"t":"assignSeat","player":"two"}
```

### Guest → host intents

| `t` | Fields |
| --- | --- |
| `intentCut` | `index` Int |
| `intentDiscard` | `cards` [Card] |
| `intentPlay` | `card` Card |
| `intentGo` | — |
| `intentLiftCut` | `index` Int |
| `intentRevealStarter` | — |
| `claimPoints` | `player` PlayerID, `amount` Int |
| `undo` | `player` PlayerID |
| `advance` | — |
| `playAgain` | — |
| `updateIdentity` | `name` String, `colorID` Int |
| `setScoringMode` | `mode` Int |
| `quitGame` | — |

A message with no fields is still a full object: `{"t":"intentGo"}`.

`updateIdentity`, `setScoringMode` and `quitGame` may travel in either direction.

---

## PlayerSnapshot

The redacted per-device view. The host sends one per device; a player's hole cards appear
only in that player's own snapshot until a reveal phase.

| Field | Type | Notes |
| --- | --- | --- |
| `matchID` | UUID | |
| `you` | PlayerID | |
| `phase` | GamePhase | |
| `yourSeat` | Seat | |
| `dealer` | PlayerID | |
| `yourHand` | [Card] | |
| `opponentHandCount` | Int | |
| `opponentHand` | [Card] | omitted before the show |
| `crib` | [Card] | omitted before counting reaches the crib |
| `cribCount` | Int | |
| `cribOwners` | Map<Card, PlayerID> | who discarded each crib card; omitted whenever `crib` is |
| `starter` | Card | omitted before the cut |
| `starterCutLifted` | Bool | |
| `playSequence` | [PlayedCard] | `{"card":Card,"player":PlayerID}` |
| `runningCount` | Int | |
| `lapCardCount` | Int | trailing `playSequence` cards in the current lap |
| `whoseTurn` | PlayerID | omitted when nobody is to act |
| `lastToPlay` | PlayerID | optional |
| `yourScore` | Int | |
| `opponentScore` | Int | |
| `flags` | [ScoreFlag] | `{"kind":…,"points":Int,"detail":String}` |
| `scoringMode` | ScoringMode | |
| `cutForDeal` | Map<PlayerID, Card> | |
| `winner` | PlayerID | optional |
| `yourName` | String | |
| `opponentName` | String | |
| `yourColorID` | Int | |
| `opponentColorID` | Int | |
| `playersWithClaims` | Set<PlayerID> | sorted array |
| `claimTick` | Int | |
| `lastClaimPlayer` | PlayerID | optional |
| `lastClaimAmount` | Int | |
| `pegEventTick` | Int | |
| `lastPegEvent` | PegEvent | optional; `{"kind":…,"scorer":PlayerID,"points":Int}` |
| `scoreLog` | [Claim] | `{"player":…,"amount":Int,"phase":GamePhase}`; only at `gameOver` |

`detail` on `ScoreFlag` is English and is a display string, not an identifier. Do not parse it.

---

## Legacy format (iOS only)

Before v1, iOS used Swift's derived `Codable` directly. Shipped builds speak it, so the
current iOS app reads **both** and writes whichever the peer understands.

- **Detection:** a root-level `"t"` key means v1. Its absence means legacy.
- **Writing:** default to legacy; switch to v1 for the rest of the session once the peer's
  `hello` carries `"protocol": 1`. A legacy peer never sends that field, so it keeps
  receiving exactly what it does today.
- Android only ever speaks v1 — it has no legacy peers.

> **The legacy path is transitional and is deleted at iOS 2.0.** See §2.1 of
> `~/Projects/PairForTwoAndroid/PLAN.md`.

---

## Golden fixtures

`fixtures/protocol-v1/*.json` in both repos holds one file per message type plus full
snapshots. Each side asserts it both **produces** and **accepts** these bytes. They are the
regression test for this document; if a change here does not change a fixture, it is not
really a protocol change.

Fixtures are stored pretty-printed with sorted keys for readable diffs. Comparison is done
on re-parsed values, not raw bytes, so formatting is not part of the contract — **key
presence, key names, types, and array order are.**
