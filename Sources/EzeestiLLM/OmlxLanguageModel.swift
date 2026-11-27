import Foundation
import EzeestiCore

/// EstLLM via a required local OMLX server (`POST /v1/chat/completions`).
public actor OmlxLanguageModel: LanguageModeling {
    public let client: OmlxClient
    /// Default sampling temperature when callers omit an override.
    public let temperature: Double

    public init(client: OmlxClient, temperature: Double = 0.2) {
        self.client = client
        self.temperature = temperature
    }

    public init(config: OmlxConfig, temperature: Double = 0.2) {
        self.client = OmlxClient(config: config)
        self.temperature = temperature
    }

    public func complete(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> String {
        let sampling = temperature ?? self.temperature
        return try await client.chatCompletions(
            messages: [.system(system), .user(user)],
            maxTokens: maxTokens,
            temperature: sampling
        )
    }

    public func warmup() async throws {
        try await client.checkReady()
        let ids = try await client.listModelIDs()
        let wanted = await client.config.llmModelID
        guard ids.contains(where: { $0 == wanted || $0.hasSuffix("/\(wanted)") || $0.hasSuffix(wanted) })
        else {
            let available = ids.isEmpty ? "(none)" : ids.joined(separator: ", ")
            throw EzeestiError.modelMissing(
                "OMLX LLM model '\(wanted)' not listed. Available: \(available). Run Scripts/fetch-models.sh and restart OMLX."
            )
        }
    }

    public func shutdown() async {}
}

/// Always resolves to the OMLX chat backend (required; no in-process fallback).
public enum LLMBackend {
    public static func resolve(config: OmlxConfig = .fromEnvironment()) -> any LanguageModeling {
        OmlxLanguageModel(config: config)
    }
}
