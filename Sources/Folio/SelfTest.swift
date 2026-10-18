import AppKit
import PDFKit

/// Headless end-to-end checks of every engine: `Folio --selftest <dir>`.
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    private static func attempt(_ name: String, _ body: () async throws -> Void) async {
        do { try await body() } catch { check(name, false, "threw: \(error.localizedDescription)") }
    }

    private static func pages(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? -1 }
    private static func text(_ url: URL) -> String { PDFDocument(url: url)?.string ?? "" }

    static func run(in root: URL) async -> Bool {
        let dir = root.appendingPathComponent("selftest-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("Self-test output: \(dir.path)")
        let progress = JobProgress(Runner())

        // Fixtures --------------------------------------------------------------
        let sample = dir.appendingPathComponent("sample.pdf")
        let para = (1...6).map { "Paragraph \($0). The quick brown fox jumps over the lazy dog while the PDF toolbox checks every feature carefully." }
        let body = NSMutableAttributedString(string: "Annual Report\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 26)])
        body.append(NSAttributedString(string: (para + para + para + para + para).joined(separator: "\n\n") + "\nContact: alice@example.com, phone 415-555-0132.\n",
                                       attributes: [.font: NSFont(name: "Helvetica", size: 13)!]))
        try? OfficeConvert.paginate(body, pageSize: CGSize(width: 612, height: 792), margins: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72), out: sample)
        let n = pages(sample)
        check("fixture: TextKit pagination", n >= 2, "\(n) pages")

        let table = dir.appendingPathComponent("table.pdf")
        if let ctx = CGContext(table as CFURL, mediaBox: nil, nil) {
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            ctx.beginPage(mediaBox: &box)
            PDFCore.topLeft(ctx, box.size) {
                let rows = [["Item", "Qty", "Price"], ["Apples", "3", "1.50"], ["Bananas", "12", "0.25"], ["Cherries", "40", "7.00"]]
                for (r, row) in rows.enumerated() {
                    for (c, cell) in row.enumerated() {
                        NSAttributedString(string: cell, attributes: [.font: NSFont(name: "Helvetica", size: 12)!]).draw(at: CGPoint(x: 72 + c * 150, y: 100 + r * 24))
                    }
                }
            }
            ctx.endPage()
            ctx.closePDF()
        }

        let photo = dir.appendingPathComponent("photo.png")
        let img = NSImage(size: CGSize(width: 400, height: 300), flipped: false) { r in
            NSColor.systemTeal.setFill(); r.fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 80, dy: 60)).fill()
            return true
        }
        if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { try? ImageConvert.write(cg, to: photo, type: .png) }

        // Organize ------------------------------------------------------------
        await attempt("merge") {
            let r = try PDFOps.merge([sample, table], out: dir)
            check("merge", pages(r.files[0]) == n + 1, "\(pages(r.files[0])) pages")
        }
        await attempt("split") {
            let r1 = try PDFOps.split(sample, mode: .extractAll, ranges: "", every: 1, mergeOutput: false, out: dir)
            check("split: extract all", r1.files.count == n && r1.files.allSatisfy { pages($0) == 1 })
            let r2 = try PDFOps.split(sample, mode: .customRanges, ranges: "1, 2-", every: 1, mergeOutput: false, out: dir)
            check("split: custom ranges", r2.files.count == 2 && pages(r2.files[1]) == n - 1)
            let r3 = try PDFOps.split(sample, mode: .extractSelected, ranges: "1,2", every: 1, mergeOutput: true, out: dir)
            check("split: extract selected merged", r3.files.count == 1 && pages(r3.files[0]) == 2)
            check("split: bad range rejected", (try? PDFCore.parseRanges("0-99", pageCount: n)) == nil)
        }
        await attempt("rotate") {
            let r = try PDFOps.rotate([sample], degrees: 90, ranges: "1", out: dir)
            let d = PDFDocument(url: r.files[0])!
            check("rotate", d.page(at: 0)!.rotation == 90 && d.page(at: 1)!.rotation == 0)
            // Coordinate round-trip on a rotated page.
            let p = d.page(at: 0)!
            let up = CGRect(x: 50, y: 60, width: 100, height: 40)
            let back = PDFCore.pageToUpright(PDFCore.uprightToPage(up, page: p), page: p)
            check("coords: rotated round-trip", abs(back.minX - up.minX) < 0.01 && abs(back.minY - up.minY) < 0.01 && abs(back.width - up.width) < 0.01)
            check("coords: upright size swaps", PDFCore.uprightSize(p) == CGSize(width: 792, height: 612))
            // Rendering a rotated page keeps it upright and the text intact.
            let out = dir.appendingPathComponent("rotated-rendered.pdf")
            try PDFCore.render(d, to: out)
            let rp = PDFDocument(url: out)!.page(at: 0)!
            check("render: rotated page upright", rp.bounds(for: .mediaBox).size == CGSize(width: 792, height: 612) && (rp.string ?? "").contains("Annual Report"))
        }

        // Optimize ------------------------------------------------------------
        await attempt("compress") {
            let imgPDF = try ImageConvert.imagesToPDF([photo], pageSize: .a4, orientation: .auto, margin: .small, merge: true, out: dir).files[0]
            for level in PDFOps.CompressLevel.allCases {
                let r = try PDFOps.compress([imgPDF, sample], level: level, out: dir, progress: progress)
                check("compress: \(level.rawValue)", r.files.count == 2 && r.files.allSatisfy { pages($0) > 0 } && text(r.files[1]).contains("Paragraph"), r.message ?? "")
            }
        }
        await attempt("repair") {
            var data = try Data(contentsOf: sample)
            data = Data("garbage-prefix\n".utf8) + data.prefix(data.count - 30)
            let broken = dir.appendingPathComponent("broken.pdf")
            try data.write(to: broken)
            let r = try PDFOps.repair([broken], out: dir)
            check("repair: truncated + junk header", pages(r.files[0]) >= 1, r.message ?? "")
        }
        await attempt("ocr") {
            // Image-only PDF from the sample's first page.
            let raster = dir.appendingPathComponent("scanned.png")
            try ImageConvert.write(PDFCore.image(of: PDFDocument(url: sample)!.page(at: 0)!, scale: 2)!, to: raster, type: .png)
            let scanned = try ImageConvert.imagesToPDF([raster], pageSize: .letter, orientation: .portrait, margin: .none, merge: true, out: dir).files[0]
            check("ocr: fixture has no text", text(scanned).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let r = try OCR.makeSearchable([scanned], languages: nil, skipTextPages: true, out: dir, progress: progress)
            let t = text(r.files[0])
            check("ocr: text now searchable", t.contains("Annual") && t.contains("quick brown fox"), String(t.prefix(60)).replacingOccurrences(of: "\n", with: " "))
            let sel = PDFDocument(url: r.files[0])!.findString("Annual", withOptions: .caseInsensitive).first
            let b = sel.map { $0.bounds(for: $0.pages[0]) } ?? .zero
            check("ocr: text positioned near heading", b.minY > 600 && b.minX < 160, "\(b)")
        }

        // Convert to PDF --------------------------------------------------------
        await attempt("images to pdf") {
            let r = try ImageConvert.imagesToPDF([photo, photo], pageSize: .fit, orientation: .auto, margin: .none, merge: false, out: dir)
            check("images → pdf (separate)", r.files.count == 2 && pages(r.files[0]) == 1)
            let r2 = try ImageConvert.imagesToPDF([photo], pageSize: .a4, orientation: .auto, margin: .big, merge: true, out: dir)
            check("images → pdf (A4 auto landscape)", PDFDocument(url: r2.files[0])!.page(at: 0)!.bounds(for: .mediaBox).width == 842)
        }
        await attempt("word to pdf") {
            let docx = dir.appendingPathComponent("letter.docx")
            try body.data(from: NSRange(location: 0, length: body.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)
            let out = try await OfficeConvert.convert(docx, kind: .word, useIWork: false, out: dir)
            check("word → pdf (built-in)", pages(out) >= 2 && text(out).contains("lazy dog"))
        }
        await attempt("excel/ppt fallback") {
            let xlsx = dir.appendingPathComponent("book.xlsx")
            try OOXMLWriter.xlsx(sheets: [("Prices", [["Item", "Price"], ["Apples", "1.5"]]), ("Other", [["x"]])], to: xlsx)
            let html = try OOXMLReader.xlsxToHTML(xlsx)
            check("xlsx writer/reader round-trip", html.contains("Apples") && html.contains("1.5") && html.contains("Prices"))
            let out = try await OfficeConvert.convert(xlsx, kind: .excel, useIWork: false, out: dir)
            check("excel → pdf (built-in)", pages(out) >= 1 && text(out).contains("Apples"))
            let pptx = dir.appendingPathComponent("deck.pptx")
            try OOXMLWriter.pptx(PDFDocument(url: sample)!, to: pptx, dpi: 72, progress: progress)
            let pout = try await OfficeConvert.convert(pptx, kind: .powerpoint, useIWork: false, out: dir)
            check("pptx → pdf (built-in)", pages(pout) >= 1)
        }
        await attempt("html to pdf") {
            let html = dir.appendingPathComponent("page.html")
            try "<html><body><h1>Hello HTML</h1>\((1...120).map { "<p>Line \($0) of a long web page.</p>" }.joined())</body></html>".write(to: html, atomically: true, encoding: .utf8)
            let out = dir.appendingPathComponent("page.pdf")
            try await WebPDF.render(url: html, baseURL: nil, out: out)
            check("html → pdf (paginated)", pages(out) >= 2 && text(out).contains("Hello HTML"), "\(pages(out)) pages")
        }

        // Convert from PDF ------------------------------------------------------
        await attempt("pdf to images") {
            let r = try ImageConvert.pdfToImages([sample], format: .jpg, dpi: 100, quality: 0.8, out: dir, progress: progress)
            check("pdf → jpg", r.files.count == n && NSImage(contentsOf: r.files[0])?.isValid == true)
            let imgPDF = try ImageConvert.imagesToPDF([photo], pageSize: .fit, orientation: .auto, margin: .none, merge: true, out: dir).files[0]
            let e = try ImageConvert.extractImages([imgPDF], out: dir)
            check("pdf → extract images", e.files.count == 1 && NSImage(contentsOf: e.files[0]).map { $0.representations[0].pixelsWide } == NSImage(contentsOf: photo)?.representations[0].pixelsWide)
        }
        await attempt("pdf to word") {
            let r = try TextExtract.pdfToWord([sample], format: .docx, ocr: false, reflowText: true, out: dir, progress: progress)
            let back = try NSAttributedString(url: r.files[0], options: [:], documentAttributes: nil)
            check("pdf → docx", back.string.contains("quick brown fox") && back.string.contains("Annual Report"))
        }
        await attempt("pdf to pptx") {
            let pptx = dir.appendingPathComponent("slides.pptx")
            try OOXMLWriter.pptx(PDFDocument(url: sample)!, to: pptx, dpi: 100, progress: progress)
            let html = try OOXMLReader.pptxToHTML(pptx)
            check("pdf → pptx", html.components(separatedBy: "class='slide'").count - 1 == n && html.contains("data:image/jpeg"))
        }
        await attempt("pdf to excel") {
            let r = try TextExtract.pdfToExcel([table], oneSheet: false, csv: true, out: dir, progress: progress)
            let csv = try String(contentsOf: r.files[0], encoding: .utf8)
            check("pdf → csv table columns", csv.contains("Item,Qty,Price") && csv.contains("Bananas,12,0.25"), csv.replacingOccurrences(of: "\n", with: " | "))
            let x = try TextExtract.pdfToExcel([table], oneSheet: false, csv: false, out: dir, progress: progress)
            check("pdf → xlsx", (try OOXMLReader.xlsxToHTML(x.files[0])).contains("Cherries"))
        }
        await attempt("pdf to markdown") {
            let md = try TextExtract.pdfToMarkdown(sample, ocr: false)
            check("pdf → markdown heading", md.hasPrefix("# Annual Report"), String(md.prefix(40)))
            check("pdf → markdown paragraphs", md.contains("Paragraph 1. The quick brown fox"))
        }
        await attempt("pdf/a") {
            let r = try PDFOps.toPDFA([sample], out: dir, progress: progress)
            // CGPDFDictionary readers don't surface these catalog entries, so inspect the bytes.
            let raw = String(decoding: try Data(contentsOf: r.files[0]), as: Unicode.ASCII.self)
            let hasIntent = raw.range(of: "/Catalog[^>]*/OutputIntents", options: .regularExpression) != nil && raw.contains("GTS_PDFA1")
            let xmp = raw.range(of: "/Catalog[^>]*/Metadata", options: .regularExpression) != nil ? "<pdfaid:part>2" : ""
            check("pdf/a metadata + intent", hasIntent && xmp.contains("<pdfaid:part>2") && text(r.files[0]).contains("lazy dog"))
        }

        // Edit ------------------------------------------------------------------
        await attempt("page numbers") {
            var o = PDFOps.PageNumberOptions(); o.format = "Page {n} of {total}"
            let r = try PDFOps.addPageNumbers([sample], options: o, out: dir)
            check("page numbers", text(r.files[0]).contains("Page 2 of \(n)"))
        }
        await attempt("watermark") {
            var o = PDFOps.WatermarkOptions(); o.text = "DRAFTCOPY"; o.mosaic = true
            let r = try PDFOps.watermark([sample], options: o, out: dir)
            check("watermark (text, mosaic)", text(r.files[0]).components(separatedBy: "DRAFTCOPY").count - 1 >= 12 * n)
            o.useImage = true; o.image = img; o.mosaic = false; o.below = true
            let r2 = try PDFOps.watermark([sample], options: o, out: dir)
            check("watermark (image, below)", pages(r2.files[0]) == n)
        }
        await attempt("crop") {
            let r = try PDFOps.crop(sample, out: dir) { _, s in CGRect(x: 50, y: 50, width: s.width - 100, height: s.height - 100) }
            let b = PDFDocument(url: r.files[0])!.page(at: 0)!.bounds(for: .cropBox)
            check("crop", abs(b.width - 512) < 0.5 && abs(b.height - 692) < 0.5, "\(b)")
            let c = PDFCore.contentBounds(PDFDocument(url: table)!.page(at: 0)!)
            check("crop: auto content bounds", c.map { $0.minX > 50 && $0.minX < 75 && $0.minY > 85 && $0.maxY < 200 } ?? false, "\(c ?? .zero)")
        }
        await attempt("edit overlay") {
            let doc = PDFDocument(url: sample)!
            let items = [CanvasItem(page: 0, kind: .text, rect: CGRect(x: 100, y: 100, width: 200, height: 30), text: "Inserted note"),
                         CanvasItem(page: 0, kind: .rect, rect: CGRect(x: 10, y: 10, width: 50, height: 50)),
                         CanvasItem(page: 1, kind: .ink, rect: CGRect(x: 10, y: 10, width: 50, height: 50), points: [.zero, CGPoint(x: 1, y: 1)])]
            let out = dir.appendingPathComponent("edited.pdf")
            try PDFCore.render(doc, to: out, over: { i, _, _, size in ItemRenderer.draw(items.filter { $0.page == i }, size: size) })
            let sel = PDFDocument(url: out)!.findString("Inserted note", withOptions: []).first
            let b = sel.map { PDFCore.pageToUpright($0.bounds(for: $0.pages[0]), page: $0.pages[0]) } ?? .zero
            check("edit: text placed at upright position", abs(b.minX - 100) < 4 && abs(b.minY - 100) < 6, "\(b)")
        }
        await attempt("edit on rotated page") {
            let doc = PDFDocument(url: sample)!
            doc.page(at: 0)!.rotation = 90
            let items = [CanvasItem(page: 0, kind: .text, rect: CGRect(x: 120, y: 80, width: 200, height: 30), text: "Rotated note")]
            let out = dir.appendingPathComponent("edited-rotated.pdf")
            try PDFCore.render(doc, to: out, over: { i, _, _, size in ItemRenderer.draw(items.filter { $0.page == i }, size: size) })
            let res = PDFDocument(url: out)!
            let sel = res.findString("Rotated note", withOptions: []).first
            let b = sel.map { PDFCore.pageToUpright($0.bounds(for: $0.pages[0]), page: $0.pages[0]) } ?? .zero
            let title = res.findString("Annual Report", withOptions: []).first.map { $0.bounds(for: $0.pages[0]) } ?? .zero
            // Upright landscape page: the original heading now runs top-to-bottom near the right edge.
            check("edit: rotated page overlay position", abs(b.minX - 120) < 4 && abs(b.minY - 80) < 6, "\(b)")
            check("render: rotated content orientation", title.height > title.width && title.minX > 600, "\(title)")
        }
        await attempt("forms") {
            let doc = PDFDocument(url: sample)!
            let page = doc.page(at: 0)!
            let w = PDFAnnotation(bounds: PDFCore.uprightToPage(CGRect(x: 72, y: 600, width: 200, height: 22), page: page), forType: .widget, withProperties: nil)
            w.widgetFieldType = .text; w.fieldName = "FullName"
            page.addAnnotation(w)
            let c = PDFAnnotation(bounds: PDFCore.uprightToPage(CGRect(x: 72, y: 640, width: 14, height: 14), page: page), forType: .widget, withProperties: nil)
            c.widgetFieldType = .button; c.widgetControlType = .checkBoxControl; c.fieldName = "Agree"
            page.addAnnotation(c)
            let out = dir.appendingPathComponent("form.pdf")
            try PDFCore.write(doc, to: out)
            let names = PDFDocument(url: out)!.page(at: 0)!.annotations.compactMap(\.fieldName)
            check("forms: fields persisted", names.contains("FullName") && names.contains("Agree"), "\(names)")
        }

        // Security --------------------------------------------------------------
        await attempt("protect/unlock") {
            var perms = PDFOps.Permissions(); perms.copying = false
            let r = try PDFOps.protect([sample], userPassword: "s3cret", ownerPassword: "", permissions: perms, out: dir)
            let locked = PDFDocument(url: r.files[0])!
            check("protect: requires password", locked.isLocked && !locked.unlock(withPassword: "wrong") && locked.unlock(withPassword: "s3cret"))
            check("protect: wrong password on unlock rejected", (try? PDFOps.unlock(r.files, password: "nope", out: dir)) == nil)
            let u = try PDFOps.unlock(r.files, password: "s3cret", out: dir)
            let d = PDFDocument(url: u.files[0])!
            check("unlock", !d.isLocked && !d.isEncrypted && (d.string ?? "").contains("lazy dog"))
        }
        await attempt("redact") {
            let doc = PDFDocument(url: sample)!
            let page = doc.page(at: doc.pageCount - 1)!
            guard let sel = doc.findString("alice@example.com", withOptions: []).first else { check("redact: fixture", false); return }
            let rect = PDFCore.pageToUpright(sel.bounds(for: page), page: page).insetBy(dx: -2, dy: -2)
            let items = [CanvasItem(page: doc.pageCount - 1, kind: .redact, rect: rect, fill: .black)]
            let tmp = dir.appendingPathComponent("redact-raster.pdf")
            try PDFCore.render(doc, to: tmp, keepInfo: false, over: { i, _, _, s in ItemRenderer.draw(items.filter { $0.page == i }, size: s) },
                               rasterizeDPI: { $0 == doc.pageCount - 1 ? 200 : nil })
            let r = try OCR.makeSearchable([tmp], languages: nil, skipTextPages: true, out: dir, progress: progress)
            let t = text(r.files[0])
            check("redact: secret removed", !t.contains("alice@example.com") && !t.contains("alice"))
            check("redact: other text still searchable (OCR)", t.contains("415-555-0132") || t.contains("phone"))
        }

        // Intelligence & compare -------------------------------------------------
        let summary = Summarizer.extractive(para.joined(separator: " ") + " Revenue grew 40 percent in the third quarter thanks to strong demand.", sentences: 3, style: .bullets)
        check("summarize: extractive", summary.split(separator: "\n").count == 3 && summary.hasPrefix("- "))
        print("INFO  Apple Intelligence: \(Summarizer.availability.reason)")
        let a = ["one", "two", "three"], b = ["one", "2", "three", "four"]
        let diff = b.difference(from: a)
        check("compare: diff", diff.insertions.count == 2 && diff.removals.count == 1)
        await attempt("translate units") {
            let units = try TranslationUnit.extract(sample, layout: true)
            check("translate: layout units extracted", units.count > 10 && units.allSatisfy { $0.rect.width > 0 })
            let r = try TranslationUnit.build(sample, units: units, translations: units.map { $0.text.uppercased() }, layout: true, language: "xx")
            check("translate: layout rebuild", text(r.files[0]).contains("QUICK BROWN FOX"))
        }

        // UI logic -------------------------------------------------------------
        await attempt("auto-save delivery") {
            let defaults = UserDefaults.standard
            let saved = defaults.string(forKey: Prefs.saveLocationKey)
            defer { if let saved { defaults.set(saved, forKey: Prefs.saveLocationKey) } else { defaults.removeObject(forKey: Prefs.saveLocationKey) } }
            defaults.set(SaveLocation.nextToOriginal.rawValue, forKey: Prefs.saveLocationKey)
            let one = try PDFOps.rotate([sample], degrees: 90, ranges: "", out: try Workspace.newOutputDir())
            let d1 = ResultSaver.deliver(one.files, source: sample, label: "Rotate PDF")
            let landed = d1?.files.first
            check("save: single file lands next to original", landed?.deletingLastPathComponent().resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path
                  && FileManager.default.fileExists(atPath: landed?.path ?? ""), landed?.path ?? "nil")
            let many = try ImageConvert.pdfToImages([sample, sample], format: .png, dpi: 30, quality: 1, out: try Workspace.newOutputDir(), progress: progress)
            let d2 = ResultSaver.deliver(many.files, source: sample, label: "PDF to JPG")
            check("save: many files go into their own folder", d2.map { $0.folder.lastPathComponent == "sample – PDF to JPG" && $0.files.count == 2 * n } ?? false,
                  d2?.folder.lastPathComponent ?? "nil")
            defaults.set(SaveLocation.ask.rawValue, forKey: Prefs.saveLocationKey)
            check("save: 'ask each time' leaves files in place", ResultSaver.deliver(one.files, source: sample, label: "") == nil)
        }
        let model = CanvasModel(doc: PDFDocument(url: sample)!, url: sample)
        model.add(CanvasItem(page: 0, kind: .rect, rect: CGRect(x: 10, y: 10, width: 50, height: 50)))
        model.beginGesture()
        for dx in stride(from: 1, through: 30, by: 1) { model.nudgeSelection(dx: 1, dy: 0); _ = dx }
        model.endGesture()
        check("undo: drag is one step", model.items[0].rect.minX == 40)
        model.undo()
        check("undo: restores position", model.items.count == 1 && model.items[0].rect.minX == 10)
        model.undo()
        check("undo: removes added item", model.items.isEmpty && !model.canUndo)
        model.redo(); model.redo()
        check("redo: reapplies both steps", model.items.count == 1 && model.items[0].rect.minX == 40 && !model.canRedo)
        let groups = try? PDFOps.splitGroups(mode: .customRanges, ranges: "1, 2-3", every: 1, mergeOutput: false, pageCount: 3)
        check("split preview groups", groups == [[0], [1, 2]])

        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        return failures == 0
    }
}
