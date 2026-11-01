import AppKit
import SwiftUI

/// A mark drawn on a screenshot, in the image's own unit square — 0…1 across
/// and down — so it lands in the same place at the size it is drawn at and at
/// the screenshot's full resolution.
struct SimulatorMark: Equatable {
    enum Tool: CaseIterable {
        case pen, rectangle, arrow

        var title: String {
            switch self {
            case .pen: localized("Pen")
            case .rectangle: localized("Rectangle")
            case .arrow: localized("Arrow")
            }
        }

        var symbol: String {
            switch self {
            case .pen: "scribble"
            case .rectangle: "rectangle"
            case .arrow: "arrow.up.right"
            }
        }
    }

    let tool: Tool
    var points: [CGPoint]

    /// The mark as a path in a `size` box, top-left origin.
    func path(in size: CGSize) -> Path {
        let scaled = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        var path = Path()
        guard let first = scaled.first, let last = scaled.last else { return path }
        switch tool {
        case .pen:
            path.addLines(scaled)
        case .rectangle:
            path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .arrow:
            path.move(to: first)
            path.addLine(to: last)
            // The head: two strokes back from the tip, a fixed share of the box.
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(size.width, size.height) * 0.03
            for side in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x + head * cos(angle + side), y: last.y + head * sin(angle + side)))
            }
        }
        return path
    }

    /// Stroke width for a `size` box: a share of its width, so a mark is as
    /// heavy on the full-resolution PNG as on the editor's smaller drawing.
    static func lineWidth(in size: CGSize) -> CGFloat { max(2, size.width * 0.008) }
}

/// The marks drawn on top of the screenshot, as one PNG at the screenshot's
/// own pixel size. Nil when the screenshot can't be read or the PNG written.
@MainActor
enum SimulatorAnnotationRenderer {
    static func render(_ source: NSImage, marks: [SimulatorMark]) -> Data? {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        guard let context = CGContext(
            data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        // Marks are measured from the top; the context counts from the bottom.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(SimulatorAnnotationEditor.ink.cgColor)
        context.setLineWidth(SimulatorMark.lineWidth(in: size))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            context.addPath(mark.path(in: size).cgPath)
            context.strokePath()
        }
        guard let rendered = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
    }
}

/// What Annotate is drawing on: the screenshot and the device it came from.
struct SimulatorAnnotationSource: Identifiable {
    let url: URL
    let deviceName: String
    var id: URL { url }
}

extension SimulatorHost {
    /// Annotate from the header: a fresh screenshot, kept out of the Desktop —
    /// it exists to be drawn on and handed to a chat, not to be filed.
    func annotate(_ screen: SimulatorScreen) async throws {
        let url = try Self.annotationFile("Simulator Screenshot", screen.name)
        _ = try await call("screenshot", ["udid": screen.udid, "path": url.path])
        annotating = SimulatorAnnotationSource(url: url, deviceName: screen.name)
    }

    /// Where annotations and the screenshots taken for them are written: the
    /// app's cache, which the system may empty — by then the chat has read it.
    static func annotationFile(_ kind: String, _ device: String) throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw SimulatorHostError.failed(localized("Couldn’t find the caches folder."))
        }
        let folder = caches.appendingPathComponent("termio/Simulator Annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folder.appendingPathComponent("\(kind) - \(device) - \(formatter.string(from: Date())).png")
    }
}

/// Annotate: draw on a screenshot and add it to the chat with a note saying
/// what it is, so the agent reads the marks as the person pointing at the
/// screen. Pen, rectangle and arrow, in one ink that holds on light and dark
/// screens; undo takes back the last mark.
struct SimulatorAnnotationEditor: View {
    let source: SimulatorAnnotationSource
    let close: () -> Void
    @EnvironmentObject private var store: TermioStore
    @State private var image: NSImage?
    @State private var marks: [SimulatorMark] = []
    @State private var drawing: SimulatorMark?
    @State private var tool: SimulatorMark.Tool = .pen
    @State private var problem: String?

    /// Annotation ink: Markup's red, the colour people already read as "look here".
    static let ink = NSColor.systemRed

    /// The editor's drawing box; the screenshot is fitted inside it.
    private static let box = CGSize(width: 520, height: 640)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if let image {
                    canvas(image)
                } else {
                    ProgressView().controlSize(.small).frame(width: 240, height: 320)
                }
            }
            .padding(16)
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
        }
        .task {
            image = NSImage(contentsOf: source.url)
            if image == nil { problem = localized("Couldn’t read the screenshot.") }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(SimulatorMark.Tool.allCases, id: \.self) { candidate in
                TreeHeaderButton(symbol: candidate.symbol, help: candidate.title, isOn: tool == candidate) {
                    tool = candidate
                }
            }
            TreeHeaderButton(symbol: "arrow.uturn.backward", help: localized("Undo")) {
                if !marks.isEmpty { marks.removeLast() }
            }
            .keyboardShortcut("z", modifiers: .command)
            Spacer(minLength: 12)
            Button(localized("Cancel"), action: close)
                .keyboardShortcut(.cancelAction)
            Button(localized("Add to Chat"), action: addToChat)
                .keyboardShortcut(.defaultAction)
                .disabled(image == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func canvas(_ image: NSImage) -> some View {
        let size = Self.fitted(image.size)
        return ZStack {
            Image(nsImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
            Canvas { context, canvasSize in
                let style = StrokeStyle(lineWidth: SimulatorMark.lineWidth(in: canvasSize), lineCap: .round, lineJoin: .round)
                for mark in marks + (drawing.map { [$0] } ?? []) {
                    context.stroke(mark.path(in: canvasSize), with: .color(Color(nsColor: Self.ink)), style: style)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = CGPoint(x: min(max(value.location.x / size.width, 0), 1),
                                            y: min(max(value.location.y / size.height, 0), 1))
                        if drawing == nil {
                            drawing = SimulatorMark(tool: tool, points: [point])
                        } else if tool == .pen {
                            drawing?.points.append(point)
                        } else {
                            drawing?.points = [drawing?.points.first ?? point, point]
                        }
                    }
                    .onEnded { _ in
                        if let drawing, drawing.points.count > 1 { marks.append(drawing) }
                        drawing = nil
                    })
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
    }

    private static func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func addToChat() {
        guard let image else { return }
        guard let png = SimulatorAnnotationRenderer.render(image, marks: marks) else {
            problem = localized("Couldn’t draw the annotations onto the screenshot.")
            return
        }
        let url: URL
        do {
            url = try SimulatorHost.annotationFile("Simulator Annotation", source.deviceName)
            try png.write(to: url)
        } catch {
            Log.simulator.error("saving an annotation failed: \(error.localizedDescription, privacy: .public)")
            problem = error.localizedDescription
            return
        }
        let note = marks.isEmpty
            ? "(a screenshot of the \(source.deviceName) simulator; use termio sim to inspect or act on the device)"
            : "(a screenshot of the \(source.deviceName) simulator with my annotations drawn on top; "
                + "use termio sim to inspect or act on the device)"
        guard store.addSnippetToSelectedSessionPrompt(TermioStore.promptToken(for: url) + " " + note + " ") else {
            problem = localized("Select a session to add this to.")
            return
        }
        close()
    }
}
