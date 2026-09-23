import Foundation
import PDFKit
import Vision
import AVFoundation
import UniformTypeIdentifiers
import AppKit

/// What code knows about a file before Jev sees it. Everything here is extracted
/// locally; the model only ever receives this struct, never the file.
struct Evidence: Codable {
    var filename: String
    var ext: String
    var uti: String?
    var sizeBytes: Int64
    var sourceURL: String?
    var sourceHost: String?
    var referrerURL: String?

    var pdfTitle: String?
    var pdfAuthor: String?
    var pageCount: Int?
    var textExcerpt: String?

    var archiveEntries: [String]?
    var archiveEntryCount: Int?

    var imageWidth: Int?
    var imageHeight: Int?
    var ocrText: String?
    /// On-device scene and object labels. For a photo with no filename, no URL and
    /// no text, this is the only thing that says what the image is.
    var imageLabels: [ImageLabel]?
    var faceCount: Int?

    /// Candidate filenames built in code. Jev selects one; it never invents a name.
    var nameCandidates: [String] = []

    /// Set when the "file" is a folder being filed as one unit.
    var isDirectory: Bool = false
    var fileCount: Int?
    var dominantExtension: String?
}

/// One label from Vision's 1303-identifier taxonomy, e.g. `jewelry`, `passport`.
struct ImageLabel: Codable, Hashable {
    var label: String
    var confidence: Double
}

enum EvidenceExtractor {

    /// Jaggedness note: large irrelevant state degrades answers, so every field
    /// here is capped hard.
    static let maxExcerptChars = 3500
    static let maxOCRChars = 1200
    static let maxArchiveEntries = 60
    static let maxImageLabels = 8
    static let minLabelConfidence: Float = 0.12

    /// A folder as one item: its name, what it mostly contains, and a sample of
    /// paths inside — the same shape an archive gets, since that is what most
    /// units were before they were unpacked.
    static func extractUnit(from url: URL) -> Evidence {
        let shape = FolderUnit.shape(of: url)
        var evidence = Evidence(filename: url.lastPathComponent, ext: "", sizeBytes: shape.bytes)
        evidence.isDirectory = true
        evidence.fileCount = shape.fileCount
        evidence.dominantExtension = shape.dominantExtension
        evidence.archiveEntries = shape.sample
        evidence.archiveEntryCount = shape.fileCount
        evidence.uti = "public.folder"
        // No rename for a folder: keep its name, minus mirror junk if any.
        evidence.nameCandidates = [BookName.stripped(for: url.lastPathComponent) ?? url.lastPathComponent]
        return evidence
    }

    static func extract(from url: URL) -> Evidence {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let ext = url.pathExtension.lowercased()

        let froms = WhereFroms.read(url)
        var evidence = Evidence(
            filename: url.lastPathComponent,
            ext: ext,
            uti: UTType(filenameExtension: ext)?.identifier,
            sizeBytes: size,
            sourceURL: froms.first,
            sourceHost: WhereFroms.host(from: froms),
            referrerURL: froms.count > 1 ? froms[1] : nil
        )

        switch ext {
        case "pdf":
            enrichPDF(url, into: &evidence)
        case "zip", "jar", "ipa", "aar":
            enrichArchive(url, into: &evidence)
        case "rar", "7z", "tar", "tgz", "tbz", "tbz2", "txz", "xz", "bz2", "gz", "cab", "iso", "cpio", "xar", "lzh":
            // macOS's tar is libarchive, which reads all of these. A RAR used to
            // go to Jev as a bare name: "K-L-1-A-2.rar" scored 27% German, and
            // its listing says "Klett Linie1 A2/Audios/…".
            enrichArchive(url, into: &evidence, tool: "/usr/bin/tar", args: ["-tf", url.path])
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp":
            enrichImage(url, into: &evidence)
        case "rtf":
            enrichViaTextutil(url, into: &evidence)
        case "txt", "md", "markdown", "csv", "json", "jsonl", "yaml", "yml",
             "ics", "vcf", "eml":   // calendar invites, contacts, mail — all plain text
            enrichPlainText(url, into: &evidence)
        case "html", "htm", "xhtml":
            // An emailed invoice is often a saved HTML page. Tags stripped, so the
            // local content check sees "Invoice number" and not a wall of markup.
            enrichHTML(url, into: &evidence)
        case "docx", "xlsx", "pptx":
            // Office Open XML is a zip of XML parts; the words are in a known one.
            enrichOfficeXML(url, into: &evidence)
        case "doc", "odt", "wordml", "webarchive":
            // Legacy binary Word and friends: macOS's own textutil converts them.
            enrichViaTextutil(url, into: &evidence)
        case "mp3", "m4a", "aac", "flac", "wav", "mp4", "mov", "m4v":
            // Media carries its own title/artist/album; that is what routes it.
            enrichMediaMetadata(url, into: &evidence)
        case "epub":
            enrichArchive(url, into: &evidence)   // epub is a zip; the spine names help
        default:
            break
        }

        evidence.nameCandidates = NameCandidates.build(for: url, evidence: evidence)
        return evidence
    }

