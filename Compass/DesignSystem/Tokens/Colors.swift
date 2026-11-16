import SwiftUI

// Colour tokens from design/compass-v3/source/tools/kit.css and the system sheet.
// Use as `.foregroundStyle(.ink)`, `.background(.ground)`, `Color.surface`.
// Weight carries hierarchy, not colour. Destructive only for destructive actions.

extension Color {
    /// `Color(hex: 0x0B0B0C)`
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension ShapeStyle where Self == Color {
    /// #0B0B0C — screen background.
    static var ground: Color { Color(hex: 0x0B0B0C) }
    /// #161618 — cards, Note pill, player, notices, tiles.
    static var surface: Color { Color(hex: 0x161618) }
    /// #1C1C1F — sheets, keyboard.
    static var raised: Color { Color(hex: 0x1C1C1F) }
    /// #2A2A2D — hairlines, outlined controls, unlit wave bars, progress off.
    static var line: Color { Color(hex: 0x2A2A2D) }
    /// #3A3A3E — stronger line: btn2 border, field underline, grab handle, inner ring.
    static var line2: Color { Color(hex: 0x3A3A3E) }
    /// #F4F4F2 — primary text and primary fill. 17.9:1.
    static var ink: Color { Color(hex: 0xF4F4F2) }
    /// #D6D6D8 — notice text.
    static var noticeInk: Color { Color(hex: 0xD6D6D8) }
    /// #A1A1A6 — secondary text (`.ink2`). 7.6:1.
    static var ink2: Color { Color(hex: 0xA1A1A6) }
    /// #8A8A90 — tertiary text (`.ink3`). 5.7:1.
    static var ink3: Color { Color(hex: 0x8A8A90) }
    /// #6E6E74 — missed marks, dim (pending) words, "no" circle border. 3.8:1, graphic only.
    static var dim: Color { Color(hex: 0x6E6E74) }
    /// #FF8A7A — destructive only.
    static var destructive: Color { Color(hex: 0xFF8A7A) }
    /// rgba(0,0,0,.64) behind sheets.
    static var scrim: Color { Color.black.opacity(0.64) }
}
