import Foundation
import RewriteDBKit

// A tiny, dependency-free test runner. XCTest and swift-testing aren't fully available under
// the Command Line Tools (they ship with full Xcode), so this runs anywhere `swift` does:
//   swift run RewriteDBTests
// Exits non-zero if any check fails (so CI fails the build).

var total = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    total += 1
    if condition {
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name)")
    }
}

func checkThrows(_ name: String, _ body: () throws -> Void) {
    total += 1
    do {
        try body()
        failed += 1
        print("  ✗ \(name) (expected an error, none thrown)")
    } catch {
        print("  ✓ \(name)")
    }
}

func data(_ s: String) -> Data { Data(s.utf8) }

print("Instruction")
check("defaults contains 4 instructions", Instruction.defaults.count == 4)
check("first default is Auto Clean", Instruction.defaults.first?.name == "Auto Clean")
check("default ids are unique",
      Set(Instruction.defaults.map(\.id)).count == Instruction.defaults.count)
let inst = Instruction(name: "Formal", systemPrompt: "Be formal.")
check("shortcutKey derives from id", inst.shortcutKey == "instruction-\(inst.id.uuidString)")
do {
    let encoded = try JSONEncoder().encode(inst)
    let decoded = try JSONDecoder().decode(Instruction.self, from: encoded)
    check("Codable round-trip preserves fields", decoded == inst)
} catch {
    check("Codable round-trip preserves fields", false)
}

print("AnthropicModel")
do {
    let m = try JSONDecoder().decode(
        AnthropicModel.self, from: data(#"{"id":"claude-opus-4-8","display_name":"Claude Opus 4.8"}"#))
    check("decodes id and display_name", m.id == "claude-opus-4-8" && m.displayName == "Claude Opus 4.8")
    let m2 = try JSONDecoder().decode(AnthropicModel.self, from: data(#"{"id":"claude-mystery"}"#))
    check("falls back to id when display_name missing", m2.displayName == "claude-mystery")
} catch {
    check("decodes id and display_name", false)
    check("falls back to id when display_name missing", false)
}
check("preferredDefault prefers Sonnet",
      AnthropicModel.preferredDefault(from: [
          AnthropicModel(id: "claude-opus-4-8", displayName: "Opus"),
          AnthropicModel(id: "claude-sonnet-4-6", displayName: "Sonnet"),
      ]) == "claude-sonnet-4-6")
check("preferredDefault falls back to first when no Sonnet",
      AnthropicModel.preferredDefault(from: [
          AnthropicModel(id: "claude-opus-4-8", displayName: "Opus"),
          AnthropicModel(id: "claude-haiku-4-5", displayName: "Haiku"),
      ]) == "claude-opus-4-8")
check("preferredDefault empty for empty list", AnthropicModel.preferredDefault(from: []) == "")
check("sortedByDisplayName groups families and orders versions naturally",
      [AnthropicModel(id: "s5",  displayName: "Claude Sonnet 5"),
       AnthropicModel(id: "o41", displayName: "Claude Opus 4.10"),
       AnthropicModel(id: "o4",  displayName: "Claude Opus 4.6"),
       AnthropicModel(id: "f5",  displayName: "Claude Fable 5")]
      .sortedByDisplayName().map(\.displayName)
      == ["Claude Fable 5", "Claude Opus 4.6", "Claude Opus 4.10", "Claude Sonnet 5"])

print("HistoryEntry")
do {
    let entry = HistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_000),
                             instructionName: "Auto Clean", model: "Claude Sonnet 5",
                             before: "teh cat", after: "the cat")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(HistoryEntry.self, from: encoder.encode(entry))
    check("Codable round-trip preserves fields (iso8601 date)", decoded == entry)
} catch {
    check("Codable round-trip preserves fields (iso8601 date)", false)
}
do {
    var list: [HistoryEntry] = []
    for i in 0..<150 {
        list = list.prepending(
            HistoryEntry(date: Date(timeIntervalSince1970: Double(i)),
                         instructionName: "x", model: "m", before: "\(i)", after: "a"),
            cappedTo: 100)
    }
    check("history caps at 100", list.count == 100)
    check("history is newest-first", list.first?.before == "149")
    check("history drops the oldest past the cap", !list.contains { $0.before == "0" })
}
check("history keeps all entries under the cap",
      ([] as [HistoryEntry])
        .prepending(HistoryEntry(instructionName: "x", model: "m", before: "b", after: "a"), cappedTo: 100)
        .count == 1)
do {
    // Entries written before `kind` existed must still decode — defaulting to .rewrite.
    let legacy = #"{"id":"11111111-1111-1111-1111-111111111111","date":"2023-11-14T22:13:20Z","instructionName":"Auto Clean","model":"Claude Sonnet 5","before":"teh cat","after":"the cat"}"#
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(HistoryEntry.self, from: data(legacy))
    check("legacy history entry (no kind) decodes as .rewrite", decoded.kind == .rewrite)
} catch {
    check("legacy history entry (no kind) decodes as .rewrite", false)
}
do {
    let entry = HistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_000), kind: .dictation,
                             instructionName: "Dictation", model: "", before: "", after: "hello there")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(HistoryEntry.self, from: encoder.encode(entry))
    check("raw dictation round-trips (.dictation, empty before)",
          decoded == entry && decoded.kind == .dictation && decoded.before.isEmpty)
} catch {
    check("raw dictation round-trips (.dictation, empty before)", false)
}

