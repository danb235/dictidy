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
