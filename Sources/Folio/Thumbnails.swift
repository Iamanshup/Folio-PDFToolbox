import AppKit
import ImageIO
import PDFKit
import SwiftUI

/// Renders and caches page/image thumbnails off the main thread.
actor ThumbnailRenderer {
    static let shared = ThumbnailRenderer()

    private var docs: [URL: PDFDocument] = [:]
    private var order: [URL] = []
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 600 }

    func pageCount(_ url: URL) -> Int { document(url)?.pageCount ?? 0 }

    func thumbnail(_ url: URL, page: Int, maxSize: CGFloat) -> NSImage? {
        let key = "\(url.path)#\(page)#\(Int(maxSize))#\(modDate(url))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var img: NSImage?
        if url.pathExtension.lowercased() == "pdf" {
            if let p = document(url)?.page(at: page) { img = p.thumbnail(of: CGSize(width: maxSize, height: maxSize), for: .cropBox) }
        } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxSize]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { img = NSImage(cgImage: cg, size: .zero) }
        }
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    private func modDate(_ url: URL) -> Int {
        Int(((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
    }

    private func document(_ url: URL) -> PDFDocument? {
        if let d = docs[url] { return d }
        guard let d = PDFDocument(url: url), !d.isLocked else { return nil }
        docs[url] = d
        order.append(url)
        if order.count > 12 { docs[order.removeFirst()] = nil } // keep memory bounded
        return d
    }
}

/// A page thumbnail that loads asynchronously.
struct PageThumb: View {
    let url: URL
    var page = 0
    var maxSize: CGFloat = 220
    @Local private var image: NSImage?
    @Local private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            } else if failed {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.12))
            }
        }
        .task(id: "\(url.path)#\(page)") {
            image = await ThumbnailRenderer.shared.thumbnail(url, page: page, maxSize: maxSize)
            failed = image == nil
        }
        .accessibilityLabel("Page \(page + 1) of \(url.lastPathComponent)")
    }
}

/// Grid of every page in a PDF. `groups` colors pages by output file (e.g. split ranges);
/// pages outside all groups are dimmed. `rotations` previews extra rotation per page.
struct PageGrid: View {
    let url: URL
    var groups: [[Int]] = []
    var rotations: [Int: Int] = [:]
    var caption: String? = nil
    @Local private var count = 0

    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo, .brown, .mint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
                    ForEach(0..<count, id: \.self) { i in cell(i) }
                }
                .padding(10)
            }
            .frame(height: min(CGFloat((count + 6) / 7) * 150 + 20, 330))
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor)))
        }
        .task(id: url) { count = await ThumbnailRenderer.shared.pageCount(url) }
    }

    private func cell(_ i: Int) -> some View {
        let g = groups.firstIndex { $0.contains(i) }
        let color = g.map { Self.palette[$0 % Self.palette.count] }
        let dim = !groups.isEmpty && g == nil
        return VStack(spacing: 4) {
            PageThumb(url: url, page: i, maxSize: 200)
                .rotationEffect(.degrees(Double(rotations[i] ?? 0)))
                .animation(.easeInOut(duration: 0.25), value: rotations[i] ?? 0)
                .frame(width: 84, height: 104)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color ?? .clear, lineWidth: 2.5))
            HStack(spacing: 4) {
                if let g, let color { Text("\(g + 1)").font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 4).background(Capsule().fill(color)) }
                Text("\(i + 1)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(dim ? 0.35 : 1)
        .accessibilityElement(children: .combine)
    }
}
