import Foundation
import CoreGraphics

/// A user-added text note on the infinite canvas.
struct CanvasTextItem: Identifiable, Codable {
    var id: UUID = UUID()
    var text: String = ""
    var x: CGFloat = 0
    var y: CGFloat = 0
    var fontName: String? = nil    // nil = system font
    var fontSize: CGFloat = 16
}

/// Persisted state of the infinite canvas (positions are in canvas coordinates).
struct CanvasLayout: Codable {
    var positions: [String: CGPoint] = [:]   // screenshot id (uuidString) → center point
    var sizes: [String: CGFloat] = [:]       // screenshot id → display width (canvas points)
    var rotations: [String: CGFloat] = [:]   // screenshot id → rotation in degrees
    var texts: [CanvasTextItem] = []
    var panX: CGFloat = 0
    var panY: CGFloat = 0
    var scale: CGFloat = 1
    var background: String? = nil   // canvas background color, hex "#RRGGBB"
    var showGrid: Bool = false      // (legacy) show a grid background
    var gridStyle: String = "none"  // background pattern: "none" / "grid" / "dots"
    var order: [String] = []        // draw order (bottom→top); image uuid or "t:"+uuid
    var locked: [String] = []       // locked item keys
    var groups: [[String]] = []     // each group = list of item keys
    var whiteEdge: [String] = []    // image keys with an irregular white border
    var polaroid: [String] = []     // image keys with a Polaroid frame
    var noShadow: [String] = []     // image keys with the drop shadow removed
}

struct Screenshot: Identifiable, Codable {
    var id: UUID = UUID()
    var fileName: String
    var createdAt: Date
    var folderId: UUID?
    var name: String?            // optional custom name

    /// Name shown in the UI: custom name if set, else a date-based default.
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: createdAt)
    }
}

struct Folder: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
}
