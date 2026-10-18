import FoundationModels
import NaturalLanguage
import PDFKit
import SwiftUI
import Translation

// MARK: - Summarizer engine

enum Summarizer {
    enum Length: String, CaseIterable, Identifiable {
        case short = "Short", medium = "Medium", detailed = "Detailed"
        var id: String { rawValue }
        var instruction: String {
            switch self {
            case .short: return "in 3 to 5 key points"
            case .medium: return "in about 6 to 10 key points"
            case .detailed: return "thoroughly, covering every main section and important detail"
            }
        }
        var sentences: Int { switch self { case .short: return 4; case .medium: return 8; case .detailed: return 15 } }
    }
    enum Style: String, CaseIterable, Identifiable { case bullets = "Bullet points", paragraph = "Paragraphs"; var id: String { rawValue } }

    static var availability: (ok: Bool, reason: String) {
        guard #available(macOS 26, *) else {
            return (false, "Apple Intelligence summaries need macOS 26 — using the built-in extractive summarizer.")
        }
        switch SystemLanguageModel.default.availability {
        case .available: return (true, "Using on-device Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled): return (false, "Apple Intelligence is turned off — using the built-in extractive summarizer. Turn it on in System Settings for AI summaries.")
        case .unavailable(.modelNotReady): return (false, "The Apple Intelligence model is still downloading — using the built-in extractive summarizer for now.")
        case .unavailable(.deviceNotEligible): return (false, "This Mac doesn’t support Apple Intelligence — using the built-in extractive summarizer.")
        default: return (false, "Apple Intelligence is unavailable — using the built-in extractive summarizer.")
        }
    }

    static func chunks(_ text: String, size: Int = 6000) -> [String] {
        var out: [String] = [], cur = ""
        for para in text.components(separatedBy: "\n") {
            if cur.count + para.count > size, !cur.isEmpty { out.append(cur); cur = "" }
            if para.count > size {
                var rest = Substring(para)
                while !rest.isEmpty { out.append(String(rest.prefix(size))); rest = rest.dropFirst(size) }
            } else { cur += para + "\n" }
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }
        return out
    }

    static func summarize(_ text: String, length: Length, style: Style, progress: @escaping (String) -> Void) async throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 40 else { throw ToolError.message("There isn’t enough text to summarize.") }
        guard #available(macOS 26, *), availability.ok else { return extractive(clean, sentences: length.sentences, style: style) }
        return await aiSummary(clean, length: length, style: style, progress: progress)
    }

    @available(macOS 26, *)
    private static func aiSummary(_ clean: String, length: Length, style: Style, progress: @escaping (String) -> Void) async -> String {
        let format = style == .bullets ? "Use a Markdown bullet list." : "Write well-structured prose paragraphs."
        let instructions = "You are an expert editor who writes accurate, concise summaries. Only use facts from the provided text. Do not add commentary."
        var parts = chunks(clean)
        do {
            if parts.count > 1 {
                // Map: condense each chunk, then reduce.
                var notes: [String] = []
                for (i, c) in parts.enumerated() {
                    progress("Reading part \(i + 1) of \(parts.count)…")
                    let s = LanguageModelSession(instructions: instructions)
                    notes.append(try await s.respond(to: "Summarize the key information in this excerpt in a few bullet points:\n\n\(c)").content)
                }
                parts = chunks(notes.joined(separator: "\n"))
                while parts.count > 1 {
                    var merged: [String] = []
                    for c in parts {
                        let s = LanguageModelSession(instructions: instructions)
                        merged.append(try await s.respond(to: "Condense these notes, keeping the important points:\n\n\(c)").content)
                    }
                    parts = chunks(merged.joined(separator: "\n"))
                }
            }
            progress("Writing summary…")
            let s = LanguageModelSession(instructions: instructions)
            let r = try await s.respond(to: "Summarize the following document \(length.instruction). \(format) Start with a one-sentence overview.\n\n\(parts.first ?? clean)")
            return r.content
        } catch {
            return "_Apple Intelligence couldn’t process this text (\(error.localizedDescription)). Extractive summary:_\n\n" + extractive(clean, sentences: length.sentences, style: style)
        }
    }

    /// Frequency-based extractive summary (works offline on any Mac).
    static func extractive(_ text: String, sentences n: Int, style: Style) -> String {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var sentences: [String] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            if s.count > 25 && s.count < 600 { sentences.append(s) }
            return true
        }
        let words = NLTokenizer(unit: .word)
        var freq: [String: Double] = [:]
        func tokens(_ s: String) -> [String] {
            words.string = s
            return words.tokens(for: s.startIndex..<s.endIndex).map { s[$0].lowercased() }.filter { $0.count > 3 }
        }
        for s in sentences { for w in tokens(s) { freq[w, default: 0] += 1 } }
        let top = freq.values.max() ?? 1
        let scored = sentences.enumerated().map { i, s -> (Int, Double) in
            let t = tokens(s)
            let score = t.reduce(0) { $0 + (freq[$1] ?? 0) / top } / Double(max(t.count, 1)).squareRoot()
            return (i, score * (i < 3 ? 1.2 : 1)) // lead sentences are usually important
        }
        let picked = scored.sorted { $0.1 > $1.1 }.prefix(n).map(\.0).sorted()
        let chosen = picked.map { sentences[$0] }
        return style == .bullets ? chosen.map { "- \($0)" }.joined(separator: "\n") : chosen.joined(separator: " ")
    }
}

