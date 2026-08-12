import AVFoundation
import Foundation
import EzeestiCore

/// Offline text-to-speech used by tutoring and learning flows.
public protocol TextSpeaking: Sendable {
    /// Speak `text`. `languageCode` is reserved for multi-locale backends (BCP-47).
    func speak(_ text: String, languageCode: String) async throws
    /// Prefetch models / start persistent worker so the first hear is not a 30s cold start.
    func prepare() async throws
}

extension TextSpeaking {
    public func prepare() async throws {}
}

/// Keeps one Neurokõne Python process alive so TensorFlow/HiFi-GAN load once per app launch.
/// Injected by `NeurokoneTTSService` (no process-global singleton).
public actor NeurokoneSession {
    /// Default Neurokõne voice id used by the CLI worker.
    public static let defaultVoiceID = "mari"

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutReader: FileHandleLineReader?
    private var binaryPath: URL?
    private var defaultSpeaker = NeurokoneSession.defaultVoiceID
    private var ready = false

    public init() {}

    public func prepare(binaryPath: URL, speaker: String = NeurokoneSession.defaultVoiceID) async throws {
        defaultSpeaker = speaker
        if ready, self.binaryPath == binaryPath, process?.isRunning == true {
            try await ping()
            return
        }
        try await start(binaryPath: binaryPath, speaker: speaker)
    }

    public func synthesize(text: String, outURL: URL, speaker: String?, speed: Double) async throws {
        guard let binaryPath else {
            throw EzeestiError.ttsFailed("Neurokõne session not prepared")
        }
        if !ready || process?.isRunning != true {
            try await start(binaryPath: binaryPath, speaker: defaultSpeaker)
        }

        let payload: [String: Any] = [
            "text": text,
            "out": outURL.path,
            "speaker": speaker ?? defaultSpeaker,
            "speed": speed,
        ]
        let line = try JSONSerialization.data(withJSONObject: payload)
        guard let encoded = String(data: line, encoding: .utf8) else {
            throw EzeestiError.ttsFailed("Could not encode Neurokõne request")
        }
        let request = encoded + "\n"
        guard let stdinHandle, let data = request.data(using: .utf8) else {
            throw EzeestiError.ttsFailed("Neurokõne stdin unavailable")
        }
        try stdinHandle.write(contentsOf: data)

        let response: [String: Any]
        do {
            response = try await readJSONObject()
        } catch {
            // A leaked log line can desync the JSON protocol — recycle the worker.
            stop()
            throw error
        }
        guard (response["ok"] as? Bool) == true else {
            let message = (response["error"] as? String) ?? "Neurokõne synthesize failed"
            throw EzeestiError.ttsFailed(message)
        }
        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw EzeestiError.ttsFailed("Neurokõne produced no audio file")
        }
    }

    private func ping() async throws {
        let payload = #"{"cmd":"ping"}"# + "\n"
        guard let stdinHandle, let data = payload.data(using: .utf8) else {
            throw EzeestiError.ttsFailed("Neurokõne stdin unavailable")
        }
        try stdinHandle.write(contentsOf: data)
        let response = try await readJSONObject()
        guard (response["ok"] as? Bool) == true else {
            throw EzeestiError.ttsFailed("Neurokõne ping failed")
        }
    }

    private func start(binaryPath: URL, speaker: String) async throws {
        stop()
        self.binaryPath = binaryPath
        defaultSpeaker = speaker

        guard FileManager.default.isExecutableFile(atPath: binaryPath.path) else {
            throw EzeestiError.modelMissing("neurokone-cli at \(binaryPath.path). Run Scripts/setup-neurokone.sh")
        }

        let process = Process()
        process.executableURL = binaryPath
        process.arguments = ["--serve", "--speaker", speaker]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.stderrHandle = stderr.fileHandleForReading
        // Drain stderr so the pipe does not fill and stall the worker.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        self.stdoutReader = FileHandleLineReader(handle: stdout.fileHandleForReading)

        // Wait until models are loaded ("READY\n").
        try await waitUntilReady(timeout: 180)
        ready = true
    }

    private func waitUntilReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if process?.isRunning != true {
                throw EzeestiError.ttsFailed("Neurokõne worker exited before READY")
            }
            let line = try await nextStdoutLine(deadline: deadline)
            if line == "READY" {
                return
            }
        }
        throw EzeestiError.ttsFailed("Neurokõne worker exited before READY")
    }

    /// Reads the next protocol JSON object from stdout, skipping log noise.
    private func readJSONObject() async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let line = try await nextStdoutLine(deadline: deadline)
            // Skip protocol noise and library log lines that leak onto stdout
            // (e.g. "INFO:synthesizer.py:76: Request received: …").
            if line.isEmpty || line == "READY" || !line.hasPrefix("{") {
                continue
            }
            return try Self.parseProtocolObject(line)
        }
        throw EzeestiError.ttsFailed("Neurokõne timed out waiting for JSON response")
    }

    private func nextStdoutLine(deadline: Date) async throws -> String {
        guard let stdoutReader else {
            throw EzeestiError.ttsFailed("Neurokõne stdout unavailable")
        }
        do {
            return try await stdoutReader.nextLine(deadline: deadline)
        } catch is FileHandleLineReader.TimeoutError {
            if process?.isRunning != true {
                throw EzeestiError.ttsFailed("Neurokõne worker died")
            }
            throw EzeestiError.ttsFailed("Neurokõne timed out waiting for stdout")
        } catch is FileHandleLineReader.ClosedError {
            throw EzeestiError.ttsFailed("Neurokõne worker died")
        }
    }

    private static func parseProtocolObject(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8) else {
            throw EzeestiError.ttsFailed("Bad Neurokõne response encoding: \(line)")
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any] else {
                throw EzeestiError.ttsFailed("Neurokõne response was not a JSON object: \(line)")
            }
            guard dict["ok"] is Bool else {
                throw EzeestiError.ttsFailed("Neurokõne response missing ok flag: \(line)")
            }
            return dict
        } catch let error as EzeestiError {
            throw error
        } catch {
            throw EzeestiError.ttsFailed("Bad Neurokõne JSON: \(line)")
        }
    }

    private func stop() {
        ready = false
        stdoutReader?.cancel()
        stdoutReader = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        if let stdinHandle {
            do {
                try stdinHandle.close()
            } catch {
                // Best-effort teardown while recycling / shutting down the worker.
            }
        }
        process?.terminate()
        process = nil
        self.stdinHandle = nil
    }
}

