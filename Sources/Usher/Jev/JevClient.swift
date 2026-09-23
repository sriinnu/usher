import Foundation

// MARK: - Question types

/// Mirrors the three System One primitives. `criteria` maps an answer key to the
/// description Jev reads, so the descriptions are the prompt.
struct JevQuestion: Encodable {
    var type: String
    var instructions: String
    var criteria: [String: String]?

    static func choice(_ instructions: String, _ criteria: [String: String]) -> JevQuestion {
        JevQuestion(type: "choice", instructions: instructions, criteria: criteria)
    }

    static func noul(_ instructions: String, yes: String, no: String) -> JevQuestion {
        JevQuestion(type: "noul", instructions: instructions,
                    criteria: ["true": yes, "false": no])
    }
}

// MARK: - Answers

struct ChoiceAnswer {
    var choice: String
    var confidence: Double
    var probabilities: [String: Double]

    /// Probability of the selected option, which is what gates a move.
    var topProbability: Double { probabilities[choice] ?? 0 }
}

enum JevAnswer {
    case choice(ChoiceAnswer)
    case noul(Double)
    case score(value: Double, confidence: Double)
    case unknown

    var asChoice: ChoiceAnswer? {
        if case .choice(let c) = self { return c }
        return nil
    }

    var asNoul: Double? {
        if case .noul(let p) = self { return p }
        return nil
    }
}

struct JevUsage: Decodable {
    var input_tokens: Int
    var output_tokens: Int
}

struct JevResponse {
    var model: String
    var answers: [String: JevAnswer]
    var usage: JevUsage?
}

// MARK: - Client

enum JevError: LocalizedError {
    case missingKey
    case http(status: Int, body: String)
    case badResponse(String)
    /// The last line of defence: a secret reached the classifier. Refused
    /// here, whatever path it came by, before a request is built.
    case refusedSecret(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No API key. Expected keychain service JEV_API_KEY, or the JEV_API_KEY / TYPESAFE_API_KEY environment variable."
        case .http(let status, let body):
            return "TypeSafe API returned \(status): \(body)"
        case .badResponse(let detail):
            return "Unreadable response: \(detail)"
        case .refusedSecret(let kind):
            return "Refused to send: looks like \(kind). Never sent, never moved."
        }
    }
}

/// One POST to /v1/systemone. Independent questions travel together so they run
/// in parallel on the server side.
struct JevClient {

    let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    var model: String
    var session: URLSession = .shared

    func ask(state: Any, questions: [String: JevQuestion]) async throws -> JevResponse {
        guard let key = KeyStore.apiKey() else { throw JevError.missingKey }

        let encodedQuestions = try JSONEncoder().encode(questions)
        let questionsJSON = try JSONSerialization.jsonObject(with: encodedQuestions)

        let body: [String: Any] = [
            "state": state,
            "model": model,
            "questions": questionsJSON
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The one place the key is used. Never log this header.
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let payload = try JSONSerialization.data(withJSONObject: body)
        // The last line before the network: the exact bytes, whatever built them.
        try OutboundGuard.screen(body: payload)
        request.httpBody = payload
        request.timeoutInterval = 45

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JevError.badResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<no body>"
            throw JevError.http(status: http.statusCode, body: String(text.prefix(500)))
        }

        return try parse(data)
    }

    private func parse(_ data: Data) throws -> JevResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JevError.badResponse("top level was not an object")
        }
        let model = root["model"] as? String ?? self.model
        let rawAnswers = root["answers"] as? [String: Any] ?? [:]

        var answers: [String: JevAnswer] = [:]
        for (id, raw) in rawAnswers {
            guard let entry = raw as? [String: Any] else { continue }
            switch entry["type"] as? String {
            case "choice":
                let probabilities = (entry["probabilities"] as? [String: Any] ?? [:])
                    .compactMapValues { ($0 as? NSNumber)?.doubleValue }
                answers[id] = .choice(ChoiceAnswer(
                    choice: entry["choice"] as? String ?? "",
                    confidence: (entry["confidence"] as? NSNumber)?.doubleValue ?? 0,
                    probabilities: probabilities
                ))
            case "noul":
                answers[id] = .noul((entry["noul"] as? NSNumber)?.doubleValue ?? 0)
            case "score":
                answers[id] = .score(
                    value: (entry["score"] as? NSNumber)?.doubleValue ?? 0,
                    confidence: (entry["confidence"] as? NSNumber)?.doubleValue ?? 0
                )
            default:
                answers[id] = .unknown
            }
        }

        var usage: JevUsage?
        if let rawUsage = root["usage"],
           let usageData = try? JSONSerialization.data(withJSONObject: rawUsage) {
            usage = try? JSONDecoder().decode(JevUsage.self, from: usageData)
        }

        return JevResponse(model: model, answers: answers, usage: usage)
    }
}