// MARK: - Summarizer view

struct SummarizeTool: View {
    @Local private var usePDF = true
    @Local private var file: URL?
    @Local private var pasted = ""
    @Local private var length = Summarizer.Length.medium
    @Local private var style = Summarizer.Style.bullets
    @Local private var output = ""
    @Local private var status = ""
    @Local private var busy = false
    @Local private var error: String?

    var body: some View {
        ToolPage(tool: .summarize) {
            let avail = Summarizer.availability
            Label(avail.reason, systemImage: avail.ok ? "apple.intelligence" : "info.circle").foregroundStyle(.secondary)
            Picker("", selection: $usePDF) { Text("PDF file").tag(true); Text("Paste text").tag(false) }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
            if usePDF {
                if let file { HStack { FileRow(url: file); Spacer(); Button("Change") { self.file = nil; output = "" } } }
                else { DropZone(types: [.pdf], multiple: false, prompt: "Select a PDF to summarize") { file = $0[0] } }
            } else {
                TextEditor(text: $pasted).font(.body).frame(minHeight: 180).border(Color.secondary.opacity(0.3))
            }
            OptionsBox {
                Picker("Length", selection: $length) { ForEach(Summarizer.Length.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 360)
                Picker("Format", selection: $style) { ForEach(Summarizer.Style.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 360)
            }
            HStack {
                Spacer()
                Button { run() } label: { Label("Summarize", systemImage: "sparkles").padding(.horizontal, 20).padding(.vertical, 4) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy || (usePDF ? file == nil : pasted.isEmpty))
                Spacer()
            }
            if busy { HStack { ProgressView().controlSize(.small); Text(status).foregroundStyle(.secondary) } }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            if !output.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text((try? AttributedString(markdown: output, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(output))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            Button { save() } label: { Label("Save as Markdown…", systemImage: "square.and.arrow.down") }
                        }
                    }.padding(8)
                } label: { Text("Summary").font(.headline) }
            }
        }
    }

