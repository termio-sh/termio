import Foundation
import PDFKit
import CryptoKit

/// Persists user-added PDF annotations in a per-document sidecar keyed by the file's content
/// hash — moving or renaming the PDF keeps its annotations attached and the original file is
/// never modified.
enum PDFAnnotationStore {
    static let userName = "termio"

    private static var directory: URL {
        AppChannel.supportDirectory.appendingPathComponent("pdf-annotations", isDirectory: true)
    }

    private static func sidecarURL(for hash: String) -> URL {
        directory.appendingPathComponent(hash + ".json")
    }

    static func hash(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(into document: PDFDocument, hash: String) {
        guard let data = try? Data(contentsOf: sidecarURL(for: hash)),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        for record in records {
            guard record.page >= 0, record.page < document.pageCount,
                  let page = document.page(at: record.page),
                  let subtype = PDFAnnotationSubtype.fromString(record.subtype) else { continue }
            let bounds = CGRect(x: record.x, y: record.y, width: record.width, height: record.height)
            let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
            annotation.color = NSColor(hex: record.colorHex) ?? .systemYellow
            annotation.userName = userName
            page.addAnnotation(annotation)
        }
    }

    static func save(_ document: PDFDocument, hash: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var records: [Record] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.userName == userName {
                guard let rawType = annotation.type,
                      let subtype = PDFAnnotationSubtype.toString(fromRawType: rawType) else { continue }
                let bounds = annotation.bounds
                records.append(Record(
                    page: pageIndex,
                    x: bounds.origin.x, y: bounds.origin.y,
                    width: bounds.size.width, height: bounds.size.height,
                    subtype: subtype,
                    colorHex: annotation.color.hexString
                ))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: sidecarURL(for: hash), options: [.atomic])
    }

    private struct Record: Codable {
        let page: Int
        let x, y, width, height: Double
        let subtype: String
        let colorHex: String
    }
}

private extension PDFAnnotationSubtype {
    static func fromString(_ string: String) -> PDFAnnotationSubtype? {
        switch string {
        case "highlight": return .highlight
        case "underline": return .underline
        case "strikeOut": return .strikeOut
        default: return nil
        }
    }

    // `PDFAnnotation.type` returns a raw PDF spec name (may or may not carry a leading slash),
    // not a `PDFAnnotationSubtype`, so map by string.
    static func toString(fromRawType raw: String) -> String? {
        let cleaned = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        switch cleaned {
        case "Highlight": return "highlight"
        case "Underline": return "underline"
        case "StrikeOut": return "strikeOut"
        default: return nil
        }
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
            a = 1
        } else {
            r = CGFloat((value >> 24) & 0xff) / 255
            g = CGFloat((value >> 16) & 0xff) / 255
            b = CGFloat((value >> 8) & 0xff) / 255
            a = CGFloat(value & 0xff) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        // `redComponent`/`greenComponent`/`blueComponent` trap on non-RGB color spaces
        // (grayscale, CMYK, and some P3 displays), so fall back to opaque black on failure —
        // the sidecar keeps loading, just without an exact color for that record.
        guard let converted = usingColorSpace(.sRGB) else { return "#000000ff" }
        let r = Int((converted.redComponent * 255).rounded())
        let g = Int((converted.greenComponent * 255).rounded())
        let b = Int((converted.blueComponent * 255).rounded())
        let a = Int((converted.alphaComponent * 255).rounded())
        return String(format: "#%02x%02x%02x%02x", r, g, b, a)
    }
}