    // MARK: - Per-type extraction

    private static func enrichPDF(_ url: URL, into evidence: inout Evidence) {
        guard let doc = PDFDocument(url: url) else { return }
        evidence.pageCount = doc.pageCount
        if let attrs = doc.documentAttributes {
            evidence.pdfTitle = attrs[PDFDocumentAttribute.titleAttribute] as? String
            evidence.pdfAuthor = attrs[PDFDocumentAttribute.authorAttribute] as? String
        }

        var text = ""
        for i in 0..<min(doc.pageCount, 3) {
            guard let page = doc.page(at: i), let pageText = page.string else { continue }
            text += pageText + "\n"
            if text.count >= maxExcerptChars { break }
        }
        evidence.textExcerpt = clamp(text, maxExcerptChars)

        // No text layer means a scan — and scans are disproportionately the
        // documents that matter most: a residence permit, a passport page, a
        // signed form. Without OCR they reach the model as "a PDF with nothing
        // in it", which is the worst possible input. Rasterize page one and read
        // it on-device, exactly as an image would be.
        if evidence.textExcerpt == nil, let first = doc.page(at: 0),
           let image = rasterize(first, scale: 2) {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.recognitionLanguages = ["en-US", "de-DE"]
            let classifyRequest = VNClassifyImageRequest()
            try? handler.perform([textRequest, classifyRequest])

            let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            if !lines.isEmpty {
                evidence.ocrText = clamp(lines.joined(separator: "\n"), maxOCRChars)
            }
            let labels = (classifyRequest.results ?? [])
                .filter { $0.confidence >= minLabelConfidence }
                .prefix(maxImageLabels)
                .map { ImageLabel(label: $0.identifier, confidence: Double($0.confidence)) }
            if !labels.isEmpty { evidence.imageLabels = Array(labels) }
        }
    }

    private static func rasterize(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    private static func enrichArchive(_ url: URL, into evidence: inout Evidence,
                                      tool: String = "/usr/bin/unzip", args: [String]? = nil) {
        // No archive reader in Foundation. Both tools list entries without
        // extracting anything.
        guard let data = run(tool, args ?? ["-Z1", url.path], limit: 64 * 1024),
              let listing = decodeText(data) else { return }
        let entries = listing.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }
        evidence.archiveEntryCount = entries.count
        evidence.archiveEntries = Array(entries.prefix(maxArchiveEntries))
    }

    private static func enrichImage(_ url: URL, into evidence: inout Evidence) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        evidence.imageWidth = cgImage.width
        evidence.imageHeight = cgImage.height

        // All three run entirely on-device. Only the derived text and labels ever
        // leave the machine — never the pixels.
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        textRequest.recognitionLanguages = ["en-US", "de-DE"]

        let classifyRequest = VNClassifyImageRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([textRequest, classifyRequest, faceRequest])

