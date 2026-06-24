//
//  OllamaClient.swift
//  notch
//
//  Minimal HTTP client for Ollama. Handles model listing + non-streaming chat completions; streaming
//  can be layered on later by switching `stream` to true and parsing the NDJSON response.
//

import Foundation

extension String {
    /// Trims whitespace, then strips common formatting artifacts the model leaks into one-shot
    /// replies: surrounding quotes (straight, single, curly), code fences (triple-backtick
    /// blocks or single-backtick spans), and leading bullet markers (`- ` or `* `). Applied
    /// iteratively so combined wrappers (`- "text"`, `` `- text` ``) all collapse in one pass.
    /// Single sentence replies that the model thought should be "a bullet" or "a quote" or
    /// "a code snippet" come back as plain text.
    func strippingSurroundingQuotes() -> String {
        var current = self.trimmingCharacters(in: .whitespacesAndNewlines)
        // Iterate until nothing changes — handles nested / combined wrappers.
        while true {
            let next = current.strippedOnePass()
            if next == current { return current }
            current = next
        }
    }

    /// Removes one outer layer of recognizable wrapping. Internal helper for the iterative
    /// pass above. Order matters: code-fence checks run before quote checks because a fence
    /// might contain quotes that aren't really "surrounding."
    fileprivate func strippedOnePass() -> String {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Leading bullet / heading / blockquote marker on a single-line reply: strip.
        // Multi-line content: still strip a leading marker on the FIRST line only — we
        // assume a model preface like "- " on its own first line is leakage even when the
        // rest is multi-line. (Real markdown lists usually have content after the marker
        // on the same line, which still gets handled correctly.)
        let prefixesToStrip = ["- ", "* ", "# ", "## ", "### ", "> "]
        for prefix in prefixesToStrip {
            if trimmed.hasPrefix(prefix) {
                let rest = String(trimmed.dropFirst(prefix.count))
                return rest.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Lone bullet marker on its own line followed by content: "- \nrest" → "rest".
        if trimmed.hasPrefix("-\n") || trimmed.hasPrefix("*\n") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Leading bracketed metadata like "[2026-06-23 7:24 PM] " or "[system] " — the model
        // sometimes mimics the timestamp-prefix format we inject into chat history. Drop one
        // outer `[...]` when it sits at the very start.
        if trimmed.hasPrefix("[") {
            if let close = trimmed.firstIndex(of: "]") {
                let after = trimmed.index(after: close)
                let rest = String(trimmed[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    return rest
                }
            }
        }

        // Triple-backtick fence (with optional language tag): ```lang\nbody\n```
        if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") && trimmed.count > 6 {
            var inner = String(trimmed.dropFirst(3).dropLast(3))
            // Drop a leading "lang\n" if present.
            if let newline = inner.firstIndex(of: "\n") {
                let possibleLang = inner[inner.startIndex..<newline]
                if possibleLang.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                    inner = String(inner[inner.index(after: newline)...])
                }
            }
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Single-backtick wrapping: `text` (only when both ends; not for inline code in prose).
        if trimmed.count >= 2,
           trimmed.first == "`", trimmed.last == "`",
           !trimmed.dropFirst().dropLast().contains("`") {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Surrounding quotes (straight, single, curly).
        let openers: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}"]
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}"]
        if trimmed.count >= 2,
           let first = trimmed.first, let last = trimmed.last,
           openers.contains(first), closers.contains(last) {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }
}

enum OllamaClient {
    enum ClientError: LocalizedError {
        case invalidURL
        case missingModel
        case http(Int)
        case decode

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .missingModel: return "No model selected"
            case .http(let code): return "HTTP \(code)"
            case .decode: return "Unexpected response"
            }
        }
    }

    // MARK: - Tags (model list)

    private struct TagsResponse: Decodable {
        struct Tag: Decodable { let name: String }
        let models: [Tag]
    }

    static func listModels(baseURL: String) async throws -> [String] {
        let url = try makeURL(baseURL: baseURL, path: "api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
        guard let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) else {
            throw ClientError.decode
        }
        return decoded.models.map(\.name).sorted()
    }

    // MARK: - Chat

    struct ChatMessage: Codable, Identifiable, Equatable {
        enum Role: String, Codable { case user, assistant, system }
        var id: UUID = UUID()
        let role: Role
        let content: String
        /// When this message was created. Optional so older persisted transcripts (without the
        /// field) decode cleanly; UI treats nil as "unknown — don't render a timestamp."
        var timestamp: Date? = Date()
    }

    /// Sampling knobs sent on every chat request. Defaults are tuned to fight the "settles into the
     /// same phrasing" failure mode we kept hitting with the personality-voice prompts: an explicit
     /// random seed forces a fresh sampling trajectory each call, a higher `repeat_penalty` plus
     /// wider `repeat_last_n` make the model actively avoid recent tokens, and a slightly elevated
     /// temperature loosens the distribution. Override per call (e.g. low temperature for the
     /// JSON-scoring request).
     struct Options: Encodable {
        var temperature: Double = 0.9
        // 1.25 (our first pass) was strong enough on smaller models to push them toward emitting
        // empty / sentinel replies. 1.15 still meaningfully discourages echoing without making
        // the distribution collapse.
        var repeat_penalty: Double = 1.15
        var repeat_last_n: Int = 256
        var seed: Int

        nonisolated static func variedDefaults() -> Options {
            // 31-bit positive int — Ollama wants a non-negative integer seed.
            Options(seed: Int.random(in: 1...Int(Int32.max)))
        }

        nonisolated static func deterministicJSON() -> Options {
            Options(temperature: 0.2, repeat_penalty: 1.1, repeat_last_n: 64, seed: Int.random(in: 1...Int(Int32.max)))
        }
    }

    private struct ChatRequest: Encodable {
        struct Msg: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Msg]
        let stream: Bool
        let options: Options
    }

    private struct ChatResponse: Decodable {
        struct Msg: Decodable { let role: String; let content: String }
        let message: Msg
    }

    /// Sends a single chat completion request (non-streaming) and returns the assistant reply text.
    static func chat(baseURL: String, model: String, history: [ChatMessage], options: Options = .variedDefaults()) async throws -> String {
        guard !model.isEmpty else { throw ClientError.missingModel }
        let url = try makeURL(baseURL: baseURL, path: "api/chat")
        let body = ChatRequest(
            model: model,
            messages: history.map { ChatRequest.Msg(role: $0.role.rawValue, content: $0.content) },
            stream: false,
            options: options
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        // Local LLMs can take a while on the first request (model load); generous timeout.
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw ClientError.decode
        }
        return decoded.message.content
    }

    // MARK: - Helpers

    private static func makeURL(baseURL: String, path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let base = URL(string: cleaned) else { throw ClientError.invalidURL }
        return base.appendingPathComponent(path)
    }

    private static func validate(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
    }
}
