import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Organize

struct MergeTool: View {
    var body: some View {
        FileToolView(tool: .merge, reorderable: true, prompt: "Select PDF files to merge", actionTitle: "Merge PDF", minFiles: 2) { files in
            { dir, _ in try PDFOps.merge(files, out: dir) }
        }
    }
}

struct SplitTool: View {
    @Local private var mode = PDFOps.SplitMode.customRanges
    @Local private var ranges = "1-2, 3-"
    @Local private var every = 1
    @Local private var merge = false

    var body: some View {
        FileToolView(tool: .split, multiple: false, prompt: "Select a PDF to split", actionTitle: "Split PDF", options: { files in
            let count = PDFDocument(url: files[0])?.pageCount ?? 0
            Picker("Mode", selection: $mode) { ForEach(PDFOps.SplitMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            switch mode {
            case .customRanges:
                TextField("Ranges, e.g. 1-3, 4-6, 7-", text: $ranges).textFieldStyle(.roundedBorder)
                Text("Each range becomes its own PDF. This file has \(count) pages.").font(.caption).foregroundStyle(.secondary)
                Toggle("Merge all ranges into one PDF", isOn: $merge)
            case .fixedRanges:
                Stepper("Split every \(every) page\(every == 1 ? "" : "s")", value: $every, in: 1...max(1, count))
                Text("This creates \(count == 0 ? 0 : (count + every - 1) / every) PDF files.").font(.caption).foregroundStyle(.secondary)
            case .extractAll:
                Text("Every page will be saved as a separate PDF (\(count) files).").foregroundStyle(.secondary)
            case .extractSelected:
                TextField("Pages to extract, e.g. 1, 3, 5-8", text: $ranges).textFieldStyle(.roundedBorder)
                Toggle("Merge extracted pages into one PDF", isOn: $merge)
            }
        }, makeJob: { files in
            let (m, r, e) = (mode, ranges, every)
            let g = merge && (mode == .customRanges || mode == .extractSelected)
            return { dir, _ in try PDFOps.split(files[0], mode: m, ranges: r, every: e, mergeOutput: g, out: dir) }
        })
    }
}

// MARK: - Optimize

struct CompressTool: View {
    @Local private var level = PDFOps.CompressLevel.recommended
    var body: some View {
        FileToolView(tool: .compress, prompt: "Select PDF files to compress", actionTitle: "Compress PDF", options: { _ in
            HStack(spacing: 12) {
                ForEach(PDFOps.CompressLevel.allCases) { l in
                    Button { level = l } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l.rawValue).font(.headline)
                            Text(l.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(level == l ? Color.green.opacity(0.15) : Color.secondary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(level == l ? Color.green : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }, makeJob: { files in
            let l = level
            return { dir, p in try PDFOps.compress(files, level: l, out: dir, progress: p) }
        })
    }
}

struct RepairTool: View {
    var body: some View {
        FileToolView(tool: .repair, prompt: "Select damaged PDF files", actionTitle: "Repair PDF") { files in
            { dir, _ in try PDFOps.repair(files, out: dir) }
        }
    }
}

struct OCRTool: View {
    @Local private var language = "auto"
    @Local private var skip = true
    var body: some View {
        FileToolView(tool: .ocr, prompt: "Select scanned PDF files", actionTitle: "Make Searchable", options: { _ in
            Picker("Document language", selection: $language) {
                Text("Detect automatically").tag("auto")
                Divider()
                ForEach(OCR.supportedLanguages, id: \.self) { l in Text(Locale.current.localizedString(forIdentifier: l) ?? l).tag(l) }
            }
            .frame(maxWidth: 360)
            Toggle("Skip pages that already contain text", isOn: $skip)
            Text("Text is recognized on-device with Apple’s Vision framework and added as an invisible, selectable layer.")
                .font(.caption).foregroundStyle(.secondary)
        }, makeJob: { files in
            let langs = language == "auto" ? nil : [language]
            let s = skip
            return { dir, p in try OCR.makeSearchable(files, languages: langs, skipTextPages: s, out: dir, progress: p) }
        })
    }
}

// MARK: - Convert to PDF

struct ImagesToPDFTool: View {
    @Local private var size = ImageConvert.PageSize.a4
    @Local private var orientation = ImageConvert.Orientation.auto
    @Local private var margin = ImageConvert.Margin.none
    @Local private var merge = true

    var body: some View {
        FileToolView(tool: .jpgToPDF, types: UTType.imageTypes, reorderable: true, prompt: "Select images", actionTitle: "Convert to PDF", options: { _ in
            Picker("Page size", selection: $size) { ForEach(ImageConvert.PageSize.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if size != .fit {
                Picker("Orientation", selection: $orientation) { ForEach(ImageConvert.Orientation.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            }
            Picker("Margin", selection: $margin) { ForEach(ImageConvert.Margin.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Toggle("Merge all images into one PDF", isOn: $merge)
        }, makeJob: { files in
            let (s, o, m, g) = (size, orientation, margin, merge)
            return { dir, _ in try ImageConvert.imagesToPDF(files, pageSize: s, orientation: o, margin: m, merge: g, out: dir) }
        })
    }
}

struct OfficeToPDFTool: View {
    let kind: OfficeConvert.Kind
    @Local private var useIWork = true

    var tool: Tool { switch kind { case .word: return .wordToPDF; case .powerpoint: return .pptToPDF; case .excel: return .excelToPDF } }
    var types: [UTType] { switch kind { case .word: return UTType.wordTypes; case .powerpoint: return UTType.pptTypes; case .excel: return UTType.excelTypes } }
    var app: (name: String, id: String) {
        switch kind { case .word: return ("Pages", OfficeConvert.pagesID); case .powerpoint: return ("Keynote", OfficeConvert.keynoteID); case .excel: return ("Numbers", OfficeConvert.numbersID) }
    }

    var body: some View {
        let installed = OfficeConvert.appInstalled(app.id)
        FileToolView(tool: tool, types: types, prompt: "Select \(kind == .word ? "Word" : kind == .powerpoint ? "PowerPoint" : "Excel") files", actionTitle: "Convert to PDF", options: { _ in
            if installed {
                Picker("Converter", selection: $useIWork) {
                    Text("\(app.name) (best fidelity)").tag(true)
                    Text(kind == .word ? "Built-in" : "Built-in (basic)").tag(false)
                }
                .pickerStyle(.radioGroup)
                if useIWork {
                    Text("The first conversion asks for permission to let Folio control \(app.name).").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(kind == .word ? "Using the built-in converter."
                     : "\(app.name) isn’t installed, so a basic built-in renderer is used (\(kind == .excel ? ".xlsx and .csv" : ".pptx") only). Install \(app.name) for full fidelity.")
                    .foregroundStyle(.secondary)
            }
        }, makeJob: { files in
            let k = kind
            let iwork = installed && useIWork
            return { dir, p in
                var out: [URL] = []
                for (i, f) in files.enumerated() {
                    p.update("Converting \(f.lastPathComponent)…", Double(i) / Double(files.count))
                    out.append(try await OfficeConvert.convert(f, kind: k, useIWork: iwork, out: dir))
                }
                return ToolResult(files: out)
            }
        })
    }
}

struct HTMLToPDFTool: View {
    @Local private var address = "https://"
    @Local private var file: URL?
    @Local private var paper = WebPDF.Paper.a4
    @Local private var landscape = false
    @Local private var margin: Double = 36
    @Local private var width: Double = 1280
    @StateObject private var runner = Runner()

    var body: some View {
        ToolPage(tool: .htmlToPDF) {
            OptionsBox(title: "Web page") {
                HStack {
                    TextField("https://example.com", text: $address).textFieldStyle(.roundedBorder).onSubmit(convert)
                    Text("or").foregroundStyle(.secondary)
                    Button("Choose HTML File…") { file = FilePicker.open(types: [.html], multiple: false)?.first }
                }
                if let file { HStack { FileRow(url: file); Button("Remove") { self.file = nil } } }
            }
            OptionsBox {
                Picker("Paper", selection: $paper) { ForEach(WebPDF.Paper.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 300)
                Toggle("Landscape", isOn: $landscape)
                HStack { Text("Margin"); Slider(value: $margin, in: 0...72); Text("\(Int(margin)) pt").monospacedDigit().frame(width: 50) }.frame(maxWidth: 420)
                Picker("Screen width", selection: $width) {
                    Text("Mobile (390 px)").tag(390.0); Text("Tablet (820 px)").tag(820.0); Text("Desktop (1280 px)").tag(1280.0); Text("Wide (1920 px)").tag(1920.0)
                }.frame(maxWidth: 300)
            }
            HStack { Spacer(); Button(action: convert) { Label("Convert to PDF", systemImage: "arrow.right.circle.fill").padding(.horizontal, 20).padding(.vertical, 4) }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(runner.isRunning); Spacer() }
            ResultPanel(runner: runner)
        }
    }

    func convert() {
        var target: URL? = file
        if target == nil {
            var s = address.trimmingCharacters(in: .whitespaces)
            if !s.contains("://") { s = "https://" + s }
            guard let u = URL(string: s), u.host != nil else { runner.error = "Enter a valid web address."; return }
            target = u
        }
        let (u, p, l, m, w) = (target!, paper, landscape, CGFloat(margin), CGFloat(width))
        runner.run { dir, prog in
            prog.update("Loading \(u.host ?? u.lastPathComponent)…")
            let name = u.isFileURL ? u.baseName : (u.host ?? "webpage").replacingOccurrences(of: "www.", with: "")
            let dest = Workspace.uniqueURL(in: dir, name: name, ext: "pdf")
            try await WebPDF.render(url: u, baseURL: nil, out: dest, paper: p, landscape: l, margin: m, screenWidth: w)
            return ToolResult(files: [dest])
        }
    }
}

// MARK: - Convert from PDF

struct PDFToImagesTool: View {
    @Local private var extract = false
    @Local private var format = ImageConvert.ImageFormat.jpg
    @Local private var dpi: Double = 150
    @Local private var quality: Double = 0.85

    var body: some View {
        FileToolView(tool: .pdfToJPG, prompt: "Select PDF files", actionTitle: "Convert to Images", options: { _ in
            Picker("Mode", selection: $extract) { Text("Page to image").tag(false); Text("Extract embedded images").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 400)
            if !extract {
                Picker("Format", selection: $format) { ForEach(ImageConvert.ImageFormat.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 300)
                Picker("Resolution", selection: $dpi) { Text("72 DPI (screen)").tag(72.0); Text("150 DPI (normal)").tag(150.0); Text("300 DPI (print)").tag(300.0); Text("600 DPI").tag(600.0) }
                    .frame(maxWidth: 300)
                if format == .jpg { HStack { Text("Quality"); Slider(value: $quality, in: 0.3...1); Text("\(Int(quality * 100))%").monospacedDigit() }.frame(maxWidth: 400) }
            } else {
                Text("Every image embedded in the PDF is saved at its original resolution.").foregroundStyle(.secondary)
            }
        }, makeJob: { files in
            let (e, f, d, q) = (extract, format, CGFloat(dpi), quality)
            return { dir, p in e ? try ImageConvert.extractImages(files, out: dir) : try ImageConvert.pdfToImages(files, format: f, dpi: d, quality: q, out: dir, progress: p) }
        })
    }
}

struct PDFToWordTool: View {
    @Local private var format = TextExtract.WordFormat.docx
    @Local private var ocr = true
    @Local private var reflow = true
    var body: some View {
        FileToolView(tool: .pdfToWord, prompt: "Select PDF files", actionTitle: "Convert to Word", options: { _ in
            Picker("Format", selection: $format) { ForEach(TextExtract.WordFormat.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 320)
            Toggle("Recognize text on scanned pages (OCR)", isOn: $ocr)
            Toggle("Rejoin lines into paragraphs", isOn: $reflow)
        }, makeJob: { files in
            let (f, o, r) = (format, ocr, reflow)
            return { dir, p in try TextExtract.pdfToWord(files, format: f, ocr: o, reflowText: r, out: dir, progress: p) }
        })
    }
}

struct PDFToPowerPointTool: View {
    @Local private var dpi: Double = 200
    var body: some View {
        FileToolView(tool: .pdfToPPT, prompt: "Select PDF files", actionTitle: "Convert to PowerPoint", options: { _ in
            Picker("Slide image quality", selection: $dpi) { Text("Standard").tag(120.0); Text("High").tag(200.0); Text("Maximum").tag(300.0) }
                .pickerStyle(.segmented).frame(maxWidth: 360)
            Text("Each page becomes a slide. Opens in PowerPoint, Keynote and Google Slides.").font(.caption).foregroundStyle(.secondary)
        }, makeJob: { files in
            let d = CGFloat(dpi)
            return { dir, p in
                var out: [URL] = []
                for f in files {
                    let doc = try PDFCore.open(f)
                    let dest = Workspace.uniqueURL(in: dir, name: f.baseName, ext: "pptx")
                    try OOXMLWriter.pptx(doc, to: dest, dpi: d, progress: p)
                    out.append(dest)
                }
                return ToolResult(files: out)
            }
        })
    }
}

struct PDFToExcelTool: View {
    @Local private var oneSheet = false
    @Local private var csv = false
    var body: some View {
        FileToolView(tool: .pdfToExcel, prompt: "Select PDF files", actionTitle: "Convert to Excel", options: { _ in
            Picker("Format", selection: $csv) { Text("Excel (.xlsx)").tag(false); Text("CSV").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 300)
            if !csv { Toggle("Put all pages on one sheet", isOn: $oneSheet) }
            Text("Columns are detected from text positions. Scanned pages are read with OCR.").font(.caption).foregroundStyle(.secondary)
        }, makeJob: { files in
            let (o, c) = (oneSheet, csv)
            return { dir, p in try TextExtract.pdfToExcel(files, oneSheet: o, csv: c, out: dir, progress: p) }
        })
    }
}

struct PDFAToolView: View {
    var body: some View {
        FileToolView(tool: .pdfToPDFA, prompt: "Select PDF files", actionTitle: "Convert to PDF/A", options: { _ in
            Text("Produces PDF/A-2b: all fonts embedded, an sRGB output intent, XMP archival metadata, no encryption and flattened annotations.")
                .foregroundStyle(.secondary)
        }, makeJob: { files in { dir, p in try PDFOps.toPDFA(files, out: dir, progress: p) } })
    }
}

struct PDFToMarkdownTool: View {
    @Local private var ocr = true
    var body: some View {
        FileToolView(tool: .pdfToMarkdown, prompt: "Select PDF files", actionTitle: "Convert to Markdown", options: { _ in
            Toggle("Recognize text on scanned pages (OCR)", isOn: $ocr)
            Text("Headings are detected from font sizes; bullets, numbered lists and paragraphs are preserved.").font(.caption).foregroundStyle(.secondary)
        }, makeJob: { files in
            let o = ocr
            return { dir, _ in
                var out: [URL] = []
                for f in files {
                    let dest = Workspace.uniqueURL(in: dir, name: f.baseName, ext: "md")
                    try TextExtract.pdfToMarkdown(f, ocr: o).write(to: dest, atomically: true, encoding: .utf8)
                    out.append(dest)
                }
                return ToolResult(files: out)
            }
        })
    }
}

// MARK: - Edit

struct RotateTool: View {
    @Local private var degrees = 90
    @Local private var ranges = ""
    var body: some View {
        FileToolView(tool: .rotate, prompt: "Select PDF files to rotate", actionTitle: "Rotate PDF", options: { _ in
            Picker("Rotation", selection: $degrees) {
                Label("Left 90°", systemImage: "rotate.left").tag(270)
                Label("180°", systemImage: "arrow.uturn.down").tag(180)
                Label("Right 90°", systemImage: "rotate.right").tag(90)
            }
            .pickerStyle(.segmented).frame(maxWidth: 380)
            TextField("Pages (leave empty for all), e.g. 1, 3-5", text: $ranges).textFieldStyle(.roundedBorder).frame(maxWidth: 380)
            Text("To rotate individual pages visually, use Organize PDF.").font(.caption).foregroundStyle(.secondary)
        }, makeJob: { files in
            let (d, r) = (degrees, ranges)
            return { dir, _ in try PDFOps.rotate(files, degrees: d, ranges: r, out: dir) }
        })
    }
}

struct PageNumbersTool: View {
    @Local private var o = PDFOps.PageNumberOptions()
    var body: some View {
        FileToolView(tool: .pageNumbers, prompt: "Select PDF files", actionTitle: "Add Page Numbers", options: { _ in
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading) { Text("Position").font(.subheadline); PositionGrid(position: $o.position) }
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Facing pages (mirror left/right)", isOn: $o.facingPages)
                    Picker("Text", selection: $o.format) {
                        Text("1").tag("{n}"); Text("Page 1").tag("Page {n}"); Text("Page 1 of N").tag("Page {n} of {total}"); Text("1 / N").tag("{n} / {total}"); Text("- 1 -").tag("- {n} -")
                    }.frame(maxWidth: 260)
                    TextField("Custom format ({n} = number, {total} = total)", text: $o.format).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                }
            }
            HStack(spacing: 20) {
                Stepper("First number: \(o.firstNumber)", value: $o.firstNumber, in: 0...9999)
                Stepper("From page \(o.fromPage)", value: $o.fromPage, in: 1...9999)
                Stepper("To page: \(o.toPage == 0 ? "last" : String(o.toPage))", value: $o.toPage, in: 0...9999)
            }
            HStack(spacing: 20) {
                FontPicker(fontName: $o.fontName)
                Stepper("Size \(Int(o.fontSize))", value: $o.fontSize, in: 6...72)
                ColorPicker("Color", selection: $o.color.color)
                Stepper("Margin \(Int(o.margin))", value: $o.margin, in: 0...144, step: 4)
            }
        }, makeJob: { files in
            let opts = o
            return { dir, _ in try PDFOps.addPageNumbers(files, options: opts, out: dir) }
        })
    }
}

struct WatermarkTool: View {
    @Local private var o = PDFOps.WatermarkOptions()
    var body: some View {
        FileToolView(tool: .watermark, prompt: "Select PDF files", actionTitle: "Add Watermark", options: { _ in
            Picker("Type", selection: $o.useImage) { Text("Text").tag(false); Text("Image").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 260)
            if o.useImage {
                HStack {
                    Button("Choose Image…") { if let u = FilePicker.open(types: UTType.imageTypes, multiple: false)?.first { o.image = NSImage(contentsOf: u) } }
                    if let img = o.image { Image(nsImage: img).resizable().scaledToFit().frame(height: 44) }
                    HStack { Text("Size"); Slider(value: $o.imageScale, in: 0.1...1); Text("\(Int(o.imageScale * 100))% of width").monospacedDigit() }.frame(maxWidth: 360)
                }
            } else {
                TextField("Watermark text", text: $o.text).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                HStack(spacing: 20) {
                    FontPicker(fontName: $o.fontName)
                    Stepper("Size \(Int(o.fontSize))", value: $o.fontSize, in: 8...200, step: 4)
                    ColorPicker("Color", selection: $o.color.color)
                }
            }
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading) {
                    Text("Position").font(.subheadline)
                    PositionGrid(position: $o.position).disabled(o.mosaic).opacity(o.mosaic ? 0.4 : 1)
                    Toggle("Mosaic (tile)", isOn: $o.mosaic)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Rotation", selection: $o.rotation) { Text("0°").tag(CGFloat(0)); Text("45°").tag(CGFloat(45)); Text("90°").tag(CGFloat(90)); Text("180°").tag(CGFloat(180)); Text("270°").tag(CGFloat(270)); Text("315°").tag(CGFloat(315)) }
                        .pickerStyle(.segmented).frame(maxWidth: 340)
                    HStack { Text("Transparency"); Slider(value: $o.opacity, in: 0.05...1); Text("\(Int((1 - o.opacity) * 100))%").monospacedDigit() }.frame(maxWidth: 340)
                    Picker("Layer", selection: $o.below) { Text("Over content").tag(false); Text("Below content").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 300)
                    TextField("Pages (empty = all), e.g. 1-3", text: $o.ranges).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                }
            }
        }, makeJob: { files in
            let opts = o
            return { dir, _ in try PDFOps.watermark(files, options: opts, out: dir) }
        })
    }
}

// MARK: - Security

struct UnlockTool: View {
    @Local private var password = ""
    var body: some View {
        FileToolView(tool: .unlock, prompt: "Select protected PDF files", actionTitle: "Unlock PDF", options: { files in
            let locked = files.contains { PDFDocument(url: $0)?.isLocked == true }
            if locked {
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Text("Required to open these files.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("These files only have permission restrictions — they’ll be removed without a password.").foregroundStyle(.secondary)
            }
        }, makeJob: { files in
            let pw = password
            return { dir, _ in try PDFOps.unlock(files, password: pw, out: dir) }
        })
    }
}

struct ProtectTool: View {
    @Local private var password = ""
    @Local private var confirm = ""
    @Local private var owner = ""
    @Local private var perms = PDFOps.Permissions()
    @Local private var advanced = false

    var body: some View {
        FileToolView(tool: .protect, prompt: "Select PDF files to protect", actionTitle: "Protect PDF", options: { _ in
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
            SecureField("Repeat password", text: $confirm).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
            if !confirm.isEmpty && confirm != password { Text("Passwords don’t match.").font(.caption).foregroundStyle(.red) }
            DisclosureGroup("Permissions", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Owner password (optional, for changing permissions)", text: $owner).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    Toggle("Allow printing", isOn: $perms.printing)
                    Toggle("Allow copying text and images", isOn: $perms.copying)
                    Toggle("Allow editing", isOn: $perms.modifying)
                    Toggle("Allow inserting, deleting and rotating pages", isOn: $perms.assembling)
                    Toggle("Allow comments", isOn: $perms.annotating)
                    Toggle("Allow filling forms", isOn: $perms.formFilling)
                }
                .padding(.top, 6)
            }
        }, makeJob: { files in
            let (pw, c, o, p) = (password, confirm, owner, perms)
            return { dir, _ in
                guard pw == c else { throw ToolError.message("Passwords don’t match.") }
                return try PDFOps.protect(files, userPassword: pw, ownerPassword: o, permissions: p, out: dir)
            }
        })
    }
}