        let lines = (textRequest.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        if !lines.isEmpty {
            evidence.ocrText = clamp(lines.joined(separator: "\n"), maxOCRChars)
        }

        let labels = (classifyRequest.results ?? [])
            .filter { $0.confidence >= minLabelConfidence }
            .prefix(maxImageLabels)
            .map { ImageLabel(label: $0.identifier, confidence: Double($0.confidence)) }
        if !labels.isEmpty { evidence.imageLabels = Array(labels) }

        evidence.faceCount = (faceRequest.results ?? []).count
    }

    private static func enrichPlainText(_ url: URL, into evidence: inout Evidence) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxExcerptChars * 2)) ?? Data()
        guard let text = decodeText(data) else { return }
        evidence.textExcerpt = clamp(text, maxExcerptChars)
    }

    /// Decodes bytes that may have been cut mid-character. A byte cap on a
    /// German text lands inside "ü" often enough, and `String(data:encoding:)`
    /// then returns nil for the whole thing — which meant a .docx Kontoauszug
    /// reached the privacy filter with an empty body and was sent. Trim up to
    /// three trailing bytes to the last valid boundary, then fall back.
    static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        for cut in 1...min(3, data.count) {
            if let s = String(data: data.prefix(data.count - cut), encoding: .utf8) { return s }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Runs a local tool with a hard time limit and returns its stdout. Every
    /// reader below is a system binary that ships with macOS; nothing is
    /// installed and nothing leaves the machine.
    ///
    /// The deadline is real: a stuck tool is killed and reaped. The earlier
    /// version checked the clock only between reads, so a tool that produced
    /// nothing blocked the extraction slot forever, and never waited on the
    /// child after terminating it, leaving a zombie per file.
    static func run(_ tool: String, _ arguments: [String],
                    limit: Int, timeout: TimeInterval = 8) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); defer { lock.unlock() }
            if chunk.isEmpty { return }
            if data.count < limit { data.append(chunk) }
        }
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        // Drain what the handler had not yet been called for.
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.lock(); defer { lock.unlock() }
        if data.count < limit { data.append(tail) }
        return data.isEmpty ? nil : data.prefix(limit)
    }

    private static func stripXML(_ raw: String) -> String {
        var text = raw
        // Paragraph and cell boundaries become spaces before the tags go, or
        // "Invoice" and "number" in adjacent runs fuse into "Invoicenumber".
        text = text.replacingOccurrences(of: "</(w:p|w:tab|a:p|t|si|row|c)>|<w:br[^>]*/>",
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "&#[0-9]+;|&[a-z]+;", with: " ", options: .regularExpression)
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// docx: word/document.xml. xlsx: the shared-strings table (where nearly all
    /// cell text lives) then the first sheet. pptx: the first three slides.
    private static func enrichOfficeXML(_ url: URL, into evidence: inout Evidence) {
        let parts: [String]
        switch url.pathExtension.lowercased() {
        case "docx": parts = ["word/document.xml"]
        case "xlsx": parts = ["xl/sharedStrings.xml", "xl/worksheets/sheet1.xml"]
        case "pptx": parts = ["ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/slide3.xml"]
        default:     return
        }
        var text = ""
        for part in parts {
            guard let data = run("/usr/bin/unzip", ["-p", url.path, part], limit: maxExcerptChars * 12),
                  let xml = decodeText(data) else { continue }
            text += stripXML(xml) + " "
            if text.count >= maxExcerptChars { break }
        }
        evidence.textExcerpt = clamp(text, maxExcerptChars)
        // A docx also carries a title in its core properties.
        if let core = run("/usr/bin/unzip", ["-p", url.path, "docProps/core.xml"], limit: 8_000),
           let xml = decodeText(core),
           let range = xml.range(of: "<dc:title>([^<]{3,120})</dc:title>", options: .regularExpression) {
            let title = String(xml[range]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if evidence.pdfTitle == nil { evidence.pdfTitle = title }
        }
    }

    private static func enrichViaTextutil(_ url: URL, into evidence: inout Evidence) {
        guard let data = run("/usr/bin/textutil", ["-stdout", "-convert", "txt", "-encoding", "UTF-8", url.path],
                             limit: maxExcerptChars * 4),
              let text = decodeText(data) else { return }
        evidence.textExcerpt = clamp(text, maxExcerptChars)
    }

    private static func enrichMediaMetadata(_ url: URL, into evidence: inout Evidence) {
        let asset = AVURLAsset(url: url)
        var bits: [String] = []
        for item in asset.commonMetadata {
            guard let key = item.commonKey?.rawValue, let value = item.stringValue, !value.isEmpty else { continue }
            switch key {
            case "title":       bits.append("Title: \(value)"); evidence.pdfTitle = evidence.pdfTitle ?? value
            case "artist", "creator": bits.append("Artist: \(value)"); evidence.pdfAuthor = evidence.pdfAuthor ?? value
            case "albumName":   bits.append("Album: \(value)")
            case "description": bits.append("Description: \(value)")
            default: break
            }
        }
        let seconds = Int(CMTimeGetSeconds(asset.duration))
        if seconds > 0 { bits.append("Duration: \(seconds / 60)m\(seconds % 60)s") }
        if !bits.isEmpty { evidence.textExcerpt = clamp(bits.joined(separator: "\n"), maxExcerptChars) }
    }

    private static func enrichHTML(_ url: URL, into evidence: inout Evidence) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        // Markup is bulky; read more than the excerpt limit so real text survives.
        let data = (try? handle.read(upToCount: maxExcerptChars * 12)) ?? Data()
        guard var text = decodeText(data) else { return }
        text = text.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;|&#160;", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&[a-zA-Z#0-9]+;", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        evidence.textExcerpt = clamp(text, maxExcerptChars)
    }

    private static func clamp(_ text: String, _ limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}

/// Jev does not generate text, so renaming works by selection: code proposes
/// names, the model picks the best one.
enum NameCandidates {

    static func build(for url: URL, evidence: Evidence) -> [String] {
        var candidates: [String] = []
        let ext = url.pathExtension

        func add(_ raw: String?) {
            guard let raw else { return }
            let cleaned = slugify(raw)
            guard cleaned.count >= 3, cleaned.count <= 90 else { return }
            let withExt = ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
            guard !candidates.contains(withExt) else { return }
            candidates.append(withExt)
        }

        // Keeping the original is always an option, and often the right one —
        // but "original" means the original with the mirror junk already off.
        // The raw name is never offered; the cleaned one stands in for it.
        candidates.append(BookName.stripped(for: url.lastPathComponent) ?? url.lastPathComponent)

        // Catalogue-dump names carry the whole record; offer the tidy spellings.
        for candidate in BookName.candidates(for: url.lastPathComponent)
        where !candidates.contains(candidate) {
            candidates.append(candidate)
        }

        add(evidence.pdfTitle)
        add(firstHeading(of: evidence.textExcerpt))
        add(firstHeading(of: evidence.ocrText))
        add(sourceSlug(evidence.sourceURL))

        if let author = evidence.pdfAuthor, let title = evidence.pdfTitle {
            add("\(author) - \(title)")
        }

        return Array(candidates.prefix(6))
    }

    /// First line that reads like a title rather than boilerplate.
    private static func firstHeading(of text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n").prefix(12) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*_ "))
            guard trimmed.count >= 8, trimmed.count <= 90 else { continue }
            // Skip lines that are mostly digits or punctuation.
            let letters = trimmed.filter { $0.isLetter }.count
            guard letters > trimmed.count / 2 else { continue }
            return trimmed
        }
        return nil
    }

    private static func sourceSlug(_ source: String?) -> String? {
        guard let source, let url = URL(string: source) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name.removingPercentEncoding ?? name
    }

    static func slugify(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\t"))
            .joined(separator: " ")
        let parts = collapsed.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
