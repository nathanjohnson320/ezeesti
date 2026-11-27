import Foundation

/// Connection settings for a required local OMLX server (OpenAI-compatible API).
public struct OmlxConfig: Sendable, Hashable {
    public let baseURL: URL
    public let apiKey: String?
    public let llmModelID: String
    public let sttModelID: String

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8000/v1")!,
        apiKey: String? = nil,
        llmModelID: String = EstLLMVariant.recommended().directoryName,
        sttModelID: String = ModelPaths.defaultWhisperDirectoryName
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.llmModelID = llmModelID
        self.sttModelID = sttModelID
    }

    /// Reads `EZEESTI_OMLX_BASE_URL`, `EZEESTI_OMLX_API_KEY`, `EZEESTI_OMLX_LLM_MODEL`,
    /// and `EZEESTI_OMLX_STT_MODEL` (empty key clears auth).
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        modelPaths: ModelPaths? = nil
    ) -> OmlxConfig {
        let base: URL
        if let raw = environment["EZEESTI_OMLX_BASE_URL"], !raw.isEmpty,
           let url = URL(string: raw)
        {
            base = url
        } else {
            base = URL(string: "http://127.0.0.1:8000/v1")!
        }

        let apiKey: String?
        if let key = environment["EZEESTI_OMLX_API_KEY"] {
            apiKey = key.isEmpty ? nil : key
        } else {
            apiKey = nil
        }

        let llmDefault = modelPaths?.estLLMDirectory?.lastPathComponent
            ?? EstLLMVariant.recommended().directoryName
        let sttDefault = modelPaths?.whisperDirectory?.lastPathComponent
            ?? ModelPaths.defaultWhisperDirectoryName

        let llm = environment["EZEESTI_OMLX_LLM_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? llmDefault
        let stt = environment["EZEESTI_OMLX_STT_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? sttDefault

        return OmlxConfig(baseURL: base, apiKey: apiKey, llmModelID: llm, sttModelID: stt)
    }

    public var modelsURL: URL {
        baseURL.appendingPathComponent("models")
    }

    public var chatCompletionsURL: URL {
        baseURL.appendingPathComponent("chat/completions")
    }

    public var transcriptionsURL: URL {
        baseURL.appendingPathComponent("audio/transcriptions")
    }
}

/// One chat message for `/v1/chat/completions`.
public struct OmlxChatMessage: Sendable, Hashable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> OmlxChatMessage {
        OmlxChatMessage(role: "system", content: content)
    }

    public static func user(_ content: String) -> OmlxChatMessage {
        OmlxChatMessage(role: "user", content: content)
    }
}

/// HTTP client for a local OMLX OpenAI-compatible server.
public actor OmlxClient {
    public let config: OmlxConfig
    private let session: URLSession

    public init(config: OmlxConfig = .fromEnvironment(), session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Confirms the server responds and lists at least one model.
    public func checkReady() async throws {
        var request = URLRequest(url: config.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        applyAuth(to: &request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EzeestiError.omlxUnavailable(
                "Cannot reach OMLX at \(config.baseURL.absoluteString) — start with: omlx serve --model-dir \"~/Library/Application Support/Ezeesti/Models\" (\(error.localizedDescription))"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw EzeestiError.omlxUnavailable("Invalid response from OMLX /models")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EzeestiError.omlxUnavailable(
                "OMLX /models returned HTTP \(http.statusCode)\(body.isEmpty ? "" : ": \(body)")"
            )
        }
    }

    /// Returns installed model IDs from `GET /v1/models`.
    public func listModelIDs() async throws -> [String] {
        var request = URLRequest(url: config.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        applyAuth(to: &request)

        let (data, response) = try await perform(request)
        try throwIfHTTPError(response, data: data, context: "list models")

        let decoded = try JSONDecoder().decode(ModelsListResponse.self, from: data)
        return decoded.data.map(\.id)
    }

    /// Non-streaming chat completion; returns the assistant message content.
    public func chatCompletions(
        messages: [OmlxChatMessage],
        model: String? = nil,
        maxTokens: Int = 160,
        temperature: Double? = 0.2
    ) async throws -> String {
        let modelID = model ?? config.llmModelID
        var body: [String: Any] = [
            "model": modelID,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": max(1, maxTokens),
            "stream": false,
        ]
        if let temperature {
            body["temperature"] = temperature
        }

        var request = URLRequest(url: config.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await perform(request)
        try throwIfHTTPError(response, data: data, context: "chat completions")

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !content.isEmpty
        else {
            throw EzeestiError.llmFailed("Empty response from OMLX model \(modelID)")
        }
        return content
    }

    /// Multipart speech-to-text via `/v1/audio/transcriptions`.
    public func transcribe(
        fileURL: URL,
        model: String? = nil,
        language: String = "et",
        prompt: String? = nil
    ) async throws -> String {
        let modelID = model ?? config.sttModelID
        let boundary = "ezeesti-\(UUID().uuidString)"
        var request = URLRequest(url: config.transcriptionsURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        applyAuth(to: &request)

        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw EzeestiError.transcriptionFailed("Could not read audio: \(error.localizedDescription)")
        }

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", modelID)
        appendField("language", language)
        appendField("response_format", "json")
        if let prompt, !prompt.isEmpty {
            appendField("prompt", prompt)
        }

        let filename = fileURL.lastPathComponent
        let mime = Self.mimeType(for: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await perform(request)
        try throwIfHTTPError(response, data: data, context: "transcription")

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyAuth(to request: inout URLRequest) {
        if let apiKey = config.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw EzeestiError.omlxUnavailable(
                "OMLX request failed (\(request.url?.absoluteString ?? "?")): \(error.localizedDescription)"
            )
        }
    }

    private func throwIfHTTPError(_ response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw EzeestiError.omlxUnavailable("Invalid HTTP response during \(context)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let snippet = body.count > 400 ? String(body.prefix(400)) + "…" : body
            throw EzeestiError.omlxUnavailable(
                "OMLX \(context) HTTP \(http.statusCode)\(snippet.isEmpty ? "" : ": \(snippet)")"
            )
        }
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Response DTOs

private struct ModelsListResponse: Decodable {
    struct Item: Decodable {
        let id: String
    }

    let data: [Item]
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct TranscriptionResponse: Decodable {
    let text: String
}
