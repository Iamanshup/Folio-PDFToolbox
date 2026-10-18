import SwiftUI

enum ToolCategory: String, CaseIterable, Identifiable {
    case organize = "Organize PDF"
    case optimize = "Optimize PDF"
    case toPDF = "Convert to PDF"
    case fromPDF = "Convert from PDF"
    case edit = "Edit PDF"
    case security = "PDF Security"
    case intelligence = "PDF Intelligence"
    var id: String { rawValue }
}

enum Tool: String, CaseIterable, Identifiable, Hashable {
    case merge, split, organize, scan
    case compress, repair, ocr
    case jpgToPDF, wordToPDF, pptToPDF, excelToPDF, htmlToPDF
    case pdfToJPG, pdfToWord, pdfToPPT, pdfToExcel, pdfToPDFA, pdfToMarkdown
    case rotate, pageNumbers, watermark, crop, edit, forms
    case unlock, protect, sign, redact, compare
    case summarize, translate

    var id: String { rawValue }

    var category: ToolCategory {
        switch self {
        case .merge, .split, .organize, .scan: return .organize
        case .compress, .repair, .ocr: return .optimize
        case .jpgToPDF, .wordToPDF, .pptToPDF, .excelToPDF, .htmlToPDF: return .toPDF
        case .pdfToJPG, .pdfToWord, .pdfToPPT, .pdfToExcel, .pdfToPDFA, .pdfToMarkdown: return .fromPDF
        case .rotate, .pageNumbers, .watermark, .crop, .edit, .forms: return .edit
        case .unlock, .protect, .sign, .redact, .compare: return .security
        case .summarize, .translate: return .intelligence
        }
    }

    var title: String {
        switch self {
        case .merge: return "Merge PDF"
        case .split: return "Split PDF"
        case .organize: return "Organize PDF"
        case .scan: return "Scan to PDF"
        case .compress: return "Compress PDF"
        case .repair: return "Repair PDF"
        case .ocr: return "OCR PDF"
        case .jpgToPDF: return "JPG to PDF"
        case .wordToPDF: return "Word to PDF"
        case .pptToPDF: return "PowerPoint to PDF"
        case .excelToPDF: return "Excel to PDF"
        case .htmlToPDF: return "HTML to PDF"
        case .pdfToJPG: return "PDF to JPG"
        case .pdfToWord: return "PDF to Word"
        case .pdfToPPT: return "PDF to PowerPoint"
        case .pdfToExcel: return "PDF to Excel"
        case .pdfToPDFA: return "PDF to PDF/A"
        case .pdfToMarkdown: return "PDF to Markdown"
        case .rotate: return "Rotate PDF"
        case .pageNumbers: return "Page Numbers"
        case .watermark: return "Watermark"
        case .crop: return "Crop PDF"
        case .edit: return "Edit PDF"
        case .forms: return "PDF Forms"
        case .unlock: return "Unlock PDF"
        case .protect: return "Protect PDF"
        case .sign: return "Sign PDF"
        case .redact: return "Redact PDF"
        case .compare: return "Compare PDF"
        case .summarize: return "AI Summarizer"
        case .translate: return "Translate PDF"
        }
    }

