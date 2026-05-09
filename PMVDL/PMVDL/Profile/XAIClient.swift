import Foundation

struct XAIClient {
    static let endpoint = URL(string: "https://api.x.ai/v1/chat/completions")!
    static let model = "grok-4.3"

    static func generateProfile(input: ProfileGenerationInput, apiKey: String) async throws -> ProfileAIResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let inputData = try encoder.encode(input)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"

        let requestBody = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: "Profile evidence JSON:\n\(inputJSON)")
            ],
            temperature: 0.2
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XAIClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw XAIClientError.requestFailed(status: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw XAIClientError.emptyResponse
        }
        return try decodeProfileResponse(content)
    }

    private static let systemPrompt = """
You curate a source-attributed porn viewing profile from raw evidence. Return JSON only. Do not wrap it in markdown fences.

Input includes raw items plus deterministic ranked evidence summaries: uploaderSignals, explicitPerformerSignals, and titleNameSignals. Raw items include titles, URLs, uploader names/URLs, scraper performer hints, category/tag metadata, studio hints, source site context, duration, quality, and one of these exact sources: Saved Favorites, PornHub Liked, PornHub Favorites, Download History.

Infer whether uploader names are performers or studios from uploaderSignals first, then uploader name, uploader URL/path, title context, sample titles, sample URLs, and other metadata. Treat /pornstar/ and /model/ paths as strong performer evidence, /channels/ as studio evidence, and /user/ as ambiguous evidence you must classify from context. Scraper performer and studio fields are hints, not final truth.

Every uploaderSignals entry with count >= 2 must appear in exactly one of topPerformers, topStudios, or ignoredSignals. Repeated Download History uploaderName values are strong evidence even when the uploader name does not appear in the title; count >= 5 should be topPerformers unless the evidence points to a studio/channel. Lowercase handles and names with digits are valid performer/account names when repeated in Download History. Extract performer names from explicitPerformerSignals, titleNameSignals, and download history when they are clearly present. Do not invent names or themes that are not in the evidence. Do not count website/domain/site/sourceSiteName as a preference signal.

For every ranked entry and ignored signal, include a count and source breakdown using only these source labels: Saved Favorites, PornHub Liked, PornHub Favorites, Download History. Source citations must come from the summarized signal counts when a summarized signal exists, not only from title text.

The narrativeMarkdown value MUST use this exact markdown structure - each section on its own line, with ## headers:

## What I Learned About Your Habits
[paragraph]

## Top Performers (with source citations)
[paragraph]

## Preferred Categories & Themes (with source citations)
[paragraph]

## Studio Preferences (with source citations)
[paragraph]

## Viewing Patterns (duration, quality, frequency)
[paragraph]

## How This Profile Was Built (data sources used, counts, gaps/limitations)
[paragraph]

Do NOT run sections together. Each ## header must appear on its own line.

Return this exact JSON object shape:
{
  "narrativeMarkdown": "## What I Learned About Your Habits\\n...\\n## Top Performers (with source citations)\\n...\\n## Preferred Categories & Themes (with source citations)\\n...\\n## Studio Preferences (with source citations)\\n...\\n## Viewing Patterns (duration, quality, frequency)\\n...\\n## How This Profile Was Built (data sources used, counts, gaps/limitations)\\n...",
  "topPerformers": [{"name": "Performer Name", "count": 12, "sources": [{"source": "Saved Favorites", "count": 8}, {"source": "Download History", "count": 4}]}],
  "topCategories": [{"name": "Category", "count": 10, "sources": [{"source": "PornHub Liked", "count": 10}]}],
  "topTags": [{"name": "Tag", "count": 7, "sources": [{"source": "PornHub Favorites", "count": 7}]}],
  "topStudios": [{"name": "Studio", "count": 5, "sources": [{"source": "Saved Favorites", "count": 5}]}],
  "preferredQuality": [{"name": "1080p", "count": 6, "sources": [{"source": "Saved Favorites", "count": 6}]}],
  "ignoredSignals": [{"name": "Uploader Handle", "count": 2, "sources": [{"source": "Download History", "count": 2}], "reason": "Clear reason this repeated uploader is not a performer or studio preference."}]
}

The narrative must be direct and clinical. Every insight in the narrative must state what was found, how many times it appeared, and which source supplied it.
"""

    private static func decodeProfileResponse(_ content: String) throws -> ProfileAIResponse {
        let json = extractJSONObject(from: stripMarkdownFence(content))
        guard let data = json.data(using: .utf8) else {
            throw XAIClientError.invalidProfileJSON
        }
        do {
            return try JSONDecoder().decode(ProfileAIResponse.self, from: data)
        } catch {
            throw XAIClientError.invalidProfileJSON
        }
    }

    private static func stripMarkdownFence(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        if !lines.isEmpty { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONObject(from content: String) -> String {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start <= end else {
            return content
        }
        return String(content[start...end])
    }
}

enum XAIClientError: LocalizedError {
    case invalidResponse
    case emptyResponse
    case invalidProfileJSON
    case requestFailed(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "xAI returned an invalid response."
        case .emptyResponse:
            return "xAI returned an empty profile."
        case .invalidProfileJSON:
            return "xAI returned a profile format VidDL could not read."
        case .requestFailed(let status, let body):
            let message = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "xAI request failed with HTTP \(status)." : "xAI request failed with HTTP \(status): \(message)"
        }
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        let message: ChatMessage
    }

    let choices: [Choice]
}
