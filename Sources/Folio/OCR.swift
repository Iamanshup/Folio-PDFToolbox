import AppKit
import CoreImage
import CoreText
import PDFKit
import Vision

enum OCR {
    struct Line {
        let text: String
        /// Normalized (0–1) bounding box, bottom-left origin.
        let box: CGRect
    }

    static func recognize(_ image: CGImage, languages: [String]? = nil, fast: Bool = false) throws -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.usesLanguageCorrection = true
        if let languages, !languages.isEmpty { req.recognitionLanguages = languages } else { req.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        return (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first else { return nil }
            return Line(text: c.string, box: o.boundingBox)
        }
    }

    static var supportedLanguages: [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
    }

    /// Draws recognized lines as invisible, selectable text. `ctx` is in upright top-left coordinates.
    static func drawInvisibleText(_ lines: [Line], in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1) // back to PDF's bottom-left space
        ctx.setTextDrawingMode(.invisible)
        for l in lines {
            let r = CGRect(x: l.box.minX * size.width, y: l.box.minY * size.height, width: l.box.width * size.width, height: l.box.height * size.height)
            guard r.width > 1, r.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, r.height * 0.82, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: l.text, attributes: [.font: font]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard width > 0 else { continue }
            ctx.textMatrix = CGAffineTransform(scaleX: r.width / CGFloat(width), y: 1)
            ctx.textPosition = CGPoint(x: r.minX, y: r.minY + r.height * 0.18)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    static func makeSearchable(_ urls: [URL], languages: [String]?, skipTextPages: Bool, out dir: URL, progress: JobProgress) throws -> ToolResult {
        var files: [URL] = []
        var processed = 0, skipped = 0
        for url in urls {
            let doc = try PDFCore.open(url)
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_ocr", ext: "pdf")
            var failure: Error?
            try PDFCore.render(doc, to: dest, over: { i, page, ctx, size in
                progress.update("Recognizing text on page \(i + 1) of \(doc.pageCount)…", Double(i) / Double(doc.pageCount))
                if skipTextPages, let s = page.string, s.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { skipped += 1; return }
                guard let img = PDFCore.image(of: page, scale: 300 / 72, maxPixels: 5000) else { return }
                do { drawInvisibleText(try recognize(img, languages: languages), in: ctx, size: size); processed += 1 }
                catch { failure = error }
            })
            if let failure { throw failure }
            files.append(dest)
        }
        var msg = "Recognized text on \(processed) page\(processed == 1 ? "" : "s")."
        if skipped > 0 { msg += " Skipped \(skipped) page\(skipped == 1 ? "" : "s") that already had text." }
        return ToolResult(files: files, message: msg)
    }
}

// MARK: - Document scan processing

enum ScanProcessing {
    enum Filter: String, CaseIterable, Identifiable {
        case color = "Color", grayscale = "Grayscale", blackWhite = "Black & White", photo = "Original"
        var id: String { rawValue }
    }

    static let context = CIContext()

    /// Detects the document in a photo and straightens it.
    static func straighten(_ image: CGImage) -> CGImage {
        let req = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        guard let o = req.results?.first, o.confidence > 0.6 else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func v(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }
        let area = abs((o.topRight.x - o.bottomLeft.x) * (o.topRight.y - o.bottomLeft.y))
        guard area > 0.15 else { return image } // tiny detections are usually wrong
        let f = CIFilter(name: "CIPerspectiveCorrection")!
        f.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        f.setValue(v(o.topLeft), forKey: "inputTopLeft")
        f.setValue(v(o.topRight), forKey: "inputTopRight")
        f.setValue(v(o.bottomLeft), forKey: "inputBottomLeft")
        f.setValue(v(o.bottomRight), forKey: "inputBottomRight")
        guard let out = f.outputImage, let cg = context.createCGImage(out, from: out.extent) else { return image }
        return cg
    }

    static func apply(_ filter: Filter, to image: CGImage) -> CGImage {
        var ci = CIImage(cgImage: image)
        switch filter {
        case .photo: return image
        case .color:
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.15, kCIInputSaturationKey: 1.05, kCIInputBrightnessKey: 0.02])
        case .grayscale:
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.25])
        case .blackWhite:
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.6, kCIInputBrightnessKey: 0.08])
                .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.55])
        }
        return context.createCGImage(ci, from: ci.extent) ?? image
    }

    static func makePDF(_ images: [CGImage], filter: Filter, ocr: Bool, to dest: URL, progress: JobProgress) throws {
        guard let ctx = CGContext(dest as CFURL, mediaBox: nil, [kCGPDFContextCreator: "Folio"] as CFDictionary) else {
            throw ToolError.message("Couldn’t create PDF.")
        }
        for (i, raw) in images.enumerated() {
            progress.update("Processing scan \(i + 1) of \(images.count)…", Double(i) / Double(images.count))
            let img = apply(filter, to: raw)
            // Re-encode as JPEG so the PDF stays small (CoreGraphics embeds JPEG data directly).
            let embedded = ImageConvert.jpegData(img, quality: 0.75)
                .flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } ?? img
            let width: CGFloat = 595
            let size = CGSize(width: width, height: width * CGFloat(img.height) / CGFloat(img.width))
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(embedded, in: box)
            if ocr, let lines = try? OCR.recognize(img) {
                PDFCore.topLeft(ctx, size) { OCR.drawInvisibleText(lines, in: ctx, size: size) }
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }
}
