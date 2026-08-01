// LAN interop harness — the Swift end.
//
// Runs the *real* `LANTransport.swift` as a command-line process. Network.framework works on macOS,
// so the shipping iOS transport can be driven against the shipping Kotlin one over real Bonjour and
// a real TCP socket, on this machine, with no devices involved. That is the "throwaway harness
// before any UI exists" from PLAN.md §10 phase 4 — except it is automatable, so it can be re-run
// whenever either transport changes.
//
// Two roles, so a run covers both directions:
//
//   --mode drive   send the whole fixture corpus, wait for each echo, compare, report
//   --mode echo    send back every message received, verbatim
//
// The corpus is `fixtures/protocol-v1/*.json` — the golden set both implementations already agree
// on — so the two harnesses build an identical corpus by construction rather than by two people
// typing the same list twice. The echoer re-encodes from its *decoded* value, so a decode bug can't
// slip through as a passing echo.
//
// Build and run via tools/run-lan-interop.sh.

import Foundation

// MARK: - Arguments

func arg(_ name: String, default def: String? = nil) -> String {
    var it = CommandLine.arguments.makeIterator()
    while let a = it.next() {
        if a == "--\(name)", let v = it.next() { return v }
    }
    guard let def else {
        FileHandle.standardError.write("missing --\(name)\n".data(using: .utf8)!)
        exit(2)
    }
    return def
}

let role = arg("role")                       // host | guest
let mode = arg("mode")                       // drive | echo
let myName = arg("name", default: "Swift")
let peerName = arg("peer", default: "")
let fixturesDir = arg("fixtures", default: "fixtures/protocol-v1")
let timeout = Double(arg("timeout", default: "60"))!

func note(_ s: String) {
    print("[swift/\(role)/\(mode)] \(s)")
    fflush(stdout)
}

func die(_ s: String) -> Never {
    note("FAIL: \(s)")
    exit(1)
}

// MARK: - Corpus

/// Ordered by filename so both harnesses walk the corpus identically.
func loadCorpus() -> [(String, GameMessage)] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: fixturesDir) else {
        die("no fixtures at \(fixturesDir)")
    }
    var out: [(String, GameMessage)] = []
    for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
        guard let data = fm.contents(atPath: "\(fixturesDir)/\(name)"),
              let message = WireCodec.decode(data) else {
            die("could not decode fixture \(name)")
        }
        out.append((String(name.dropLast(5)), message))
    }
    return out
}

/// Compares by canonical JSON tree rather than by `==`: what has to survive the wire is the
/// encoding, and two messages that encode identically are the same message as far as interop goes.
func sameMessage(_ a: GameMessage, _ b: GameMessage) -> Bool {
    guard let da = try? WireCodec.encode(a, as: .v1), let db = try? WireCodec.encode(b, as: .v1),
          let oa = try? JSONSerialization.jsonObject(with: da) as? [String: Any],
          let ob = try? JSONSerialization.jsonObject(with: db) as? [String: Any] else { return false }
    return NSDictionary(dictionary: oa).isEqual(to: ob)
}

// MARK: - Run

@MainActor
final class Harness {
    let transport: LANTransport
    let corpus: [(String, GameMessage)]
    var inbox: [GameMessage] = []
    var connected = false

    init() {
        transport = LANTransport(displayName: myName)
        corpus = loadCorpus()
    }

    func start() {
        Task { [transport] in
            for await event in transport.events {
                await MainActor.run { self.handle(event) }
            }
        }
        if role == "host" {
            transport.startHosting()
            note("advertising as '\(myName)' on \(LANTransport.serviceType)")
        } else {
            transport.startBrowsing()
            note("browsing for '\(peerName)'")
            Task { await self.inviteWhenFound() }
        }
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .connected:
            connected = true
            note("connected")
        case .received(let m):
            inbox.append(m)
            if mode == "echo" {
                Task { await self.transport.send(m) }
            }
        case .reconnecting:
            note("reconnecting")
        case .disconnected:
            note("disconnected")
        }
    }

    private func inviteWhenFound() async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let peer = transport.discoveredPeers.first(where: { peerName.isEmpty || $0.name == peerName }) {
                note("found '\(peer.name)' — inviting")
                transport.invite(peer)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        die("never discovered '\(peerName)'")
    }

    func awaitConnected() async {
        let deadline = Date().addingTimeInterval(timeout)
        while !connected {
            if Date() > deadline { die("never connected") }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Waits until `inbox` holds at least `n` messages.
    func awaitInbox(_ n: Int, what: String) async {
        let deadline = Date().addingTimeInterval(timeout)
        while inbox.count < n {
            if Date() > deadline { die("timed out waiting for \(what) (\(inbox.count)/\(n))") }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func drive() async {
        note("corpus: \(corpus.count) messages")

        // Pass 1 — one at a time, so a mismatch names the exact message type.
        for (name, message) in corpus {
            let before = inbox.count
            await transport.send(message)
            await awaitInbox(before + 1, what: "echo of \(name)")
            guard sameMessage(inbox[before], message) else { die("echo of '\(name)' differed") }
        }
        note("✓ round-trip: \(corpus.count) message types, one at a time")

        // Pass 2 — the whole corpus back to back with no pauses, so the peer's reader has to
        // reassemble whatever TCP hands it. This is the pass that catches framing bugs.
        let before = inbox.count
        for (_, message) in corpus { await transport.send(message) }
        await awaitInbox(before + corpus.count, what: "burst echoes")
        for (i, entry) in corpus.enumerated() {
            guard sameMessage(inbox[before + i], entry.1) else {
                die("burst echo \(i) ('\(entry.0)') differed or arrived out of order")
            }
        }
        note("✓ burst: \(corpus.count) messages back to back, in order")

        note("PASS")
    }

    func echo() async {
        // Two passes of the corpus, echoed as they arrive by `handle`.
        await awaitInbox(corpus.count * 2, what: "the driver's two passes")
        note("✓ echoed \(inbox.count) messages")
        note("PASS")
        // Give the last echo time to reach the driver before the process exits and the socket dies.
        try? await Task.sleep(for: .milliseconds(500))
    }
}

@MainActor
func runHarness() async {
    let harness = Harness()
    harness.start()
    await harness.awaitConnected()
    if mode == "drive" { await harness.drive() } else { await harness.echo() }
}

await runHarness()
exit(0)
