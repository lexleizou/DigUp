import Foundation

/// What was said in a recording, as words, for keyword search.
///
/// A sound vector answers "which recording is about food"; it can't answer "which one says 张三". The words can, and
/// they're what a transcript is for: the audio window keeps its vector (how it sounds) and gains text (what it says),
/// so both searches reach the same moment of the same file.
public protocol Transcriber: Sendable {
    /// The words of one audio window (16 kHz mono WAV, 30 s at most), or nil when there was nothing to write down or
    /// the server couldn't be reached. Never throws: one window that can't be read isn't a reason to fail the file.
    func text(ofWindowAt url: URL) -> String?
}

/// A speech-to-text server on this machine, over the OpenAI-compatible `/v1/audio/transcriptions` interface that
/// oMLX, LM Studio and whisper.cpp's server all speak (`POST` multipart, JSON back).
///
/// Local on purpose: a recording is the one thing here whose text can't be recovered from the file, and sending it
/// somewhere to be written down would break the promise the rest of the app keeps (`README`, "Private").
public struct LocalTranscriber: Transcriber {
    public let endpoint: URL
    /// The name the server knows it by ("Qwen3-ASR-1.7B-bf16"). Some servers ignore it and use the loaded model.
    public let model: String
    /// Sent as `Authorization: Bearer` when set: servers started with an API key need it.
    public let apiKey: String?
    /// One window's worth of patience. A 30 s window took 1.7 s on an M1 Max (measured 2026-10-17, Qwen3-ASR-1.7B);
    /// the default leaves room for a slower machine and a first call that loads the model.
    public let timeout: TimeInterval

    public init(endpoint: URL, model: String, apiKey: String? = nil, timeout: TimeInterval = 120) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
    }

    /// The settings the app and the CLI read, so both mean the same thing by them. Unset: no transcription, which is
    /// how DigUp ships (recordings are searched by how they sound).
    public static let endpointVariable = "DIGUP_ASR_URL"
    public static let modelVariable = "DIGUP_ASR_MODEL"
    public static let keyVariable = "DIGUP_ASR_KEY"

    /// What the environment says to use, or nil when it names no server. An endpoint without a model asks the server
    /// what it has (`/v1/models`), so one variable is enough to turn this on.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> LocalTranscriber? {
        guard let url = environment[endpointVariable].flatMap({ URL(string: $0) }), !environment[endpointVariable]!.isEmpty
        else { return nil }
        let model = environment[modelVariable].flatMap { $0.isEmpty ? nil : $0 } ?? firstModel(at: url) ?? "whisper-1"
        return LocalTranscriber(endpoint: url, model: model, apiKey: environment[keyVariable])
    }

    /// The first model the server offers, for when nothing named one. Nil when it can't be asked.
    static func firstModel(at endpoint: URL) -> String? {
        let base = endpoint.deletingLastPathComponent().deletingLastPathComponent()
        guard let url = URL(string: base.absoluteString + "/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let data = send(request), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return nil }
        // A speech server may offer more than one model; the one that names a recognizer is the one to ask.
        let names = models.compactMap { $0["id"] as? String }
        return names.first { $0.lowercased().contains("asr") || $0.lowercased().contains("whisper") } ?? names.first
    }

    public func text(ofWindowAt url: URL) -> String? {
        guard let audio = try? Data(contentsOf: url), !audio.isEmpty else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        let boundary = "DigUp-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"window.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        guard let data = Self.send(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        // Servers write filler and noise as bracketed or parenthesised fragments ("[BLANK_AUDIO]", "(music)"):
        // they're not words anyone searches for.
        let cleaned = text.replacingOccurrences(of: #"^\s*[\[(][^\])]*[\])]\s*$"#, with: "", options: .regularExpression)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// A request, waited for. The indexer is synchronous and one thread at a time; a session per call keeps the
    /// transcriber `Sendable` without a lock.
    private static func send(_ request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            result = data
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + (request.timeoutInterval + 5))
        session.invalidateAndCancel()
        return result
    }
}
