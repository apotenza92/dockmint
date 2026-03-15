import AppKit

enum StatusBarIcon {
    static func image(pointSize: CGFloat = 18, isTemplate: Bool = true) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let inset: CGFloat = max(0.65, pointSize * 0.055)
            let glyphRect = NSRect(
                x: rect.minX + inset,
                y: rect.minY + inset,
                width: rect.width - inset * 2,
                height: rect.height - inset * 2
            )

            drawLeafGlyph(in: glyphRect, lineWidth: 2.0)
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    private static func newStrokePath(lineWidth: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        return path
    }

    private static func lucidePoint(_ x: CGFloat, _ y: CGFloat, in rect: NSRect) -> NSPoint {
        NSPoint(
            x: rect.minX + rect.width * (x / 24.0),
            y: rect.minY + rect.height * ((24.0 - y) / 24.0)
        )
    }

    private static func drawLeafGlyph(in rect: NSRect, lineWidth: CGFloat) {
        let strokeWidth = lineWidth * min(rect.width, rect.height) / 24.0

        let leaf = newStrokePath(lineWidth: strokeWidth)
        leaf.move(to: lucidePoint(11.0, 20.0, in: rect))
        leaf.curve(
            to: lucidePoint(9.8, 6.1, in: rect),
            controlPoint1: lucidePoint(7.2, 18.0, in: rect),
            controlPoint2: lucidePoint(6.9, 9.7, in: rect)
        )
        leaf.curve(
            to: lucidePoint(19.0, 2.0, in: rect),
            controlPoint1: lucidePoint(15.5, 5.0, in: rect),
            controlPoint2: lucidePoint(17.0, 4.48, in: rect)
        )
        leaf.curve(
            to: lucidePoint(21.0, 10.0, in: rect),
            controlPoint1: lucidePoint(20.0, 4.0, in: rect),
            controlPoint2: lucidePoint(21.0, 6.18, in: rect)
        )
        leaf.curve(
            to: lucidePoint(11.0, 20.0, in: rect),
            controlPoint1: lucidePoint(21.0, 15.5, in: rect),
            controlPoint2: lucidePoint(16.22, 20.0, in: rect)
        )
        leaf.close()
        leaf.fill()

        let vein = newStrokePath(lineWidth: strokeWidth)
        vein.move(to: lucidePoint(2.0, 21.0, in: rect))
        vein.curve(
            to: lucidePoint(7.08, 15.0, in: rect),
            controlPoint1: lucidePoint(2.0, 18.0, in: rect),
            controlPoint2: lucidePoint(3.85, 15.64, in: rect)
        )
        vein.curve(
            to: lucidePoint(13.0, 12.0, in: rect),
            controlPoint1: lucidePoint(9.5, 14.52, in: rect),
            controlPoint2: lucidePoint(12.0, 13.0, in: rect)
        )
        vein.stroke()
    }
}
