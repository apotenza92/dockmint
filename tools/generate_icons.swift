#!/usr/bin/env swift

import AppKit
import ImageIO
import UniformTypeIdentifiers

struct IconSpec {
    let size: Int
    let filename: String
}

struct IconTheme {
    let baseTop: NSColor
    let baseBottom: NSColor
    let diagonalTop: NSColor
    let diagonalMid: NSColor
    let diagonalBottom: NSColor
    let vignetteBottom: NSColor
    let glyphTopAlpha: CGFloat
    let glyphBottomAlpha: CGFloat
}

struct IconSet {
    let folderName: String
    let label: String
    let theme: IconTheme
}

let specs: [IconSpec] = [
    .init(size: 16, filename: "icon_16x16.png"),
    .init(size: 32, filename: "icon_16x16@2x.png"),
    .init(size: 32, filename: "icon_32x32.png"),
    .init(size: 64, filename: "icon_32x32@2x.png"),
    .init(size: 128, filename: "icon_128x128.png"),
    .init(size: 256, filename: "icon_128x128@2x.png"),
    .init(size: 256, filename: "icon_256x256.png"),
    .init(size: 512, filename: "icon_256x256@2x.png"),
    .init(size: 512, filename: "icon_512x512.png"),
    .init(size: 1024, filename: "icon_512x512@2x.png")
]

let stableTheme = IconTheme(
    baseTop: NSColor(calibratedRed: 0.71, green: 0.92, blue: 0.84, alpha: 1.0),
    baseBottom: NSColor(calibratedRed: 0.05, green: 0.66, blue: 0.49, alpha: 1.0),
    diagonalTop: NSColor(calibratedRed: 0.92, green: 0.98, blue: 0.95, alpha: 0.30),
    diagonalMid: NSColor(calibratedRed: 0.34, green: 0.84, blue: 0.69, alpha: 0.10),
    diagonalBottom: NSColor(calibratedRed: 0.02, green: 0.44, blue: 0.33, alpha: 0.28),
    vignetteBottom: NSColor(calibratedRed: 0.01, green: 0.26, blue: 0.19, alpha: 0.24),
    glyphTopAlpha: 0.99,
    glyphBottomAlpha: 0.74
)

let betaTheme = IconTheme(
    baseTop: NSColor(calibratedRed: 0.50, green: 0.72, blue: 0.95, alpha: 1.0),
    baseBottom: NSColor(calibratedRed: 0.23, green: 0.21, blue: 0.72, alpha: 1.0),
    diagonalTop: NSColor(calibratedRed: 0.88, green: 0.93, blue: 1.00, alpha: 0.30),
    diagonalMid: NSColor(calibratedRed: 0.52, green: 0.64, blue: 0.96, alpha: 0.10),
    diagonalBottom: NSColor(calibratedRed: 0.15, green: 0.14, blue: 0.48, alpha: 0.28),
    vignetteBottom: NSColor(calibratedRed: 0.09, green: 0.08, blue: 0.27, alpha: 0.25),
    glyphTopAlpha: 0.99,
    glyphBottomAlpha: 0.74
)

let iconSets: [IconSet] = [
    .init(folderName: "AppIcon.appiconset", label: "stable", theme: stableTheme),
    .init(folderName: "AppIconBeta.appiconset", label: "beta", theme: betaTheme)
]

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let assetsCatalog = cwd.appendingPathComponent("Dockmint/Assets.xcassets", isDirectory: true)

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func newStrokePath(lineWidth: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineJoinStyle = .round
    path.lineCapStyle = .round
    return path
}

private let referenceViewBox = NSSize(width: 1000.0, height: 1000.0)

func fittedReferenceRect(in rect: NSRect, scale: CGFloat = 1.01, yOffset: CGFloat = 0.01) -> NSRect {
    let fitted = NSSize(width: rect.height * (referenceViewBox.width / referenceViewBox.height), height: rect.height)
    let scaled = NSSize(width: fitted.width * scale, height: fitted.height * scale)
    return NSRect(
        x: rect.midX - scaled.width / 2.0,
        y: rect.midY - scaled.height / 2.0 + rect.height * yOffset,
        width: scaled.width,
        height: scaled.height
    )
}

func referencePoint(_ x: CGFloat, _ y: CGFloat, in rect: NSRect) -> NSPoint {
    NSPoint(
        x: rect.minX + rect.width * (x / referenceViewBox.width),
        y: rect.minY + rect.height * (1.0 - (y / referenceViewBox.height))
    )
}

