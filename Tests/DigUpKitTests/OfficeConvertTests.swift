import Foundation
import Testing
@testable import DigUpKit

@Suite struct OfficeConvertTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpConvert-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func binaryOfficeFilesAreDocumentsNow() {
        for name in ["a.ppt", "a.xls", "A.PPT", "A.XLS"] {
            #expect(Rules.classify(file(name), values: nil, options: IndexOptions()) == .index(.doc))
        }
    }

    @Test func whatEachFormatBecomes() {
        #expect(OfficeConverter.target(for: "ppt") == "pdf")     // pages, pictures and words in one go
        #expect(OfficeConverter.target(for: "xls") == "xlsx")    // cells, read by `OfficeText`
        #expect(OfficeConverter.target(for: "pptx") == nil)      // already read here
        #expect(OfficeConverter.target(for: "xlsx") == nil)
        #expect(OfficeConverter.target(for: "txt") == nil)
        // Word is the Cocoa text system's job on a Mac, and a conversion elsewhere.
        #if os(macOS)
        #expect(OfficeConverter.target(for: "doc") == nil)
        #else
        #expect(OfficeConverter.target(for: "doc") == "docx")
        #endif
    }

    @Test func noConverterUnlessOneIsNamed() {
        // A path that isn't executable is not a converter, so nothing tries to run it.
        #expect(OfficeConverter.fromEnvironment([OfficeConverter.toolVariable: "/nope/soffice"]) == nil)
        // Nothing named: whatever `soffice` this machine has, or none.
        let detected = OfficeConverter.fromEnvironment([:])
        #expect((detected != nil) == (OfficeConverter.detect() != nil))
    }

    @Test func aBinaryFileIsSkippedWhenNothingCanConvertIt() throws {
        // No converter: the file is a document that can't be read, which is the status it had before.
        let url = folder.appendingPathComponent("deck.ppt")
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0, 0, 0]).write(to: url)
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([folder.appendingPathComponent(".")])
        _ = try indexer.run()
        // No converter, no words: the file is in the index by name and by nothing else, as it was before.
        var words = 0
        try store.db.query("""
            SELECT COUNT(*) FROM fts JOIN segments s ON s.id = fts.rowid JOIN files f ON f.id = s.file
            WHERE f.path LIKE '%.ppt' AND s.kind != 'name'
            """) { words = Int($0.int(0)) }
        #expect(words == 0)
    }

    @Test func aConverterThatIsThereConverts() throws {
        // Only when this machine has one: the test says what the code does, not what it should install.
        guard let converter = OfficeConverter.detect() else { return }
        let pdf = try converter.convert(Self.sampleDeck, to: "pdf", in: folder.appendingPathComponent("out"))
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        #expect(pdf.pathExtension == "pdf")
        let size = (try? FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int64) ?? 0
        #expect(size > 1_000)
    }

    /// A deck LibreOffice can convert, in the one format every Mac can read: `.fodp` is a flat ODF presentation.
    static let sampleDeck: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigUpConvert-sample-\(UUID().uuidString).fodp")
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
             xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
             xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"
             office:mimetype="application/vnd.oasis.opendocument.presentation">
             <office:body><office:presentation><draw:page draw:name="p1">
              <draw:frame><draw:text-box><text:p>Quarterly budget</text:p></draw:text-box></draw:frame>
             </draw:page></office:presentation></office:body>
            </office:document>
            """
        try? Data(xml.utf8).write(to: url)
        return url
    }()

    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
}
