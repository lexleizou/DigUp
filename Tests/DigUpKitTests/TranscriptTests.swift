import Foundation
import Testing
@testable import DigUpKit

@Suite struct TranscriptTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTranscript-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A transcriber that says what it's told to, and remembers what it was asked.
    final class Fake: Transcriber, @unchecked Sendable {
        let lines: [String?]
        private(set) var asked: [String] = []
        private let lock = NSLock()

        init(_ lines: [String?]) { self.lines = lines }

        func text(ofWindowAt url: URL) -> String? {
            lock.lock(); defer { lock.unlock() }
            let index = asked.count
            asked.append(url.lastPathComponent)
            return index < lines.count ? lines[index] : nil
        }
    }

    /// An audio file the indexer will read as a window: 3 s of a quiet tone, above the silence floor.
    private func writeWAV(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let samples = (0..<(3 * 16_000)).map { Int16((sin(Double($0) / 20.0) * 3000).rounded()) }
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(16); append16(1); append16(1)
        append(16_000); append(32_000); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count * 2))
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        try data.write(to: url)
        return url
    }

    @Test func whatIsSaidIsSearchableAndOpensAtItsMoment() throws {
        let source = try writeWAV("meeting.wav")
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        indexer.transcriber = Fake(["今天开会讨论数字孪生二期项目，张三负责网络拓扑设计。"])
        _ = try indexer.sync([folder])
        try indexer.run()

        let searcher = try Searcher(store: store, loadVectors: false)
        let hits = try searcher.search("张三", queryVector: nil)
        // The walk reports /private/var where the temp folder is /var (the two spellings the store handles).
        #expect(hits.count == 1)
        #expect(hits.first?.path.hasSuffix("/meeting.wav") == true)
        #expect(hits.first?.kind == .audio)
        // The moment, not just the file: the window it was said in.
        #expect(hits.first?.loc == 0)
        #expect(hits.first?.excerpt?.contains("张三") == true)
    }

    @Test func aWindowNobodyCouldReadStillIndexesByHowItSounds() throws {
        let source = try writeWAV("noise.wav")
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        // The server was down, or the window was music: no words, and the file is not a failure.
        indexer.transcriber = Fake([nil])
        _ = try indexer.sync([folder])
        let states = try indexer.run()

        #expect(states["done"] == 1)   // not a failure: the sound vector is enough
        _ = source
        let searcher = try Searcher(store: store, loadVectors: false)
        #expect(try searcher.search("张三", queryVector: nil).isEmpty)
        var vectors = 0
        try store.db.query("SELECT COUNT(vec) FROM segments WHERE kind = 'audio'") { vectors = Int($0.int(0)) }
        #expect(vectors == 1)   // the sound vector is there either way
    }

    @Test func withNoTranscriberRecordingsAreUnchanged() throws {
        let source = try writeWAV("plain.wav")
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([folder])   // no `transcriber`: how DigUp ships
        _ = try indexer.run()

        var words = 0
        try store.db.query("""
            SELECT COUNT(*) FROM fts JOIN segments s ON s.id = fts.rowid WHERE s.kind = 'audio'
            """) { words = Int($0.int(0)) }
        #expect(words == 0)
        _ = source
    }

    @Test func theEnvironmentNamesTheServer() {
        #expect(LocalTranscriber.fromEnvironment([:]) == nil)
        #expect(LocalTranscriber.fromEnvironment([LocalTranscriber.endpointVariable: ""]) == nil)
        let chosen = LocalTranscriber.fromEnvironment([
            LocalTranscriber.endpointVariable: "http://127.0.0.1:8000/v1/audio/transcriptions",
            LocalTranscriber.modelVariable: "Qwen3-ASR-1.7B-bf16",
            LocalTranscriber.keyVariable: "sk-local",
        ])
        #expect(chosen?.endpoint.absoluteString == "http://127.0.0.1:8000/v1/audio/transcriptions")
        #expect(chosen?.model == "Qwen3-ASR-1.7B-bf16")
        #expect(chosen?.apiKey == "sk-local")
    }

    @Test func aServerThatIsNotThereIsNotAFailure() throws {
        // Nothing listens here: the file indexes by sound alone, and nothing throws.
        let transcriber = LocalTranscriber(endpoint: URL(string: "http://127.0.0.1:9/v1/audio/transcriptions")!,
                                           model: "none", timeout: 1)
        let url = try writeWAV("unreachable.wav")
        #expect(transcriber.text(ofWindowAt: url) == nil)
    }
}
