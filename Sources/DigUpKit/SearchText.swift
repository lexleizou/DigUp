import Foundation

/// Text the way keyword search keeps it and matches it, so that a word is found however it was typed or extracted.
public enum SearchText {
    /// NFKC (Arabic presentation forms and ligatures become plain letters, full-width becomes ASCII, and Bengali's
    /// two spellings of "ো" become one), invisible formatting characters dropped (Bengali's zero-width joiners,
    /// direction marks), and Arabic the way people type it: no tatweel, no short-vowel marks, one alef.
    public static func normalized(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        for scalar in compatible.unicodeScalars {
            switch scalar.value {
            case 0x200B: scalars.append(" ")   // zero-width space: a word break (Thai, Khmer)
            case 0x00AD, 0x061C, 0x200C...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
                continue                         // joiners, direction marks, soft hyphen, BOM
            case 0x0640, 0x064B...0x065F, 0x0670:
                continue                         // tatweel; harakat and the dagger alef
            case 0x0622, 0x0623, 0x0625, 0x0671:
                scalars.append("\u{0627}")       // alef with hamza or madda, wasla → alef
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// True for words of scripts that attach endings to words (Bengali, Hindi, Arabic): keyword search matches them as
    /// prefixes, so "কুমির" finds "কুমিরও" and "مدرس" finds "مدرسة".
    public static func inflects(_ word: String) -> Bool {
        word.unicodeScalars.contains { Script.indic.contains($0.value) || Script.arabic.contains($0.value) }
    }

    /// True for a character of a script written without spaces between words: Chinese, Japanese and Korean. The
    /// tokenizer splits on spaces, so a run of them reaches it as one word and a search for part of it finds nothing:
    /// `indexable` cuts the run into its overlapping pairs instead.
    ///
    /// Only Han is listed. Kana and Hangul are left out on purpose: a search for "東京" has to find "東京都" (Han
    /// runs, cut here), and a search for a Korean word has to find it inside a longer one, which `inflects` already
    /// does for the scripts it covers. Cutting Kana and Hangul would also change what `matches` highlights for them,
    /// where the prefix rule already gives the whole word. Measured on 2026-10-17: a Han run of 700,000 characters
    /// indexed as pairs is 12 MB against 2 MB as one word, and an English index is the same size either way.
    static func joinsWords(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,        // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,        // CJK Unified Ideographs
             0xF900...0xFAFF: true   // CJK Compatibility Ideographs
        case 0x20000...0x3FFFF: true  // CJK Unified Ideographs Extension B and later
        default: false
        }
    }

    /// True when `word` has a Han character, so keyword search stores and looks it up as pairs (`indexable`).
    static func cutsInPairs(_ word: String) -> Bool {
        word.unicodeScalars.contains(where: joinsWords)
    }

    /// `text` the way keyword search stores it: a run of Han characters becomes its overlapping pairs, so "验收报告"
    /// is stored as "验收 收报 报告" and a search for any part of it finds the whole. Everything else is left as it is,
    /// including Latin, digits, spaces and punctuation.
    ///
    /// A run of one character stays itself: it has no pair. That is the one thing this can't find, and the reason
    /// `terms` keeps asking for two characters.
    ///
    /// Called on text `normalized` has already NFKC-folded, so full-width Latin is ASCII by then and every Han
    /// character is one scalar.
    public static func indexable(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var run: [Unicode.Scalar] = []
        // Whether a word is already written, so that what follows it gets the space the tokenizer needs: without it
        // "PDF报告" stayed one word and "报告" found nothing.
        var wroteWord = false
        // Starts a new word: a space before it when the text already wrote one. Han pairs are separate words.
        func startWord() {
            if wroteWord { out.append(" ") }
            wroteWord = true
        }
        func flush() {
            switch run.count {
            case 0: break
            case 1:
                startWord()
                out.append(run[0])
            default:
                for index in 0..<(run.count - 1) {
                    startWord()
                    out.append(run[index])
                    out.append(run[index + 1])
                }
            }
            run.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            if joinsWords(scalar) {
                run.append(scalar)
                continue
            }
            flush()
            if CharacterSet.alphanumerics.contains(scalar) {
                // A letter or digit right after another one continues the same word; one right after Han or
                // punctuation starts a new one.
                if !wroteWord || out.last.map({ !CharacterSet.alphanumerics.contains($0) }) == true {
                    startWord()
                }
                out.append(scalar)
                wroteWord = true
            } else {
                // A space, a comma, a full stop: already a separator, so it ends the word it follows.
                out.append(scalar)
                wroteWord = false
            }
        }
        flush()
        return String(out)
    }

    /// Whether text says something in words: at least a fifth of what isn't space is letters (marks count, such as
    /// Bengali vowel signs). A data dump or a table of numbers isn't, and gets keyword search only: a meaning vector of
    /// digits matches nothing anyone would describe. On the testbed (2026-10-09) real pages and chunks had 30% letters
    /// or more; a 970,000-character dump of numbers saved as .txt had none, and would have been 607 vectors.
    public static func hasWords(_ text: String) -> Bool {
        var letters = 0, others = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if CharacterSet.letters.contains(scalar) { letters += 1 } else { others += 1 }
        }
        return letters > 0 && letters * 4 >= others
    }

    /// Where `word` is in `text` as keyword search would find it (normalized, ignoring case and accents), as ranges of
    /// the text as it's written: whole words, and for a word of a language that attaches endings, the whole word it
    /// starts ("কুমির" marks all of "কুমিরের"). For marking matches on what's shown (it never splits a letter from its
    /// vowel sign).
    public static func matches(of word: String, in text: String) -> [Range<String.Index>] {
        let needle = normalized(word).lowercased()
        guard !needle.isEmpty else { return [] }
        let folded = Folded(text)
        let haystack = folded.text as NSString
        // A Han word is part of a longer run of them as often as a Bengali word takes an ending, and for the same
        // reason: there is no space to stop at. So there is no whole-word boundary to check on either side: "验收" is
        // in "项目验收报告" and the run it starts is the whole word to mark.
        let han = cutsInPairs(word)
        let prefix = inflects(word) || han
        var found: [Range<String.Index>] = []
        var searchRange = NSRange(location: 0, length: haystack.length)
        while found.count < 500 {
            let hit = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            guard hit.location != NSNotFound else { break }
            searchRange = NSRange(location: hit.upperBound, length: haystack.length - hit.upperBound)
            guard var range = folded.original(hit) else { continue }
            if !han, range.lowerBound > text.startIndex, isWordCharacter(text[text.index(before: range.lowerBound)]) {
                continue
            }
            if range.upperBound < text.endIndex, isWordCharacter(text[range.upperBound]) {
                guard prefix else { continue }
                var end = range.upperBound
                while end < text.endIndex, isWordCharacter(text[end]) { end = text.index(after: end) }
                range = range.lowerBound..<end
            }
            if let last = found.last, last.overlaps(range) { continue }
            found.append(range)
        }
        return found
    }

    /// One line from `text` around the first of `terms` it has, the terms marked « » as SQLite's snippet() marks them:
    /// the excerpt of a keyword match, from the text as it's written. Nil when none of the terms is in it.
    public static func snippet(_ text: String, terms: [String], words: Int = 12) -> String? {
        let marks = terms.flatMap { matches(of: $0, in: text) }.sorted { $0.lowerBound < $1.lowerBound }
        guard let first = marks.first else { return nil }
        // About `words` words, starting a few before the first match.
        var start = first.lowerBound, before = 0
        while start > text.startIndex, before < words / 3 {
            start = text.index(before: start)
            if text[start].isWhitespace, start < first.lowerBound, !text[text.index(after: start)].isWhitespace {
                before += 1
            }
        }
        if start > text.startIndex || text[start].isWhitespace { start = text.index(after: start) }
        var end = first.upperBound, after = 0
        while end < text.endIndex, after < words - before {
            if text[end].isWhitespace { after += 1 }
            end = text.index(after: end)
        }
        var out = start > text.startIndex ? "…" : ""
        var cursor = start
        for mark in marks where mark.lowerBound >= start && mark.upperBound <= end && mark.lowerBound >= cursor {
            out += text[cursor..<mark.lowerBound] + "«" + text[mark] + "»"
            cursor = mark.upperBound
        }
        out += text[cursor..<end] + (end < text.endIndex ? "…" : "")
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// `text` normalized one character at a time, remembering where each piece came from.
    private struct Folded {
        let text: String
        /// For each UTF-16 unit of `text`, the original character it came from.
        private let origin: [String.Index]
        private let source: String

        init(_ source: String) {
            self.source = source
            var text = "", origin: [String.Index] = []
            var index = source.startIndex
            for character in source {
                let piece = normalized(String(character)).lowercased()
                text += piece
                origin += Array(repeating: index, count: piece.utf16.count)
                index = source.index(after: index)
            }
            self.text = text
            self.origin = origin
        }

        /// The characters of the source that `range` (in `text`) came from.
        func original(_ range: NSRange) -> Range<String.Index>? {
            guard range.length > 0, range.upperBound <= origin.count else { return nil }
            let first = origin[range.location], last = origin[range.upperBound - 1]
            return first..<source.index(after: last)
        }
    }
}

/// Words to search for in a PDF so its page is among the matches (Preview, opened the way Spotlight opens documents,
/// fills its search with them and lists the matches by page).
public enum Landmark {
    /// `texts`: the PDF's own text (what the app searches, as PDFKit reads it) of pages 1 through `page`. The first of
    /// `words` that's on that page, spelled as the page spells it, preferring one that isn't on an earlier page. Nil for
    /// page 1 (it opens there anyway), or when none of the words is on it.
    public static func find(page: Int, texts: [String], words: [String]) -> String? {
        guard page > 1, texts.count >= page else { return nil }
        let target = texts[page - 1]
        let before = texts.prefix(page - 1).map { SearchText.normalized($0).lowercased() }
        let onPage = words.filter { $0.count >= 3 }.compactMap { word in
            SearchText.matches(of: word, in: target).first.map { String(target[$0]) }
        }
        return onPage.first { word in !before.contains { $0.contains(SearchText.normalized(word).lowercased()) } }
            ?? onPage.first
    }
}

enum Script {
    static let indic: ClosedRange<UInt32> = 0x0900...0x0DFF
    static let arabic: ClosedRange<UInt32> = 0x0600...0x06FF
}

/// What's wrong with the text PDFKit read from a page, when the page's text layer can't be used as it is.
enum PageTextProblem: Equatable {
    /// Bengali or Hindi read in glyph order: vowel signs ahead of their consonants, conjuncts lost ("চুক্তিপত্র" reads
    /// "চিপ"). PDFKit reads most Bengali PDFs this way, whatever made them (Quartz, WebKit, Chrome). The page is used
    /// as a picture instead (Apple's OCR doesn't read Bengali).
    case glyphOrder
    /// Arabic letters lost where the font drew a lam ligature: the article's lam goes with the ligature, leaving a bare
    /// alef before a "?" or "." ("الأردن" reads "ا?ردن", "المبيعات" "ا.بيعات"). The page is read again by OCR. A bare
    /// alef, not أ: "أ.د." (Prof. Dr.) and "ذ.م.م" (LLC) are real abbreviations.
    case lostLetters

    static func check(_ text: String) -> PageTextProblem? {
        let text = text.precomposedStringWithCanonicalMapping
        var vowelSigns = 0, misplaced = 0, lostLetters = 0
        var previous: Unicode.Scalar = " ", beforePrevious: Unicode.Scalar = " "
        for scalar in text.unicodeScalars {
            if isIndicVowelSign(scalar.value) {
                vowelSigns += 1
                if !isIndicConsonantOrNukta(previous.value) { misplaced += 1 }
            }
            if beforePrevious == "\u{0627}", "?.\u{FFFD}".unicodeScalars.contains(previous),
               Script.arabic.contains(scalar.value), scalar.properties.isAlphabetic {
                lostLetters += 1
            }
            beforePrevious = previous
            previous = scalar
        }
        if vowelSigns >= 10, misplaced * 20 >= vowelSigns { return .glyphOrder }
        if lostLetters >= 2 { return .lostLetters }
        return nil
    }

    /// Dependent vowel signs of Bengali and Devanagari: in a real word, each follows a consonant (or its nukta).
    private static func isIndicVowelSign(_ value: UInt32) -> Bool {
        switch value {
        case 0x09BE...0x09C4, 0x09C7, 0x09C8, 0x09CB, 0x09CC, 0x09D7, 0x09E2, 0x09E3: true
        case 0x093A, 0x093B, 0x093E...0x094C, 0x094E, 0x094F, 0x0955...0x0957, 0x0962, 0x0963: true
        default: false
        }
    }

    private static func isIndicConsonantOrNukta(_ value: UInt32) -> Bool {
        switch value {
        case 0x0995...0x09B9, 0x09BC, 0x09CE, 0x09DC, 0x09DD, 0x09DF, 0x09F0, 0x09F1: true
        case 0x0915...0x0939, 0x093C, 0x0958...0x095F, 0x0979...0x097F: true
        default: false
        }
    }
}