print("RewriteProvider")
check("has anthropic and local cases", RewriteProvider.allCases.count == 2)
check("rawValues are stable (persisted to UserDefaults)",
      RewriteProvider.anthropic.rawValue == "anthropic" && RewriteProvider.local.rawValue == "local")
do {
    let decoded = try JSONDecoder().decode(RewriteProvider.self, from: JSONEncoder().encode(RewriteProvider.local))
    check("Codable round-trip preserves case", decoded == .local)
} catch {
    check("Codable round-trip preserves case", false)
}
check("decodes from a stored rawValue", RewriteProvider(rawValue: "anthropic") == .anthropic)
check("unknown rawValue is nil (falls back to default at load)", RewriteProvider(rawValue: "bogus") == nil)
check("providers have distinct display names", RewriteProvider.anthropic.displayName != RewriteProvider.local.displayName)

print("rewriteProviderOrder")
check("primary only when fallback off",
      rewriteProviderOrder(primary: .anthropic, fallbackEnabled: false, anthropicReady: true, localReady: true) == [.anthropic])
check("primary then fallback when both ready + enabled",
      rewriteProviderOrder(primary: .anthropic, fallbackEnabled: true, anthropicReady: true, localReady: true) == [.anthropic, .local])
check("falls through to ready fallback when primary not ready",
      rewriteProviderOrder(primary: .anthropic, fallbackEnabled: true, anthropicReady: false, localReady: true) == [.local])
check("empty when primary not ready and fallback off",
      rewriteProviderOrder(primary: .anthropic, fallbackEnabled: false, anthropicReady: false, localReady: true) == [])
check("empty when neither provider ready",
      rewriteProviderOrder(primary: .local, fallbackEnabled: true, anthropicReady: false, localReady: false) == [])
check("local primary then anthropic fallback",
      rewriteProviderOrder(primary: .local, fallbackEnabled: true, anthropicReady: true, localReady: true) == [.local, .anthropic])
check("no fallback appended when the other provider isn't ready",
      rewriteProviderOrder(primary: .anthropic, fallbackEnabled: true, anthropicReady: true, localReady: false) == [.anthropic])

