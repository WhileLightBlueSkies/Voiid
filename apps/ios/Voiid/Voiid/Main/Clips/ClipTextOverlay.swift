//
//  ClipTextOverlay.swift
//  Voiid
//
//  Text placed on a clip in the editor, and the one drawing of it that both the editor and
//  the export use — so the words land in the uploaded video exactly where they sat on screen.
//
//  ── ONE LAYOUT, TWO RENDERERS ───────────────────────────────────────────────────
//  Everything is measured against the VIDEO's width, never the screen's: the size is a
//  fraction of the frame width and the position a fraction of the frame. The editor lays the
//  text out over the video's on-screen rect with those fractions; the export draws the same
//  fractions into the full-resolution frame. A 1080-wide export and a 390-point phone
//  therefore agree, which a point size would not.
//

import SwiftUI
import UIKit
import CoreImage

nonisolated struct ClipTextOverlay: Identifiable, Equatable, Sendable {
    enum Style: Equatable { case plain, pill }

    let id = UUID()
    var text: String
    var color: Int = 0
    var style: Style = .plain
    /// Centre of the text, 0…1 of the video frame, y down.
    var position = CGPoint(x: 0.5, y: 0.4)

    /// Font size as a fraction of the frame width: 28 pt on a 390 pt-wide frame.
    static let fontFraction: CGFloat = 28.0 / 390.0
    /// Longest line before wrapping, as a fraction of the frame width.
    static let wrapFraction: CGFloat = 300.0 / 390.0

    static let palette: [UIColor] = [
        .white, .black, UIColor(red: 0.075, green: 0.51, blue: 0.55, alpha: 1),
        UIColor(red: 1, green: 0.84, blue: 0.2, alpha: 1), UIColor(red: 1, green: 0.38, blue: 0.55, alpha: 1),
        UIColor(red: 0.35, green: 0.6, blue: 1, alpha: 1),
    ]

    var fill: UIColor { Self.palette[min(color, Self.palette.count - 1)] }
    /// The letters' colour: the palette colour, or on a pill the colour that reads on it.
    var ink: UIColor { style == .pill ? (color == 0 ? .black : .white) : fill }

    static func font(forFrameWidth width: CGFloat) -> UIFont {
        let size = width * fontFraction
        let base = UIFont.systemFont(ofSize: size, weight: .bold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: size)
    }
}

// MARK: - Export drawing

nonisolated enum ClipTextRenderer {
    /// All the text as one transparent image the size of the frame, in Core Image space
    /// (origin bottom-left) ready to composite over each video frame. Nil when there is none.
    static func overlay(_ texts: [ClipTextOverlay], frame size: CGSize) -> CIImage? {
        let visible = texts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !visible.isEmpty, size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            for item in visible { draw(item, in: size) }
        }
        guard let cg = image.cgImage else { return nil }
        // UIKit drew top-down; CIImage(cgImage:) keeps the picture upright, so no flip.
        return CIImage(cgImage: cg)
    }

    private static func draw(_ item: ClipTextOverlay, in size: CGSize) {
        let font = ClipTextOverlay.font(forFrameWidth: size.width)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: item.ink, .paragraphStyle: paragraph,
        ]
        if item.style == .plain {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = font.pointSize * 0.14
            shadow.shadowOffset = CGSize(width: 0, height: font.pointSize * 0.035)
            attrs[.shadow] = shadow
        }
        let text = NSAttributedString(string: item.text, attributes: attrs)
        let wrap = size.width * ClipTextOverlay.wrapFraction
        let bounds = text.boundingRect(with: CGSize(width: wrap, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            .integral
        let centre = CGPoint(x: item.position.x * size.width, y: item.position.y * size.height)
        let textRect = CGRect(x: centre.x - bounds.width / 2, y: centre.y - bounds.height / 2,
                              width: bounds.width, height: bounds.height)

        if item.style == .pill {
            let padX = font.pointSize * 0.5, padY = font.pointSize * 0.21
            let pill = textRect.insetBy(dx: -padX, dy: -padY)
            item.fill.setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: font.pointSize * 0.36).fill()
        }
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}

// MARK: - Editor drawing

/// The same text in SwiftUI, sized for a video that is `frameWidth` points wide on screen.
struct ClipTextLabel: View {
    let item: ClipTextOverlay
    let frameWidth: CGFloat

    var body: some View {
        let font = ClipTextOverlay.font(forFrameWidth: frameWidth)
        Text(item.text)
            .font(Font(font))
            .multilineTextAlignment(.center)
            .foregroundColor(Color(item.ink))
            .shadow(color: .black.opacity(item.style == .plain ? 0.45 : 0),
                    radius: font.pointSize * 0.14, y: font.pointSize * 0.035)
            .frame(maxWidth: frameWidth * ClipTextOverlay.wrapFraction)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, item.style == .pill ? font.pointSize * 0.5 : 0)
            .padding(.vertical, item.style == .pill ? font.pointSize * 0.21 : 0)
            .background(
                RoundedRectangle(cornerRadius: font.pointSize * 0.36, style: .continuous)
                    .fill(item.style == .pill ? Color(item.fill) : .clear)
            )
    }
}