/// Async line reader backed by `FileHandle.readabilityHandler` (event-driven, no sleep polling).
private final class FileHandleLineReader: @unchecked Sendable {
    struct TimeoutError: Error {}
    struct ClosedError: Error {}

    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] fileHandle in
            self?.receive(fileHandle.availableData)
        }
    }

    func cancel() {
        handle.readabilityHandler = nil
        lock.lock()
        closed = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: ClosedError())
    }

    func nextLine(deadline: Date) async throws -> String {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw TimeoutError() }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.waitForLine()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(remaining))
                throw TimeoutError()
            }
            let line = try await group.next()!
            group.cancelAll()
            return line
        }
    }

    private func waitForLine() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !pending.isEmpty {
                    let line = pending.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: line)
                    return
                }
                if closed {
                    lock.unlock()
                    continuation.resume(throwing: ClosedError())
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }

    private func receive(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if chunk.isEmpty {
            flushRemainderLocked()
            closed = true
            handle.readabilityHandler = nil
            if let waiter {
                self.waiter = nil
                waiter.resume(throwing: ClosedError())
            }
            return
        }

        buffer.append(chunk)
        while let text = String(data: buffer, encoding: .utf8),
              let newline = text.firstIndex(of: "\n") {
            let line = String(text[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(text[text.index(after: newline)...])
            buffer = Data(rest.utf8)
            deliverLocked(line)
        }
    }

    private func deliverLocked(_ line: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: line)
        } else {
            pending.append(line)
        }
    }

    private func flushRemainderLocked() {
        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) else { return }
        buffer.removeAll(keepingCapacity: false)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            deliverLocked(trimmed)
        }
    }
}

/// Offline Neurokõne via a persistent local CLI worker (TransformerTTS + HiFi-GAN).
/// Owns its `NeurokoneSession` so the app can inject/share one service instance.
public struct NeurokoneTTSService: TextSpeaking {
    /// Rate multiplier sent to the worker: the model divides phoneme durations by it,
    /// so values below 1 stretch speech without shifting pitch. Native-paced Estonian (1.0)
    /// is too fast for learners to hear word boundaries; below ~0.7 the vocoder smears.
    public static let defaultSpeed = 0.85

    public let binaryPath: URL
    public let speaker: String
    public let speed: Double

    private let session: NeurokoneSession

    public init(
        binaryPath: URL,
        speaker: String = NeurokoneSession.defaultVoiceID,
        speed: Double = NeurokoneTTSService.defaultSpeed
    ) {
        self.init(
            binaryPath: binaryPath,
            speaker: speaker,
            speed: speed,
            session: NeurokoneSession()
        )
    }

    public init(
        binaryPath: URL,
        speaker: String,
        speed: Double,
        session: NeurokoneSession
    ) {
        self.binaryPath = binaryPath
        self.speaker = speaker
        self.speed = speed
        self.session = session
    }

    public func prepare() async throws {
        try await session.prepare(binaryPath: binaryPath, speaker: speaker)
    }

    /// Neurokõne is Estonian-only; `languageCode` is accepted for `TextSpeaking` compatibility.
    public func speak(_ text: String, languageCode _: String) async throws {
        try await session.prepare(binaryPath: binaryPath, speaker: speaker)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ezeesti-nk-\(UUID().uuidString).wav")

        try await session.synthesize(
            text: text,
            outURL: outURL,
            speaker: speaker,
            speed: speed
        )

        try await WavPlayer.play(url: outURL)
        do {
            try FileManager.default.removeItem(at: outURL)
        } catch {
            // Best-effort temp cleanup after playback.
        }
    }
}

/// Plays a WAV once on the main actor, retaining the player until playback finishes.
@MainActor
enum WavPlayer {
    static func play(url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                let session = PlaybackSession(player: player, continuation: continuation)
                PlaybackRegistry.insert(session)
                player.delegate = session
                guard player.play() else {
                    PlaybackRegistry.remove(session)
                    throw EzeestiError.ttsFailed("AVAudioPlayer failed to start")
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Keeps in-flight `AVAudioPlayer` sessions alive until their delegate fires.
@MainActor
private enum PlaybackRegistry {
    private static var sessions: [ObjectIdentifier: PlaybackSession] = [:]

    static func insert(_ session: PlaybackSession) {
        sessions[ObjectIdentifier(session)] = session
    }

    static func remove(_ session: PlaybackSession) {
        sessions[ObjectIdentifier(session)] = nil
    }
}

@MainActor
private final class PlaybackSession: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private var continuation: CheckedContinuation<Void, Error>?

    init(player: AVAudioPlayer, continuation: CheckedContinuation<Void, Error>) {
        self.player = player
        self.continuation = continuation
        super.init()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(flag ? .success(()) : .failure(EzeestiError.ttsFailed("Playback failed")))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(.failure(error ?? EzeestiError.ttsFailed("Decode error")))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        PlaybackRegistry.remove(self)
        continuation.resume(with: result)
    }
}
