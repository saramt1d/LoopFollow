// LoopFollow
// ClaudeInsightsService.swift

import Foundation

/// Calls the Claude Messages API directly over HTTPS (there is no official
/// Swift SDK) and streams the answer back as text.
enum ClaudeInsightsService {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"

    enum Model: String, CaseIterable, Identifiable, Codable {
        case opus = "claude-opus-5-5"
        case sonnet = "claude-sonnet-5-5"
        case haiku = "claude-haiku-5-5"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .opus: return "Claude Opus 5.5 (best analysis)"
            case .sonnet: return "Claude Sonnet 5.5 (faster, cheaper)"
            case .haiku: return "Claude Haiku 5.5 (fastest, cheapest)"
            }
        }

        /// Haiku has no server-side refusal fallback; sending one is an error.
        var supportsServerFallback: Bool { self != .haiku }
    }

    enum Focus: String, CaseIterable, Identifiable {
        case summary
        case patterns
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .summary: return "Daily/weekly summary"
            case .patterns: return "Pattern detection"
            case .settings: return "Settings observations"
            }
        }

        var instruction: String {
            switch self {
            case .summary:
                return "Summary: time in range, average glucose, GMI and variability, and how they changed over the period (call out the best and worst days)."
            case .patterns:
                return "Patterns: recurring lows or highs by time of day, overnight trends, post-meal spikes, late or missing meal boluses, and lows that follow corrections or meals."
            case .settings:
                return "Settings observations: where the data suggests basal, ISF, carb ratio or targets may not fit (for example repeated overnight drift, or consistent post-meal peaks at one meal). Name the time block and the evidence. Frame these as questions to review with the care team, never as instructions to change a dose."
            }
        }
    }

    enum ServiceError: LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case refused(String?)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add your Anthropic API key in Settings → AI Insights."
            case let .http(code, message):
                switch code {
                case 401: return "The API key was rejected (401). Check the key in Settings → AI Insights."
                case 429: return "Rate limited by the Claude API (429). Try again in a minute."
                case 529: return "The Claude API is overloaded right now. Try again shortly."
                default: return "Claude API error \(code): \(message)"
                }
            case let .refused(explanation):
                return "Claude declined this request." + (explanation.map { " \($0)" } ?? "")
            }
        }
    }

    static let systemPrompt = """
    You are a diabetes data analyst inside LoopFollow, an iOS app used to follow \
    someone's continuous glucose monitor (CGM) and automated insulin delivery data from Nightscout. \
    The reader may be the person with diabetes or a caregiver.

    You will receive a pre-computed summary of Nightscout data. Analyse only what is in it; \
    if something can't be determined from the data (for example because treatments are missing), say so briefly \
    rather than guessing.

    Rules:
    - You are not a medical provider. Do not tell the reader to change insulin doses or settings. \
    Present settings-related findings as observations and questions to discuss with their diabetes care team.
    - If the data shows frequent or severe lows (for example any time below 54 mg/dL most days), mention it first.
    - Be specific: cite times of day, days, and numbers from the data.
    - Be concise and practical. Prefer a short list of the most important findings over an exhaustive one.

    Format (it is rendered on a phone):
    - Use "### " headings for sections and "- " bullets. Use **bold** sparingly. No tables, no code blocks.
    - Start with a 2-3 sentence overview, then the requested sections, then "### Things to discuss with your care team" if relevant.
    """

    static func userPrompt(dataSummary: String, focus: Set<Focus>, unit: String) -> String {
        let requested = Focus.allCases.filter { focus.contains($0) }.map { "- \($0.instruction)" }.joined(separator: "\n")
        return """
        <nightscout_data_summary>
        \(dataSummary)
        </nightscout_data_summary>

        The summary above uses mg/dL. Write every glucose value in your answer in \(unit)\
        \(unit == "mmol/L" ? " (divide mg/dL by 18 and use one decimal)" : "").

        Please cover:
        \(requested)
        """
    }

    /// Streams Claude's answer. Each yielded value is the full text so far.
    static func streamInsights(dataSummary: String,
                               focus: Set<Focus>,
                               unit: String,
                               model: Model) -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey = ClaudeAPIKeyStore.apiKey else { throw ServiceError.missingAPIKey }

                    var body: [String: Any] = [
                        "model": model.rawValue,
                        "max_tokens": 16000,
                        "stream": true,
                        "system": systemPrompt,
                        "output_config": ["effort": "high"],
                        "messages": [
                            ["role": "user", "content": userPrompt(dataSummary: dataSummary, focus: focus, unit: unit)],
                        ],
                    ]

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 300
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
                    if model.supportsServerFallback {
                        // On a safety-classifier decline, retry server-side on the
                        // model Anthropic recommends for that category.
                        body["fallbacks"] = "default"
                        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var raw = ""
                        for try await line in bytes.lines {
                            raw += line
                        }
                        throw ServiceError.http(status, errorMessage(from: raw))
                    }

                    var text = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String
                        else { continue }

                        switch type {
                        case "content_block_start":
                            // A fallback block marks a server-side switch to another
                            // model after a decline; drop the declined partial text.
                            if let block = event["content_block"] as? [String: Any],
                               block["type"] as? String == "fallback"
                            {
                                text = ""
                                continuation.yield(text)
                            }
                        case "content_block_delta":
                            if let delta = event["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let piece = delta["text"] as? String
                            {
                                text += piece
                                continuation.yield(text)
                            }
                        case "message_delta":
                            if let delta = event["delta"] as? [String: Any],
                               delta["stop_reason"] as? String == "refusal"
                            {
                                let details = delta["stop_details"] as? [String: Any]
                                throw ServiceError.refused(details?["explanation"] as? String)
                            }
                        case "error":
                            let err = event["error"] as? [String: Any]
                            throw ServiceError.http(0, err?["message"] as? String ?? "Stream error")
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func errorMessage(from raw: String) -> String {
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let message = err["message"] as? String
        {
            return message
        }
        return raw.isEmpty ? "No response body" : String(raw.prefix(300))
    }
}
