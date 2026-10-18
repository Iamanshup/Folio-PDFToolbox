import AppKit
import ImageCaptureCore
import PDFKit
import Quartz
import SwiftUI

// MARK: - Continuity Camera ("Import from iPhone or iPad")

struct ContinuityCameraButton: NSViewRepresentable {
    let onImages: ([CGImage]) -> Void

    func makeNSView(context: Context) -> CameraButton {
        let b = CameraButton(title: "Import from iPhone…", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.onImages = onImages
        b.target = b
        b.action = #selector(CameraButton.showMenu)
        return b
    }

    func updateNSView(_ v: CameraButton, context: Context) { v.onImages = onImages }

    /// The system fills a menu item tagged `importFromDeviceIdentifier` with "Take Photo" / "Scan Documents"
    /// for nearby devices and returns the result through the services pasteboard protocol.
    final class CameraButton: NSButton, NSServicesMenuRequestor {
        var onImages: (([CGImage]) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        @objc func showMenu() {
            window?.makeFirstResponder(self)
            let menu = NSMenu()
            let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
            item.identifier = NSMenuItem.importFromDeviceIdentifier
            menu.addItem(item)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        }

        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
            if let r = returnType, sendType == nil, [.pdf, .tiff, .png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")].contains(r) {
                return self
            }
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }

        func readSelection(from pboard: NSPasteboard) -> Bool {
            if let data = pboard.data(forType: .pdf), let doc = PDFDocument(data: data) {
                let images = (0..<doc.pageCount).compactMap { doc.page(at: $0).flatMap { PDFCore.image(of: $0, scale: 2.5) } }
                onImages?(images)
                return !images.isEmpty
            }
            if let img = NSImage(pasteboard: pboard), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                onImages?([cg])
                return true
            }
            return false
        }

        func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
    }
}

// MARK: - Scanners (ImageKit)

struct ScannerView: NSViewRepresentable {
    let onScan: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let browser = IKDeviceBrowserView(frame: .zero)
        browser.mode = .outline
        browser.displaysLocalScanners = true
        browser.displaysNetworkScanners = true
        browser.displaysLocalCameras = false
        browser.displaysNetworkCameras = false
        browser.delegate = context.coordinator

        let scanner = IKScannerDeviceView(frame: .zero)
        scanner.mode = .simple
        scanner.transferMode = .fileBased
        scanner.hasDisplayModeSimple = true
        scanner.hasDisplayModeAdvanced = true
        scanner.displaysDownloadsDirectoryControl = false
        scanner.displaysPostProcessApplicationControl = false
        scanner.downloadsDirectory = FileManager.default.temporaryDirectory
        scanner.documentName = "Scan"
        scanner.delegate = context.coordinator
        context.coordinator.scannerView = scanner

        let empty = NSTextField(labelWithString: "Select a scanner on the left. Connected and network scanners appear automatically.")
        empty.textColor = .secondaryLabelColor
        context.coordinator.placeholder = empty

        for v in [browser, scanner, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
        NSLayoutConstraint.activate([
            browser.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            browser.topAnchor.constraint(equalTo: container.topAnchor),
            browser.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            browser.widthAnchor.constraint(equalToConstant: 220),
            scanner.leadingAnchor.constraint(equalTo: browser.trailingAnchor),
            scanner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scanner.topAnchor.constraint(equalTo: container.topAnchor),
            scanner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scanner.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scanner.centerYAnchor),
        ])
        scanner.isHidden = true
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator: NSObject, IKDeviceBrowserViewDelegate, IKScannerDeviceViewDelegate {
        let onScan: (URL) -> Void
        weak var scannerView: IKScannerDeviceView?
        weak var placeholder: NSView?
        init(onScan: @escaping (URL) -> Void) { self.onScan = onScan }

        func deviceBrowserView(_ deviceBrowserView: IKDeviceBrowserView, selectionDidChange device: ICDevice?) {
            if let s = device as? ICScannerDevice {
                scannerView?.scannerDevice = s
                scannerView?.isHidden = false
                placeholder?.isHidden = true
            } else {
                scannerView?.isHidden = true
                placeholder?.isHidden = false
            }
        }

        func deviceBrowserView(_ deviceBrowserView: IKDeviceBrowserView, didEncounterError error: Error) {}

        func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView, didScanTo url: URL, error: Error?) {
            if error == nil { DispatchQueue.main.async { self.onScan(url) } }
        }
    }
}
