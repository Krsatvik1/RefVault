import Foundation

/// Loads the four tool prompts from the bundled Resources/prompts folder.
enum PromptStore {
    static func load(_ name: String) throws -> String {
        // SwiftPM puts resources under Bundle.module.
        if let url = Bundle.refvaultResources.url(
            forResource: name,
            withExtension: "txt",
            subdirectory: "Resources/prompts"
        ),
           let str = try? String(contentsOf: url, encoding: .utf8) {
            return str
        }
        // Fall back to a path next to the executable for Xcode app bundles.
        if let main = Bundle.main.url(
            forResource: name,
            withExtension: "txt",
            subdirectory: "prompts"
        ),
           let str = try? String(contentsOf: main, encoding: .utf8) {
            return str
        }
        throw RefVaultError.promptResourceMissing("\(name).txt")
    }

    static var relevance: String { (try? load("relevance")) ?? "" }
    static var metadata: String { (try? load("metadata")) ?? "" }
    static var colors: String   { (try? load("colors"))   ?? "" }
    static var url: String      { (try? load("url"))      ?? "" }
}