print("AnthropicError.isAvailabilityFailure")
check("network is an availability failure", AnthropicError.network("x").isAvailabilityFailure)
check("missingAPIKey is an availability failure", AnthropicError.missingAPIKey.isAvailabilityFailure)
check("429 is an availability failure", AnthropicError.http(429, "").isAvailabilityFailure)
check("503 is an availability failure", AnthropicError.http(503, "").isAvailabilityFailure)
check("401 is an availability failure", AnthropicError.http(401, "").isAvailabilityFailure)
check("400 is NOT an availability failure", !AnthropicError.http(400, "").isAvailabilityFailure)
check("emptyResponse is NOT an availability failure", !AnthropicError.emptyResponse.isAvailabilityFailure)
check("decoding is NOT an availability failure", !AnthropicError.decoding("x").isAvailabilityFailure)

print("WordDiff")
check("identical strings are all equal",
      WordDiff.diff(before: "the cat sat", after: "the cat sat").allSatisfy { $0.kind == .equal })
check("pure insertion into empty", WordDiff.diff(before: "", after: "hi").map(\.kind) == [.inserted])
check("pure deletion to empty", WordDiff.diff(before: "hi", after: "").map(\.kind) == [.deleted])
check("empty → empty yields no tokens", WordDiff.diff(before: "", after: "").isEmpty)
do {
    let d = WordDiff.diff(before: "the quick brown fox", after: "the slow brown fox")
    let rebuiltBefore = d.filter { $0.kind != .inserted }.map(\.text).joined()
    let rebuiltAfter  = d.filter { $0.kind != .deleted  }.map(\.text).joined()
    check("diff reconstructs the before text", rebuiltBefore == "the quick brown fox")
    check("diff reconstructs the after text", rebuiltAfter == "the slow brown fox")
    check("changed word is marked deleted+inserted",
          d.contains { $0.kind == .deleted && $0.text.contains("quick") }
              && d.contains { $0.kind == .inserted && $0.text.contains("slow") })
    check("unchanged words stay equal",
          d.contains { $0.kind == .equal && $0.text.contains("brown") })
}
do {
    // Reconstruction invariant holds for an arbitrary edit.
    let before = "teh  cat are fluffy", after = "The cat is fluffy and happy"
    let d = WordDiff.diff(before: before, after: after)
    check("reconstruction invariant (before)", d.filter { $0.kind != .inserted }.map(\.text).joined() == before)
    check("reconstruction invariant (after)", d.filter { $0.kind != .deleted }.map(\.text).joined() == after)
}

print("AnthropicClient parsing")
do {
    let models = try AnthropicClient.parseModels(data(#"""
    {"data":[{"type":"model","id":"claude-opus-4-8","display_name":"Opus"},
             {"type":"model","id":"claude-sonnet-4-6","display_name":"Sonnet"}]}
    """#))
    check("parseModels returns ids in order", models.map(\.id) == ["claude-opus-4-8", "claude-sonnet-4-6"])
} catch {
    check("parseModels returns ids in order", false)
}
do {
    let text = try AnthropicClient.parseRewriteText(data(#"""
    {"content":[{"type":"thinking","thinking":"hmm"},
                {"type":"text","text":"Hello "},
                {"type":"text","text":"world."}]}
    """#))
    check("parseRewriteText joins text blocks, ignores others", text == "Hello world.")
} catch {
    check("parseRewriteText joins text blocks, ignores others", false)
}
checkThrows("parseRewriteText throws on empty content") {
    _ = try AnthropicClient.parseRewriteText(data(#"{"content":[]}"#))
}
checkThrows("parseRewriteText throws on malformed body") {
    _ = try AnthropicClient.parseRewriteText(data(#"{"unexpected":true}"#))
}
check("extractErrorMessage reads error.message",
      AnthropicClient.extractErrorMessage(
        data(#"{"type":"error","error":{"type":"not_found_error","message":"model: claude-retired"}}"#))
      == "model: claude-retired")
check("extractErrorMessage is nil when absent",
      AnthropicClient.extractErrorMessage(data(#"{"content":[]}"#)) == nil)

print("\n\(total - failed)/\(total) checks passed")
if failed > 0 {
    print("FAILED")
    exit(1)
}
print("OK")