    var subtitle: String {
        switch self {
        case .merge: return "Combine PDFs in the order you want."
        case .split: return "Separate one page or a whole set into independent PDF files."
        case .organize: return "Sort, delete, rotate and add pages to your PDF."
        case .scan: return "Capture documents with your iPhone, a scanner, or photos."
        case .compress: return "Reduce file size while optimizing for maximal quality."
        case .repair: return "Recover data from a damaged or corrupt PDF."
        case .ocr: return "Make scanned PDFs searchable and selectable."
        case .jpgToPDF: return "Convert images to PDF. Adjust orientation and margins."
        case .wordToPDF: return "Convert DOC, DOCX, RTF and ODT documents to PDF."
        case .pptToPDF: return "Convert PPT and PPTX slideshows to PDF."
        case .excelToPDF: return "Convert Excel spreadsheets to PDF."
        case .htmlToPDF: return "Convert web pages to PDF from a URL or HTML file."
        case .pdfToJPG: return "Convert each page to JPG or extract all embedded images."
        case .pdfToWord: return "Convert PDFs into editable DOCX documents."
        case .pdfToPPT: return "Turn PDF pages into a PPTX slideshow."
        case .pdfToExcel: return "Pull tables straight out of PDFs into spreadsheets."
        case .pdfToPDFA: return "Convert to PDF/A, the ISO standard for long-term archiving."
        case .pdfToMarkdown: return "Turn PDFs into Markdown with headings and lists."
        case .rotate: return "Rotate pages of one or many PDFs at once."
        case .pageNumbers: return "Add page numbers with your choice of position and typography."
        case .watermark: return "Stamp an image or text over your PDF."
        case .crop: return "Crop margins or select a specific area."
        case .edit: return "Add text, images, shapes and freehand drawings."
        case .forms: return "Fill forms, or create fillable fields."
        case .unlock: return "Remove password security from PDFs."
        case .protect: return "Encrypt PDFs with a password and set permissions."
        case .sign: return "Draw, type or upload your signature and place it."
        case .redact: return "Permanently remove sensitive text and graphics."
        case .compare: return "Compare two versions side by side and spot the changes."
        case .summarize: return "Generate concise summaries using on-device Apple Intelligence."
        case .translate: return "Translate PDFs on-device while keeping the layout."
        }
    }

    var symbol: String {
        switch self {
        case .merge: return "arrow.triangle.merge"
        case .split: return "scissors"
        case .organize: return "square.grid.2x2"
        case .scan: return "doc.viewfinder"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .repair: return "wrench.and.screwdriver"
        case .ocr: return "text.viewfinder"
        case .jpgToPDF: return "photo.on.rectangle"
        case .wordToPDF: return "doc.richtext"
        case .pptToPDF: return "rectangle.on.rectangle.angled"
        case .excelToPDF: return "tablecells"
        case .htmlToPDF: return "globe"
        case .pdfToJPG: return "photo"
        case .pdfToWord: return "doc.text"
        case .pdfToPPT: return "play.rectangle"
        case .pdfToExcel: return "tablecells.badge.ellipsis"
        case .pdfToPDFA: return "archivebox"
        case .pdfToMarkdown: return "number"
        case .rotate: return "rotate.right"
        case .pageNumbers: return "list.number"
        case .watermark: return "drop"
        case .crop: return "crop"
        case .edit: return "pencil.and.outline"
        case .forms: return "checklist"
        case .unlock: return "lock.open"
        case .protect: return "lock.shield"
        case .sign: return "signature"
        case .redact: return "rectangle.fill.badge.xmark"
        case .compare: return "rectangle.split.2x1"
        case .summarize: return "sparkles"
        case .translate: return "character.bubble"
        }
    }

    var color: Color {
        switch category {
        case .organize: return .red
        case .optimize: return .green
        case .toPDF: return .orange
        case .fromPDF: return .blue
        case .edit: return .purple
        case .security: return .indigo
        case .intelligence: return .pink
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .merge: MergeTool()
        case .split: SplitTool()
        case .organize: OrganizeTool()
        case .scan: ScanTool()
        case .compress: CompressTool()
        case .repair: RepairTool()
        case .ocr: OCRTool()
        case .jpgToPDF: ImagesToPDFTool()
        case .wordToPDF: OfficeToPDFTool(kind: .word)
        case .pptToPDF: OfficeToPDFTool(kind: .powerpoint)
        case .excelToPDF: OfficeToPDFTool(kind: .excel)
        case .htmlToPDF: HTMLToPDFTool()
        case .pdfToJPG: PDFToImagesTool()
        case .pdfToWord: PDFToWordTool()
        case .pdfToPPT: PDFToPowerPointTool()
        case .pdfToExcel: PDFToExcelTool()
        case .pdfToPDFA: PDFAToolView()
        case .pdfToMarkdown: PDFToMarkdownTool()
        case .rotate: RotateTool()
        case .pageNumbers: PageNumbersTool()
        case .watermark: WatermarkTool()
        case .crop: CropTool()
        case .edit: EditTool()
        case .forms: FormsTool()
        case .unlock: UnlockTool()
        case .protect: ProtectTool()
        case .sign: SignTool()
        case .redact: RedactTool()
        case .compare: CompareTool()
        case .summarize: SummarizeTool()
        case .translate: TranslateTool()
        }
    }
}