func leafPath(in rect: NSRect) -> NSBezierPath {
    let leaf = NSBezierPath()
    leaf.move(to: referencePoint(799.846, 118.449, in: rect))
    leaf.curve(to: referencePoint(846.087, 430.357, in: rect),
               controlPoint1: referencePoint(799.846, 118.449, in: rect),
               controlPoint2: referencePoint(892.934, 239.215, in: rect))
    leaf.curve(to: referencePoint(318.622, 751.420, in: rect),
               controlPoint1: referencePoint(796.649, 632.069, in: rect),
               controlPoint2: referencePoint(480.967, 943.975, in: rect))
    leaf.curve(to: referencePoint(799.846, 118.449, in: rect),
               controlPoint1: referencePoint(111.051, 505.224, in: rect),
               controlPoint2: referencePoint(799.846, 118.449, in: rect))
    leaf.close()
    return leaf
}

func veinPath(in rect: NSRect, lineWidth: CGFloat) -> NSBezierPath {
    let vein = newStrokePath(lineWidth: lineWidth)
    vein.move(to: referencePoint(140.732, 839.032, in: rect))
    vein.curve(to: referencePoint(500.417, 606.490, in: rect),
               controlPoint1: referencePoint(140.732, 839.032, in: rect),
               controlPoint2: referencePoint(336.615, 765.537, in: rect))
    vein.curve(to: referencePoint(720.674, 336.010, in: rect),
               controlPoint1: referencePoint(703.268, 409.526, in: rect),
               controlPoint2: referencePoint(720.674, 336.010, in: rect))
    return vein
}

func drawLeafGlyph(
    in rect: NSRect,
    topColor: NSColor,
    bottomColor: NSColor,
    veinColor: NSColor,
    lineWidth: CGFloat
) {
    let strokeWidth = lineWidth * min(rect.width, rect.height) / 24.0

    let fittedRect = fittedReferenceRect(in: rect)
    let leaf = leafPath(in: fittedRect)
    let vein = veinPath(in: fittedRect, lineWidth: strokeWidth * 0.50)

    NSGraphicsContext.saveGraphicsState()
    leaf.addClip()
    let glyphGradient = NSGradient(colors: [topColor, bottomColor])!
    glyphGradient.draw(in: leaf.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    veinColor.setStroke()
    vein.stroke()
}

func drawIcon(size: Int, theme: IconTheme) throws -> NSBitmapImageRep {
    let pixelsWide = size
    let pixelsHigh = size
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "DockmintIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap"])
    }

    rep.size = NSSize(width: pixelsWide, height: pixelsHigh)

    let s = CGFloat(size)
    let canvas = NSRect(x: 0, y: 0, width: s, height: s)
    let context = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer {
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    canvas.fill()

    let outerInset = s * 0.06
    let outerRect = canvas.insetBy(dx: outerInset, dy: outerInset)
    let outer = roundedRect(outerRect, radius: s * 0.22)

    let baseGradient = NSGradient(colors: [theme.baseTop, theme.baseBottom])!
    baseGradient.draw(in: outer, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    outer.addClip()

    let diagonal = NSGradient(colors: [
        theme.diagonalTop,
        theme.diagonalMid,
        theme.diagonalBottom
    ])!
    diagonal.draw(in: outerRect, angle: -35)

    let subtleVignette = NSGradient(colors: [
        NSColor(calibratedWhite: 0.0, alpha: 0.0),
        theme.vignetteBottom
    ])!
    subtleVignette.draw(in: outerRect, relativeCenterPosition: NSPoint(x: 0.0, y: -0.15))

    NSGraphicsContext.restoreGraphicsState()

    let glyphRect = outerRect.insetBy(dx: s * 0.065, dy: s * 0.065)

    drawLeafGlyph(
        in: glyphRect,
        topColor: NSColor(calibratedWhite: 1.0, alpha: theme.glyphTopAlpha * 0.71),
        bottomColor: NSColor(calibratedWhite: 1.0, alpha: theme.glyphBottomAlpha * 0.55),
        veinColor: NSColor(calibratedWhite: 1.0, alpha: 0.99),
        lineWidth: 2.0
    )

    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let cgImage = rep.cgImage else {
        throw NSError(domain: "DockmintIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "DockmintIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination"])
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "DockmintIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
}

func appIconContentsJSON() -> String {
    """
    {
      "images" : [
        { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
        { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
        { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
        { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
        { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
        { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
        { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
        { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
        { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
        { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
}

guard fm.fileExists(atPath: assetsCatalog.path) else {
    fputs("Missing assets catalog: \(assetsCatalog.path)\n", stderr)
    exit(1)
}

for iconSet in iconSets {
    let iconsetURL = assetsCatalog.appendingPathComponent(iconSet.folderName, isDirectory: true)
    try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

    for spec in specs {
        let image = try drawIcon(size: spec.size, theme: iconSet.theme)
        let out = iconsetURL.appendingPathComponent(spec.filename)
        try writePNG(image, to: out)
        print("Wrote \(out.path)")
    }

    let contentsURL = iconsetURL.appendingPathComponent("Contents.json")
    try appIconContentsJSON().data(using: .utf8)?.write(to: contentsURL, options: .atomic)
    print("Updated \(contentsURL.path) [\(iconSet.label)]")
}
