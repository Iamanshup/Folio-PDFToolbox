# Folio — PDF Toolbox for Mac

Folio is a native macOS app with every tool you need to work with PDFs: merge, split, compress, convert, edit, sign, redact, OCR, translate and more. **Everything runs locally on your Mac — your files are never uploaded anywhere.**

## Install

### Homebrew

```sh
brew install --cask iamanshup/tap/folio
```

### DMG

Download the latest `Folio-x.y.z.dmg` from [Releases](https://github.com/Iamanshup/Folio-PDFToolbox/releases), open it and drag **Folio** into **Applications**.

> Folio isn't notarized by Apple. The first time you open it, macOS will say it "could not verify" Folio: click **Done**, then open **System Settings › Privacy & Security** and click **Open Anyway**. This is needed once.

**Requirements:** macOS 15 (Sequoia) or later on Apple silicon. AI summaries use Apple Intelligence on macOS 26 and later; on macOS 15 the summarizer uses its built-in offline method.

## Tools

| Category | Tools |
|---|---|
| **Organize** | Merge PDF · Split PDF (custom/fixed ranges, extract pages) · Organize PDF (drag to reorder, rotate, delete, duplicate, insert blank pages, combine files) · Scan to PDF (iPhone/iPad via Continuity Camera, scanners, or photos with automatic edge detection) |
| **Optimize** | Compress PDF (3 levels) · Repair PDF (rebuilds damaged cross-reference tables) · OCR PDF (makes scans searchable and selectable) |
| **Convert to PDF** | JPG/images · Word · PowerPoint · Excel · HTML/web pages |
| **Convert from PDF** | PDF to JPG/PNG/TIFF (or extract embedded images) · PDF to Word (DOCX, DOC, RTF, ODT, TXT) · PDF to PowerPoint · PDF to Excel (XLSX/CSV with table detection) · PDF to PDF/A · PDF to Markdown |
| **Edit** | Rotate · Page numbers · Watermark (text or image, tiled, over/under content) · Crop (drag, margins, or auto-detect) · Edit PDF (text, images, shapes, lines, freehand, highlight, whiteout) · PDF Forms (fill, create fields, auto-detect fields) |
| **Security** | Unlock · Protect (password + permissions) · Sign (draw, type or upload; signatures are saved) · Redact (search, patterns like emails/phones/cards, true removal) · Compare (text diff + visual overlay) |
| **Intelligence** | AI Summarizer (on-device Apple Intelligence, with an offline fallback) · Translate PDF (on-device, keeps the layout or exports .docx) |

### Working with Folio

- **Open files any way you like:** drag them onto a tool, use **File › Open…** (⌘O), drop them on the Dock icon, or choose **Open With › Folio** in Finder. Folio then suggests the tools that accept them.
- **Results save automatically**, next to the original file by default. Choose Downloads, a fixed folder, or "Ask each time" in **Folio › Settings** (⌘,). Jobs that create many files get their own folder.
- **Previews:** file lists show page thumbnails; Split shows which pages go into each output file, and Rotate previews the result.
- **Editors** (Edit, Sign, Redact, Forms) support undo/redo (⌘Z / ⇧⌘Z), zoom (⌘= / ⌘- / ⌘0 or pinch) and keyboard shortcuts: Delete, arrow keys to nudge (Shift for 10 pt), Esc, ⌘D to duplicate, and V T I R O L D H W X to switch tools.
- **Favorites and Recent:** star a tool (or right-click it) to pin it to the top of the sidebar and home screen.

### How it works

Folio is built entirely on Apple frameworks — no third-party dependencies:

- **PDFKit / CoreGraphics** for reading, editing and writing PDFs
- **Vision** for OCR and document edge detection
- **WebKit** for HTML → PDF
- **Pages, Keynote and Numbers** (when installed) for high-fidelity Office → PDF, with built-in fallbacks for DOCX, XLSX, CSV and PPTX
- **Foundation Models** (Apple Intelligence) for summaries and **Translation** for on-device translation

## Build from source

Only the Xcode Command Line Tools are needed (full Xcode is not required).

```sh
git clone https://github.com/Iamanshup/Folio-PDFToolbox.git
cd Folio-PDFToolbox
./Scripts/build-app.sh          # → build/Folio.app
./Scripts/make-dmg.sh 1.0.0     # → build/Folio-1.0.0.dmg
```

### Self-test

A headless suite runs 59 end-to-end checks over generated documents for every engine:

```sh
swift build && .build/debug/Folio --selftest /tmp
```

### Project layout

```
Sources/Folio/
  App.swift              App entry, sidebar navigation, home screen
  Tools.swift            Tool catalog (names, icons, categories, routing)
  Components.swift       Shared UI: drop zone, file list, job runner, results
  ToolViews.swift        Form-style tools (merge, split, compress, convert…)
  Editor.swift           Page canvas editor used by Edit, Sign, Redact, Forms
  InteractiveViews.swift Edit, Sign, Redact, Forms, Crop, Organize, Compare, Scan
  AIViews.swift          Summarizer and Translate
  DeviceViews.swift      Continuity Camera and scanner integration
  PDFCore.swift          Rendering pipeline, coordinates, organize/security ops
  Convert.swift          Image, Office, HTML, DOCX/XLSX/PPTX/Markdown conversion
  OCR.swift              Vision OCR, searchable PDFs, scan processing
  SelfTest.swift         End-to-end engine checks
  Local.swift            @Local, a stand-in for @State (see below)
```

`@Local` replaces SwiftUI's `@State`: in the current SDK `@State` is a macro whose compiler plugin ships only with full Xcode, so `@Local` (built on `@StateObject`) keeps the project buildable with the Command Line Tools alone.

## Known limitations

- PDF → PowerPoint creates one image slide per page (text isn't editable).
- "Keep layout" translation covers the original text with white boxes; the original text remains hidden underneath.
- PDF/A output includes the required archival structures but hasn't been checked with a PDF/A validator.
- Watermark, page numbers, signing and editing flatten existing links and form fields.
