import Foundation

/// Formats no reader here understands, turned into one it does.
///
/// Word 97–2003 documents come out of the Cocoa text system on a Mac, but a `.ppt` (a binary PowerPoint) and a `.xls`
/// (a binary spreadsheet) are OLE compound files that nothing on any of these three systems parses. LibreOffice does,
/// headless and in a second or two a file, and writes a PDF: then the text, the rendered pages and the words inside
/// them all arrive through the PDF path that already exists.
///
/// Off unless a converter is named (`DIGUP_SOFFICE`, or `soffice` on the PATH), the same way the transcriber is: a
/// tool this app doesn't ship shouldn't be a requirement for using it.
public struct OfficeConverter: Sendable {
    public let tool: URL
    /// One file's worth of patience. A 4-slide deck took 1.9 s on an M1 Max (measured 2026-10-18, LibreOffice 26.8).
    public let timeout: TimeInterval

    public init(tool: URL, timeout: TimeInterval = 180) {
        self.tool = tool
        self.timeout = timeout
    }

    public static let toolVariable = "DIGUP_SOFFICE"

    /// What the environment names, or a `soffice` this machine already has. Nil: no conversion, and the formats below
    /// are skipped as they were before.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> OfficeConverter? {
        if let chosen = environment[toolVariable], !chosen.isEmpty {
            return FileManager.default.isExecutableFile(atPath: chosen)
                ? OfficeConverter(tool: URL(fileURLWithPath: chosen)) : nil
        }
        return detect()
    }

    /// The places `soffice` is installed to: Homebrew's two prefixes, then the cask's app bundle, then the PATH.
    public static func detect() -> OfficeConverter? {
        let candidates = ["/opt/homebrew/bin/soffice", "/usr/local/bin/soffice",
                          "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return OfficeConverter(tool: URL(fileURLWithPath: path))
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for folder in path.split(separator: ":") {
            let candidate = "\(folder)/soffice"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return OfficeConverter(tool: URL(fileURLWithPath: candidate))
            }
        }
        return nil
    }

    /// `url` turned into `format` ("pdf", "xlsx", "pptx") inside `folder`, which is where the caller wants it.
    ///
    /// LibreOffice writes its output into `--outdir` under the source's own stem, so the file comes back by that name:
    /// the caller's folder is per-file, so nothing collides.
    @discardableResult
    public func convert(_ url: URL, to format: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(format)
        let process = Process()
        process.executableURL = tool
        // A profile of its own, so a LibreOffice someone is using doesn't make this one wait or fail.
        process.arguments = ["--headless", "--norestore", "--nolockcheck", "--nodefault",
                             "-env:UserInstallation=file://\(folder.appendingPathComponent("profile").path)",
                             "--convert-to", format, "--outdir", folder.path, url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); throw ExtractError.unreadable("conversion timed out") }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path)
        else { throw ExtractError.unreadable("converter failed (\(process.terminationStatus))") }
        return out
    }

    /// A presentation turned into the pictures of its slides: one image per page, numbered from 1, for the reader that
    /// looks at pictures (`pageImage`). A slide's own text arrives from `OfficeText` with its speaker notes, which a
    /// PDF export leaves out, so the two together cover what a deck says and what it shows.
    ///
    /// The frames are what the deck looks like, and a chart or a diagram on one is only findable as a picture: a
    /// search for "the gantt chart" has nothing else to match.
    func slidePictures(of url: URL, pixels: Int, maxPages: Int, into folder: URL) throws -> [MediaPiece] {
        guard maxPages > 0 else { return [] }
        let pdf = try convert(url, to: "pdf", in: folder.appendingPathComponent("pdf"))
        var pieces: [MediaPiece] = []
        var number = 1
        while number <= maxPages {
            let out = folder.appendingPathComponent(String(format: "slide-%04d.jpg", number))
            do {
                try PDFExtractor.renderPage(number, of: pdf, pixels: pixels, to: out)
            } catch {
                break   // past the last page: a deck has as many as it has
            }
            pieces.append(MediaPiece(path: out.path, start: Double(number), end: Double(number)))
            number += 1
        }
        return pieces
    }

    /// The formats `DocExtractor` can't read but this can, and what to turn each into.
    ///
    /// Word is here only off a Mac: the Cocoa text system reads a `.doc` and does it better than a conversion (the
    /// words stay where they were, and no LibreOffice is needed).
    public static func target(for ext: String) -> String? {
        switch ext.lowercased() {
        case "ppt": return "pdf"      // text, rendered slides and the words inside them, all through the PDF path
        case "xls": return "xlsx"     // cells, through the reader the modern format already has
        #if os(macOS)
        // The Cocoa text system reads a Word 97–2003 document itself, and reproduces its words better than a
        // conversion does; there's nothing to convert for.
        default: return nil
        #else
        // No Cocoa text system here: a Word 97–2003 document is one conversion away from the reader docx has.
        case "doc": return "docx"
        default: return nil
        #endif
        }
    }
}