    private func run() {
        busy = true; error = nil; output = ""; status = "Reading document…"
        let (f, text, l, s, pdf) = (file, pasted, length, style, usePDF)
        Task {
            do {
                let source: String
                if pdf, let f {
                    source = try await Task.detached {
                        let doc = try PDFCore.open(f)
                        return (0..<doc.pageCount).compactMap { doc.page(at: $0).map { TextExtract.pageText($0, ocrIfEmpty: true) } }.joined(separator: "\n")
                    }.value
                } else { source = text }
                output = try await Summarizer.summarize(source, length: l, style: s) { msg in Task { @MainActor in status = msg } }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func save() {
        let p = NSSavePanel()
        p.nameFieldStringValue = (file?.baseName ?? "summary") + " summary.md"
        guard p.runModal() == .OK, let u = p.url else { return }
        try? output.write(to: u, atomically: true, encoding: .utf8)
    }
}

// MARK: - Translate

struct TranslateTool: View {
    @Local private var file: URL?
    @Local private var languages: [Locale.Language] = []
    @Local private var source = "auto"
    @Local private var target = Locale.current.language.languageCode?.identifier == "en" ? "es" : "en"
    @Local private var keepLayout = true
    @Local private var config: TranslationSession.Configuration?
    @Local private var units: [TranslationUnit] = []
    @StateObject private var runner = Runner()

    var body: some View {
        ToolPage(tool: .translate) {
            if let file { HStack { FileRow(url: file); Spacer(); Button("Change") { self.file = nil; runner.reset() } } }
            else { DropZone(types: [.pdf], multiple: false, prompt: "Select a PDF to translate") { file = $0[0] } }
            OptionsBox {
                HStack(spacing: 16) {
                    Picker("From", selection: $source) {
                        Text("Detect language").tag("auto")
                        Divider()
                        ForEach(languages, id: \.minimalIdentifier) { Text(name($0)).tag($0.minimalIdentifier) }
                    }.frame(maxWidth: 260)
                    Image(systemName: "arrow.right")
                    Picker("To", selection: $target) {
                        ForEach(languages, id: \.minimalIdentifier) { Text(name($0)).tag($0.minimalIdentifier) }
                    }.frame(maxWidth: 260)
                }
                Picker("Output", selection: $keepLayout) { Text("PDF, keep layout").tag(true); Text("Word document (.docx)").tag(false) }.pickerStyle(.radioGroup)
                Text("Translation runs on-device. The first time you use a language pair, macOS may ask to download it.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button { start() } label: { Label("Translate", systemImage: "character.bubble").padding(.horizontal, 20).padding(.vertical, 4) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(file == nil || runner.isRunning)
                Spacer()
            }
            ResultPanel(runner: runner)
        }
        .task {
            let langs = await LanguageAvailability().supportedLanguages
            languages = langs.sorted { name($0) < name($1) }
        }
        .translationTask(config) { session in await translate(session) }
    }

    private func name(_ l: Locale.Language) -> String { Locale.current.localizedString(forIdentifier: l.minimalIdentifier) ?? l.minimalIdentifier }

    private func start() {
        guard let file else { return }
        runner.isRunning = true
        runner.error = nil
        runner.result = nil
        runner.status = "Extracting text…"
        let layout = keepLayout
        Task {
            do {
                units = try await Task.detached { try TranslationUnit.extract(file, layout: layout) }.value
                guard !units.isEmpty else { throw ToolError.message("No text found in this PDF. Run OCR PDF first if it’s a scan.") }
                runner.status = "Translating \(units.count) passages…"
                let src = source == "auto" ? nil : Locale.Language(identifier: source)
                let tgt = Locale.Language(identifier: target)
                if config?.source == src && config?.target == tgt { config?.invalidate() }
                else { config = TranslationSession.Configuration(source: src, target: tgt) }
            } catch {
                runner.error = error.localizedDescription
                runner.isRunning = false
            }
        }
    }

    private func translate(_ session: TranslationSession) async {
        guard let file, !units.isEmpty else { return }
        do {
            var out = [String](repeating: "", count: units.count)
            let requests = units.enumerated().map { TranslationSession.Request(sourceText: $1.text, clientIdentifier: String($0)) }
            var done = 0
            for start in stride(from: 0, to: requests.count, by: 80) {
                let batch = Array(requests[start..<min(start + 80, requests.count)])
                for r in try await session.translations(from: batch) {
                    if let id = r.clientIdentifier, let i = Int(id) { out[i] = r.targetText }
                }
                done += batch.count
                runner.status = "Translated \(done) of \(requests.count) passages…"
                runner.progress = Double(done) / Double(requests.count)
            }
            let (u, layout, tgt) = (units, keepLayout, target)
            let result = try await Task.detached { try TranslationUnit.build(file, units: u, translations: out, layout: layout, language: tgt) }.value
            runner.result = result
        } catch {
            runner.error = "Translation failed: \(error.localizedDescription)"
        }
        runner.isRunning = false
        runner.progress = nil
    }
}

struct TranslationUnit: Sendable {
    let page: Int
    let text: String
    let rect: CGRect // upright
    let fontSize: CGFloat

    static func extract(_ url: URL, layout: Bool) throws -> [TranslationUnit] {
        let doc = try PDFCore.open(url)
        var out: [TranslationUnit] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if layout {
                for line in page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? [] {
                    let t = (line.string ?? "").trimmingCharacters(in: .whitespaces)
                    guard t.contains(where: \.isLetter) else { continue }
                    let font = line.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    let r = PDFCore.pageToUpright(line.bounds(for: page), page: page)
                    out.append(TranslationUnit(page: i, text: t, rect: r, fontSize: font?.pointSize ?? r.height * 0.8))
                }
            } else {
                for para in TextExtract.reflow(page.string ?? "").components(separatedBy: "\n") {
                    let t = para.trimmingCharacters(in: .whitespaces)
                    if t.contains(where: \.isLetter) { out.append(TranslationUnit(page: i, text: t, rect: .zero, fontSize: 12)) }
                }
            }
        }
        return out
    }

    static func build(_ url: URL, units: [TranslationUnit], translations: [String], layout: Bool, language: String) throws -> ToolResult {
        let dir = try Workspace.newOutputDir()
        let doc = try PDFCore.open(url)
        if layout {
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_\(language)", ext: "pdf")
            try PDFCore.render(doc, to: dest, over: { i, _, _, _ in
                for (k, u) in units.enumerated() where u.page == i {
                    let t = translations[k].isEmpty ? u.text : translations[k]
                    NSColor.white.setFill()
                    u.rect.insetBy(dx: -0.5, dy: -0.5).fill()
                    var size = max(3, min(u.fontSize, u.rect.height * 1.1))
                    var s = NSAttributedString(string: t, attributes: [.font: NSFont(name: "Helvetica", size: size)!, .foregroundColor: NSColor.black])
                    let w = s.size().width
                    if w > u.rect.width, u.rect.width > 0 {
                        size = max(3, size * u.rect.width / w)
                        s = NSAttributedString(string: t, attributes: [.font: NSFont(name: "Helvetica", size: size)!, .foregroundColor: NSColor.black])
                    }
                    s.draw(at: CGPoint(x: u.rect.minX, y: u.rect.midY - s.size().height / 2))
                }
            })
            return ToolResult(files: [dest])
        } else {
            let result = NSMutableAttributedString()
            var lastPage = 0
            for (k, u) in units.enumerated() {
                if u.page != lastPage { result.append(NSAttributedString(string: "\u{0C}")); lastPage = u.page }
                result.append(NSAttributedString(string: (translations[k].isEmpty ? u.text : translations[k]) + "\n\n",
                                                 attributes: [.font: NSFont(name: "Helvetica", size: 12)!]))
            }
            let dest = Workspace.uniqueURL(in: dir, name: "\(url.baseName)_\(language)", ext: "docx")
            try result.data(from: NSRange(location: 0, length: result.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: dest)
            return ToolResult(files: [dest])
        }
    }
}
