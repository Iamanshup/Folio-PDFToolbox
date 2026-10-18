import AppKit
import CoreGraphics
import PDFKit
import Quartz

enum ToolError: LocalizedError {
    case open(String)
    case locked(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .open(let name): return "Couldn’t open “\(name)”. It may be damaged — try Repair PDF."
        case .locked(let name): return "“\(name)” is password protected. Enter its password or unlock it first."
        case .message(let m): return m
        }
    }
}

/// Low-level helpers shared by every tool.
enum PDFCore {
    static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ToolError.open(url.lastPathComponent) }
        if doc.isLocked {
            if let password, !password.isEmpty, doc.unlock(withPassword: password) { return doc }
            throw ToolError.locked(url.lastPathComponent)
        }
        return doc
    }

    static func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any]? = nil) throws {
        let ok = options.map { doc.write(to: url, withOptions: $0) } ?? doc.write(to: url)
        if !ok { throw ToolError.message("Failed to write \(url.lastPathComponent).") }
    }

    static func normalizedRotation(_ r: Int) -> Int { ((r % 360) + 360) % 360 }

    /// Size of the page as displayed (crop box with rotation applied).
    static func uprightSize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        return normalizedRotation(page.rotation) % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    // MARK: Coordinate conversion
    // "Upright" coordinates: points, origin top-left of the page as displayed. Used by all editors.

    static func pageToUpright(_ rect: CGRect, page: PDFPage) -> CGRect {
        let size = uprightSize(page)
        let r = rect.applying(page.transform(for: .cropBox))
        return CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
    }

    static func uprightToPage(_ rect: CGRect, page: PDFPage) -> CGRect {
        let size = uprightSize(page)
        let bl = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        return bl.applying(page.transform(for: .cropBox).inverted())
    }

    // MARK: Rendering

    /// Renders a page (upright) into a bitmap.
    static func image(of page: PDFPage, scale: CGFloat, maxPixels: CGFloat = 6000) -> CGImage? {
        let size = uprightSize(page)
        var s = scale
        if max(size.width, size.height) * s > maxPixels { s = maxPixels / max(size.width, size.height) }
        let w = max(1, Int(size.width * s)), h = max(1, Int(size.height * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s, y: s)
        page.draw(with: .cropBox, to: ctx) // applies the page's rotation itself
        return ctx.makeImage()
    }

    /// Runs `body` with the context flipped to upright top-left coordinates and an AppKit context installed.
    static func topLeft(_ ctx: CGContext, _ size: CGSize, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    typealias PageDrawer = (_ index: Int, _ page: PDFPage, _ ctx: CGContext, _ size: CGSize) -> Void

    /// Re-draws every page of `doc` into a new PDF. Text and vectors are preserved; annotations are flattened.
    /// `under`/`over` draw in upright top-left coordinates. `rasterizeDPI` returns a DPI for pages that must
    /// be converted to images (e.g. redaction), or nil to keep the page vector.
    static func render(_ doc: PDFDocument, to url: URL,
                       info extra: [CFString: Any] = [:],
                       keepInfo: Bool = true,
                       metadata: Data? = nil,
                       under: PageDrawer? = nil,
                       over: PageDrawer? = nil,
                       rasterizeDPI: ((Int) -> CGFloat?)? = nil,
                       progress: JobProgress? = nil) throws {
        var info: [CFString: Any] = [kCGPDFContextCreator: "Folio"]
        let attrs = keepInfo ? (doc.documentAttributes ?? [:]) : [:]
        if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle] = t }
        if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor] = a }
        for (k, v) in extra { info[k] = v }
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw ToolError.message("Couldn’t create \(url.lastPathComponent).")
        }
        if let metadata { ctx.addDocumentMetadata(metadata as CFData) }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            progress?.update("Processing page \(i + 1) of \(doc.pageCount)…", Double(i) / Double(max(doc.pageCount, 1)))
            let size = uprightSize(page)
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            if let under { topLeft(ctx, size) { under(i, page, ctx, size) } }
            if let dpi = rasterizeDPI?(i) {
                // Draw over with overlays first, then rasterize so covered content is truly gone.
                if let img = rasterized(page, size: size, dpi: dpi, over: over.map { o in { c, s in o(i, page, c, s) } }) {
                    ctx.draw(img, in: box)
                }
            } else {
                ctx.saveGState()
                page.draw(with: .cropBox, to: ctx)
                ctx.restoreGState()
                if let over { topLeft(ctx, size) { over(i, page, ctx, size) } }
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }

    private static func rasterized(_ page: PDFPage, size: CGSize, dpi: CGFloat,
                                   over: ((CGContext, CGSize) -> Void)?) -> CGImage? {
        let s = dpi / 72
        let w = Int(size.width * s), h = Int(size.height * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        ctx.saveGState()
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        if let over { topLeft(ctx, size) { over(ctx, size) } }
        return ctx.makeImage()
    }

    /// Bounding box of non-white content on a page, in upright coordinates.
    static func contentBounds(_ page: PDFPage) -> CGRect? {
        guard let img = image(of: page, scale: 1, maxPixels: 1500), let data = img.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let w = img.width, h = img.height, bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = bytes + y * bpr
            for x in 0..<w {
                let p = row + x * bpp
                if p[0] < 245 || p[1] < 245 || p[2] < 245 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let size = uprightSize(page)
        let sx = size.width / CGFloat(w), sy = size.height / CGFloat(h)
        // Bitmap rows run top to bottom, matching upright coordinates.
        return CGRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy, width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
            .insetBy(dx: -6, dy: -6).intersection(CGRect(origin: .zero, size: size))
    }

    // MARK: Page ranges

    /// Parses "1-3, 5, 8-" into groups of zero-based page indices.
    static func parseRanges(_ text: String, pageCount: Int) throws -> [[Int]] {
        var groups: [[Int]] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let part = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if part.isEmpty { continue }
            let bits = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            func num(_ s: String, _ fallback: Int) throws -> Int {
                if s.isEmpty || s == "end" { return fallback }
                guard let n = Int(s) else { throw ToolError.message("“\(part)” isn’t a valid page range.") }
                return n
            }
            let a: Int, b: Int
            if bits.count == 1 { a = try num(bits[0], pageCount); b = a }
            else if bits.count == 2 { a = try num(bits[0], 1); b = try num(bits[1], pageCount) }
            else { throw ToolError.message("“\(part)” isn’t a valid page range.") }
            guard a >= 1, b >= 1, a <= pageCount, b <= pageCount else {
                throw ToolError.message("Page range “\(part)” is outside 1–\(pageCount).")
            }
            groups.append(a <= b ? Array((a - 1)...(b - 1)) : Array(stride(from: a - 1, through: b - 1, by: -1)))
        }
        if groups.isEmpty { throw ToolError.message("Enter at least one page or range.") }
        return groups
    }

    static func subset(_ doc: PDFDocument, _ indices: [Int]) -> PDFDocument {
        let out = PDFDocument()
        for i in indices { if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
        return out
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static func byteString(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

// MARK: - Organize-type operations

enum PDFOps {
    static func merge(_ urls: [URL], out dir: URL) throws -> ToolResult {
        guard urls.count >= 2 else { throw ToolError.message("Add at least two PDFs to merge.") }
        let out = PDFDocument()
        for url in urls {
            let d = try PDFCore.open(url)
            for i in 0..<d.pageCount { if let p = d.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
        }
        let dest = Workspace.uniqueURL(in: dir, name: "merged", ext: "pdf")
        try PDFCore.write(out, to: dest)
        return ToolResult(files: [dest], message: "Merged \(urls.count) files into \(out.pageCount) pages.")
    }

    enum SplitMode: String, CaseIterable, Identifiable {
        case customRanges = "Custom ranges"
        case fixedRanges = "Fixed ranges"
        case extractAll = "Extract all pages"
        case extractSelected = "Extract selected pages"
        var id: String { rawValue }
    }

    static func split(_ url: URL, mode: SplitMode, ranges: String, every: Int, mergeOutput: Bool, out dir: URL) throws -> ToolResult {
        let doc = try PDFCore.open(url)
        let n = doc.pageCount
        var groups: [[Int]]
        switch mode {
        case .customRanges: groups = try PDFCore.parseRanges(ranges, pageCount: n)
        case .fixedRanges:
            let step = max(1, every)
            groups = stride(from: 0, to: n, by: step).map { Array($0..<min($0 + step, n)) }
        case .extractAll: groups = (0..<n).map { [$0] }
        case .extractSelected: groups = try PDFCore.parseRanges(ranges, pageCount: n).flatMap { $0 }.map { [$0] }
        }
        if mergeOutput { groups = [groups.flatMap { $0 }] }
        var files: [URL] = []
        for g in groups {
            let part = PDFCore.subset(doc, g)
            let label = g.count == 1 ? "page-\(g[0] + 1)" : "pages-\(g.first! + 1)-\(g.last! + 1)"
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_\(mergeOutput ? "extracted" : label)", ext: "pdf")
            try PDFCore.write(part, to: dest)
            files.append(dest)
        }
        return ToolResult(files: files, message: "Created \(files.count) PDF\(files.count == 1 ? "" : "s").")
    }

    static func rotate(_ urls: [URL], degrees: Int, ranges: String, out dir: URL) throws -> ToolResult {
        var files: [URL] = []
        for url in urls {
            let doc = try PDFCore.open(url)
            let targets: Set<Int> = ranges.trimmingCharacters(in: .whitespaces).isEmpty
                ? Set(0..<doc.pageCount)
                : Set(try PDFCore.parseRanges(ranges, pageCount: doc.pageCount).flatMap { $0 })
            for i in targets { if let p = doc.page(at: i) { p.rotation = PDFCore.normalizedRotation(p.rotation + degrees) } }
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_rotated", ext: "pdf")
            try PDFCore.write(doc, to: dest)
            files.append(dest)
        }
        return ToolResult(files: files)
    }

    // MARK: Compress

    enum CompressLevel: String, CaseIterable, Identifiable {
        case low = "Less compression"
        case recommended = "Recommended"
        case extreme = "Extreme compression"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .low: return "High quality, less compression"
            case .recommended: return "Good quality, good compression"
            case .extreme: return "Lower quality, smallest file"
            }
        }
    }

    static func compress(_ urls: [URL], level: CompressLevel, out dir: URL, progress: JobProgress) throws -> ToolResult {
        var files: [URL] = []
        var before: Int64 = 0, after: Int64 = 0
        for (n, url) in urls.enumerated() {
            progress.update("Compressing \(url.lastPathComponent)…", Double(n) / Double(urls.count))
            let doc = try PDFCore.open(url)
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_compressed", ext: "pdf")
            var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
            switch level {
            case .low: break
            case .recommended: options[.optimizeImagesForScreenOption] = true
            case .extreme:
                options[.optimizeImagesForScreenOption] = true
                if let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")) {
                    options[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = filter
                }
            }
            try PDFCore.write(doc, to: dest, options: options)
            let a = PDFCore.fileSize(url), b = PDFCore.fileSize(dest)
            if b >= a { // Already optimal — keep the original bytes.
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
            }
            before += a; after += min(a, b)
            files.append(dest)
        }
        let saved = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
        let msg = saved > 0
            ? "Your PDFs are now \(saved)% smaller: \(PDFCore.byteString(before)) → \(PDFCore.byteString(after))."
            : "These PDFs are already well optimized (\(PDFCore.byteString(before)))."
        return ToolResult(files: files, message: msg)
    }

    // MARK: Security

    struct Permissions {
        var printing = true, copying = true, modifying = true, annotating = true, formFilling = true, assembling = true
    }

    static func protect(_ urls: [URL], userPassword: String, ownerPassword: String, permissions p: Permissions, out dir: URL) throws -> ToolResult {
        guard !userPassword.isEmpty else { throw ToolError.message("Enter a password.") }
        // PDFAccessPermissions is a plain NS_ENUM of bit values, so combine raw values.
        var perms: UInt = PDFAccessPermissions.allowsContentAccessibility.rawValue
        func allow(_ p: PDFAccessPermissions) { perms |= p.rawValue }
        if p.printing { allow(.allowsHighQualityPrinting); allow(.allowsLowQualityPrinting) }
        if p.copying { allow(.allowsContentCopying) }
        if p.modifying { allow(.allowsDocumentChanges) }
        if p.assembling { allow(.allowsDocumentAssembly) }
        if p.annotating { allow(.allowsCommenting) }
        if p.formFilling { allow(.allowsFormFieldEntry) }
        let owner = ownerPassword.isEmpty ? userPassword + "-owner-" + UUID().uuidString.prefix(8) : ownerPassword
        var files: [URL] = []
        for url in urls {
            let doc = try PDFCore.open(url)
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_protected", ext: "pdf")
            try PDFCore.write(doc, to: dest, options: [
                .userPasswordOption: userPassword,
                .ownerPasswordOption: owner,
                .accessPermissionsOption: NSNumber(value: perms),
            ])
            guard PDFDocument(url: dest)?.isLocked == true else { throw ToolError.message("Encryption failed for \(url.lastPathComponent).") }
            files.append(dest)
        }
        return ToolResult(files: files, message: "Encrypted with AES. Keep your password safe — it can’t be recovered.")
    }

    static func unlock(_ urls: [URL], password: String, out dir: URL) throws -> ToolResult {
        var files: [URL] = []
        for url in urls {
            guard let doc = PDFDocument(url: url) else { throw ToolError.open(url.lastPathComponent) }
            if doc.isLocked && !doc.unlock(withPassword: password) {
                throw ToolError.message("Wrong password for “\(url.lastPathComponent)”.")
            }
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_unlocked", ext: "pdf")
            try PDFCore.write(doc, to: dest)
            if let check = PDFDocument(url: dest), check.isEncrypted {
                // PDFKit kept the encryption; rebuild the file without it.
                try PDFCore.render(doc, to: dest)
            }
            files.append(dest)
        }
        return ToolResult(files: files, message: "Password and restrictions removed.")
    }

    // MARK: Repair

    static func repair(_ urls: [URL], out dir: URL) throws -> ToolResult {
        var files: [URL] = []
        var notes: [String] = []
        for url in urls {
            var doc = PDFDocument(url: url)
            if doc == nil || doc?.pageCount == 0, var data = try? Data(contentsOf: url) {
                // Strip junk before the header and terminate truncated files.
                if let r = data.range(of: Data("%PDF-".utf8)), r.lowerBound > 0 { data = data.subdata(in: r.lowerBound..<data.endIndex) }
                if let r = data.range(of: Data("%%EOF".utf8), options: .backwards) { data = data.subdata(in: data.startIndex..<r.upperBound) }
                else { data.append(Data("\nstartxref\n0\n%%EOF\n".utf8)) }
                doc = PDFDocument(data: data)
                if doc == nil || doc?.pageCount == 0 { doc = rebuildXref(data).flatMap(PDFDocument.init(data:)) }
            }
            guard let doc, doc.pageCount > 0 else { throw ToolError.message("“\(url.lastPathComponent)” is too badly damaged to recover.") }
            if doc.isLocked { throw ToolError.locked(url.lastPathComponent) }
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_repaired", ext: "pdf")
            try PDFCore.render(doc, to: dest)
            notes.append("\(url.lastPathComponent): recovered \(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s")")
            files.append(dest)
        }
        return ToolResult(files: files, message: notes.joined(separator: "\n"))
    }

    /// Rebuilds the cross-reference table by scanning for "N G obj" markers — recovers files whose
    /// xref/trailer is missing or truncated.
    static func rebuildXref(_ input: Data) -> Data? {
        var data = input
        let text = String(decoding: data, as: Unicode.ASCII.self) // 1 char per byte, so offsets match
        let ns = text as NSString
        guard let objRE = try? NSRegularExpression(pattern: "(?<![0-9])(\\d{1,7})\\s+(\\d{1,5})\\s+obj\\b") else { return nil }
        var offsets: [Int: (Int, Int)] = [:]
        var root: String?
        for m in objRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let num = Int(ns.substring(with: m.range(at: 1)))!, gen = Int(ns.substring(with: m.range(at: 2)))!
            offsets[num] = (m.range.location, gen) // later definitions win (incremental updates)
            let peek = ns.substring(with: NSRange(location: m.range.upperBound, length: min(400, ns.length - m.range.upperBound)))
            if peek.range(of: "/Type\\s*/Catalog", options: .regularExpression) != nil { root = "\(num) \(gen) R" }
        }
        if let r = try? NSRegularExpression(pattern: "/Root\\s+(\\d+\\s+\\d+\\s+R)"),
           let m = r.matches(in: text, range: NSRange(location: 0, length: ns.length)).last { root = ns.substring(with: m.range(at: 1)) }
        guard let root, let maxNum = offsets.keys.max() else { return nil }
        if data.last != 10 { data.append(10) }
        let xrefAt = data.count
        var xref = "xref\n0 \(maxNum + 1)\n0000000000 65535 f \n"
        for n in 1...max(maxNum, 1) {
            if let (off, gen) = offsets[n] { xref += String(format: "%010d %05d n \n", off, gen) } else { xref += "0000000000 65535 f \n" }
        }
        xref += "trailer\n<< /Size \(maxNum + 1) /Root \(root) >>\nstartxref\n\(xrefAt)\n%%EOF\n"
        data.append(Data(xref.utf8))
        return data
    }

    // MARK: PDF/A

    static func toPDFA(_ urls: [URL], out dir: URL, progress: JobProgress) throws -> ToolResult {
        var files: [URL] = []
        for url in urls {
            let doc = try PDFCore.open(url)
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_pdfa", ext: "pdf")
            let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? url.baseName
            let intent: [CFString: Any] = [
                kCGPDFXOutputIntentSubtype: "GTS_PDFA1",
                kCGPDFXOutputConditionIdentifier: "sRGB IEC61966-2.1",
                kCGPDFXOutputCondition: "sRGB",
                kCGPDFXRegistryName: "http://www.color.org",
                kCGPDFXInfo: "sRGB IEC61966-2.1",
                kCGPDFXDestinationOutputProfile: CGColorSpace(name: CGColorSpace.sRGB)!,
            ]
            try PDFCore.render(doc, to: dest, info: [kCGPDFContextOutputIntent: intent, kCGPDFContextTitle: title],
                               metadata: pdfaXMP(title: title), progress: progress)
            files.append(dest)
        }
        return ToolResult(files: files, message: "Converted to PDF/A-2b with embedded fonts, sRGB output intent and archival metadata.")
    }

    private static func pdfaXMP(title: String) -> Data {
        let date = ISO8601DateFormatter().string(from: Date())
        let t = title.xmlEscaped
        return Data("""
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:pdf="http://ns.adobe.com/pdf/1.3/">
           <pdfaid:part>2</pdfaid:part>
           <pdfaid:conformance>B</pdfaid:conformance>
           <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(t)</rdf:li></rdf:Alt></dc:title>
           <xmp:CreatorTool>Folio</xmp:CreatorTool>
           <xmp:CreateDate>\(date)</xmp:CreateDate>
           <xmp:ModifyDate>\(date)</xmp:ModifyDate>
           <pdf:Producer>macOS Quartz PDFContext</pdf:Producer>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """.utf8)
    }

    // MARK: Page numbers

    enum Position: String, CaseIterable, Identifiable {
        case topLeft = "Top left", topCenter = "Top center", topRight = "Top right"
        case middleLeft = "Middle left", center = "Center", middleRight = "Middle right"
        case bottomLeft = "Bottom left", bottomCenter = "Bottom center", bottomRight = "Bottom right"
        var id: String { rawValue }
        var col: Int { [0, 1, 2, 0, 1, 2, 0, 1, 2][Self.allCases.firstIndex(of: self)!] }
        var row: Int { Self.allCases.firstIndex(of: self)! / 3 }

        func origin(for item: CGSize, in page: CGSize, margin: CGFloat) -> CGPoint {
            let x: CGFloat = [margin, (page.width - item.width) / 2, page.width - item.width - margin][col]
            let y: CGFloat = [margin, (page.height - item.height) / 2, page.height - item.height - margin][row]
            return CGPoint(x: x, y: y)
        }
        var mirrored: Position {
            switch col { case 0: return Self.allCases[row * 3 + 2]; case 2: return Self.allCases[row * 3]; default: return self }
        }
    }

    struct PageNumberOptions {
        var position: Position = .bottomCenter
        var facingPages = false
        var margin: CGFloat = 28
        var firstNumber = 1
        var fromPage = 1
        var toPage = 0 // 0 = last
        var format = "{n}"
        var fontName = "Helvetica"
        var fontSize: CGFloat = 11
        var color: NSColor = .black
    }

    static func addPageNumbers(_ urls: [URL], options o: PageNumberOptions, out dir: URL) throws -> ToolResult {
        var files: [URL] = []
        for url in urls {
            let doc = try PDFCore.open(url)
            let last = o.toPage <= 0 ? doc.pageCount : min(o.toPage, doc.pageCount)
            let first = max(1, o.fromPage)
            let total = last - first + o.firstNumber
            let font = NSFont(name: o.fontName, size: o.fontSize) ?? .systemFont(ofSize: o.fontSize)
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_numbered", ext: "pdf")
            try PDFCore.render(doc, to: dest, over: { i, _, _, size in
                let pageNo = i + 1
                guard pageNo >= first, pageNo <= last else { return }
                let n = pageNo - first + o.firstNumber
                let text = o.format.replacingOccurrences(of: "{n}", with: "\(n)").replacingOccurrences(of: "{total}", with: "\(total)")
                let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: o.color])
                let pos = (o.facingPages && pageNo % 2 == 0) ? o.position.mirrored : o.position
                s.draw(at: pos.origin(for: s.size(), in: size, margin: o.margin))
            })
            files.append(dest)
        }
        return ToolResult(files: files)
    }

    // MARK: Watermark

    struct WatermarkOptions {
        var useImage = false
        var text = "CONFIDENTIAL"
        var fontName = "Helvetica-Bold"
        var fontSize: CGFloat = 48
        var color: NSColor = .red
        var image: NSImage?
        var imageScale: CGFloat = 0.4 // fraction of page width
        var opacity: CGFloat = 0.35
        var rotation: CGFloat = 45
        var position: Position = .center
        var mosaic = false
        var below = false
        var ranges = ""
    }

    static func watermark(_ urls: [URL], options o: WatermarkOptions, out dir: URL) throws -> ToolResult {
        if o.useImage && o.image == nil { throw ToolError.message("Choose an image for the watermark.") }
        if !o.useImage && o.text.isEmpty { throw ToolError.message("Enter watermark text.") }
        var files: [URL] = []
        for url in urls {
            let doc = try PDFCore.open(url)
            let targets: Set<Int>? = o.ranges.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                : Set(try PDFCore.parseRanges(o.ranges, pageCount: doc.pageCount).flatMap { $0 })
            let draw: PDFCore.PageDrawer = { i, _, ctx, size in
                if let targets, !targets.contains(i) { return }
                ctx.setAlpha(o.opacity)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                let itemSize: CGSize
                let font = NSFont(name: o.fontName, size: o.fontSize) ?? .boldSystemFont(ofSize: o.fontSize)
                let str = NSAttributedString(string: o.text, attributes: [.font: font, .foregroundColor: o.color])
                if o.useImage, let img = o.image {
                    let w = size.width * o.imageScale
                    itemSize = CGSize(width: w, height: w * img.size.height / max(img.size.width, 1))
                } else { itemSize = str.size() }
                func stamp(at center: CGPoint) {
                    ctx.saveGState()
                    ctx.translateBy(x: center.x, y: center.y)
                    ctx.rotate(by: -o.rotation * .pi / 180)
                    let r = CGRect(x: -itemSize.width / 2, y: -itemSize.height / 2, width: itemSize.width, height: itemSize.height)
                    if o.useImage, let img = o.image { img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
                    else { str.draw(at: r.origin) }
                    ctx.restoreGState()
                }
                if o.mosaic {
                    let cols = 3, rows = 4
                    for r in 0..<rows { for c in 0..<cols {
                        stamp(at: CGPoint(x: size.width * (CGFloat(c) + 0.5) / CGFloat(cols), y: size.height * (CGFloat(r) + 0.5) / CGFloat(rows)))
                    } }
                } else {
                    let origin = o.position.origin(for: itemSize, in: size, margin: 36)
                    stamp(at: CGPoint(x: origin.x + itemSize.width / 2, y: origin.y + itemSize.height / 2))
                }
                ctx.endTransparencyLayer()
            }
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_watermarked", ext: "pdf")
            try PDFCore.render(doc, to: dest, under: o.below ? draw : nil, over: o.below ? nil : draw)
            files.append(dest)
        }
        return ToolResult(files: files)
    }

    // MARK: Crop

    /// `rectFor` returns the upright crop rect for a page index, or nil to leave the page alone.
    static func crop(_ url: URL, out dir: URL, rectFor: (Int, CGSize) -> CGRect?) throws -> ToolResult {
        let doc = try PDFCore.open(url)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let r = rectFor(i, PDFCore.uprightSize(page)), r.width > 4, r.height > 4 else { continue }
            let pr = PDFCore.uprightToPage(r, page: page).intersection(page.bounds(for: .cropBox))
            page.setBounds(pr, for: .mediaBox)
            page.setBounds(pr, for: .cropBox)
        }
        let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_cropped", ext: "pdf")
        try PDFCore.write(doc, to: dest)
        return ToolResult(files: [dest])
    }
}

extension String {
    var xmlEscaped: String {
        var s = ""
        for ch in unicodeScalars {
            switch ch {
            case "&": s += "&amp;"
            case "<": s += "&lt;"
            case ">": s += "&gt;"
            case "\"": s += "&quot;"
            case "'": s += "&apos;"
            default:
                // Drop control characters that are illegal in XML 1.0.
                if ch.value < 0x20 && ch != "\n" && ch != "\t" && ch != "\r" { continue }
                s.unicodeScalars.append(ch)
            }
        }
        return s
    }
}
