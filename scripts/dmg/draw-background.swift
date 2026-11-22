#!/usr/bin/env swift
// Draws the picture behind the icons in the disk image's window: Espalier's
// mark and name, a line saying what it is, the headline, an arrow from the
// app to Applications, and a pill behind each icon's name.
//
//   swift scripts/dmg/draw-background.swift
//
// writes background.png and background@2x.png next to this script, in the
// app's fonts (Geist and Geist Mono, from EspalierUI's resources) and the
// website's colors. settings.py puts the icons where this draws around
// them: `appIcon` and `applicationsIcon` here are its `icon_locations`.
//
// Finder draws the picture from the top left of the window's content, a
// point to a pixel of background.png, and never scales it. It draws each
// icon's name over the picture in the appearance's own text color, so the
// pills are a color that black and white both read on.

import AppKit
import CoreText

// MARK: - Layout, in points from the picture's top left

/// The picture: as wide as the window, and taller than its content
/// (settings.py's window, less the title bar), so a shorter title bar
/// shows more background rather than white.
let canvas = CGSize(width: 660, height: 420)

/// The left and right margins.
let margin: CGFloat = 44

/// The centers of the two icons, 128 points each.
let appIcon = CGPoint(x: 180, y: 240)
let applicationsIcon = CGPoint(x: 480, y: 240)

/// How far below an icon's center Finder centers its name, at 13 points.
let nameOffset: CGFloat = 84

// MARK: - Colors

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let paper = color(0xF9F8FE)
let ink = color(0x110C19)
let quietInk = color(0x6B637C)
/// The icon's fruit.
let fruit = color(0x8B5CF6)

// MARK: - Fonts

let here = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
let fontsFolder = here.appending(path: "../../Packages/EspalierKit/Sources/EspalierUI/Resources/Fonts").standardizedFileURL

for file in ["geist/Geist[wght].ttf", "geist-mono/GeistMono[wght].ttf"] {
    var error: Unmanaged<CFError>?
    guard CTFontManagerRegisterFontsForURL(fontsFolder.appending(path: file) as CFURL, .process, &error) else {
        fatalError("Couldn't register \(file): \(String(describing: error?.takeRetainedValue()))")
    }
}

/// A face of a variable family at `weight` on its weight axis.
func font(_ family: String, size: CGFloat, weight: CGFloat) -> NSFont {
    let weightAxis = 0x7767_6874 // 'wght'
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontFamilyNameAttribute: family,
        kCTFontVariationAttribute: [weightAxis: weight],
    ] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
}

/// A line of text, set with `tracking` (in ems) between its characters.
struct Line {
    let string: NSAttributedString
    /// The ink's left and right edges, from the line's origin.
    let inkLeft: CGFloat
    let inkRight: CGFloat

    init(_ text: String, font: NSFont, color: NSColor, tracking: CGFloat = 0) {
        string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: tracking * font.pointSize,
        ])
        let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(string), .useGlyphPathBounds)
        inkLeft = ink.minX
        inkRight = ink.maxX
    }

    var inkWidth: CGFloat { inkRight - inkLeft }

    /// Draws the line with its ink's left edge at `x`, on `baseline`.
    func draw(x: CGFloat, baseline: CGFloat) {
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        // The context is flipped; text is drawn upright from its baseline.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x - inkLeft, y: baseline)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        context.restoreGState()
    }
}

// MARK: - The pieces

/// The icon's tree, drawn flat: Marketing/AppIcon/draw-icon.py's geometry,
/// in its 180-unit square. `height` is the mark's, from its top tip to the
/// foot of its trunk; `origin` is its top left.
func drawMark(origin: CGPoint, height: CGFloat) {
    // The mark's ink in the 180-unit square.
    let bounds = CGRect(x: 51.5, y: 33, width: 84, height: 119.5)
    let scale = height / bounds.height
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.translateBy(x: origin.x, y: origin.y)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)

    // A quarter circle as a curve: its control points sit this far along.
    let k: CGFloat = 0.5523
    let tree = CGMutablePath()
    tree.move(to: CGPoint(x: 58, y: 146))
    tree.addLine(to: CGPoint(x: 58, y: 66))
    tree.addCurve(to: CGPoint(x: 80, y: 44), control1: CGPoint(x: 58, y: 66 - 22 * k), control2: CGPoint(x: 80 - 22 * k, y: 44))
    tree.addLine(to: CGPoint(x: 124, y: 44))
    tree.move(to: CGPoint(x: 58, y: 108))
    tree.addCurve(to: CGPoint(x: 80, y: 87), control1: CGPoint(x: 58, y: 95), control2: CGPoint(x: 66, y: 87))
    tree.addLine(to: CGPoint(x: 108, y: 87))
    tree.move(to: CGPoint(x: 58, y: 146))
    tree.addCurve(to: CGPoint(x: 80, y: 130), control1: CGPoint(x: 58, y: 136), control2: CGPoint(x: 66, y: 130))
    tree.addLine(to: CGPoint(x: 124, y: 130))

    context.setStrokeColor(ink.cgColor)
    context.setLineWidth(13)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(tree)
    context.strokePath()

    context.setFillColor(ink.cgColor)
    for tip in [CGPoint(x: 124, y: 44), CGPoint(x: 124, y: 130)] {
        context.fillEllipse(in: CGRect(x: tip.x - 11, y: tip.y - 11, width: 22, height: 22))
    }
    context.setFillColor(fruit.cgColor)
    context.fillEllipse(in: CGRect(x: 108 - 11.5, y: 87 - 11.5, width: 23, height: 23))
    context.restoreGState()
}

/// The arrow from the app to Applications: a branch with a fruit where it
/// starts.
func drawArrow(from start: CGFloat, to end: CGFloat, y: CGFloat) {
    let context = NSGraphicsContext.current!.cgContext
    let head: CGFloat = 13
    context.saveGState()
    context.setStrokeColor(ink.cgColor)
    context.setLineWidth(5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: start, y: y))
    context.addLine(to: CGPoint(x: end, y: y))
    context.move(to: CGPoint(x: end - head, y: y - head))
    context.addLine(to: CGPoint(x: end, y: y))
    context.addLine(to: CGPoint(x: end - head, y: y + head))
    context.strokePath()
    context.setFillColor(fruit.cgColor)
    context.fillEllipse(in: CGRect(x: start - 7, y: y - 7, width: 14, height: 14))
    context.restoreGState()
}

/// The pill behind an icon's name.
func drawPill(under icon: CGPoint) {
    let size = CGSize(width: 118, height: 26)
    let rect = CGRect(x: icon.x - size.width / 2, y: icon.y + nameOffset - size.height / 2, width: size.width, height: size.height)
    fruit.setFill()
    NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
}

func drawBackground() {
    paper.setFill()
    CGRect(origin: .zero, size: canvas).fill()

    // The mark, the name, and what Espalier is, on one line.
    let name = Line("Espalier", font: font("Geist", size: 17, weight: 650), color: ink, tracking: -0.01)
    let what = Line("A GIT CLIENT FOR THE MAC", font: font("Geist Mono", size: 10.5, weight: 500), color: quietInk, tracking: 0.12)
    let nameBaseline: CGFloat = 54
    let markHeight: CGFloat = 22
    drawMark(origin: CGPoint(x: margin, y: nameBaseline - markHeight + 3), height: markHeight)
    let nameX = margin + 84 / 119.5 * markHeight + 9
    name.draw(x: nameX, baseline: nameBaseline)
    what.draw(x: nameX + name.inkWidth + 16, baseline: nameBaseline - 0.5)

    // The headline, sized to run from margin to margin.
    let headlineText = "Put down roots."
    let measured = Line(headlineText, font: font("Geist", size: 100, weight: 800), color: ink, tracking: -0.045)
    let headlineSize = 100 * (canvas.width - margin * 2) / measured.inkWidth
    let headline = Line(headlineText, font: font("Geist", size: headlineSize, weight: 800), color: ink, tracking: -0.045)
    headline.draw(x: margin, baseline: 138)

    drawArrow(from: appIcon.x + 86, to: applicationsIcon.x - 86, y: appIcon.y)
    drawPill(under: appIcon)
    drawPill(under: applicationsIcon)
}

// MARK: - Writing

for scale in [1, 2] {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width) * scale,
        pixelsHigh: Int(canvas.height) * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = canvas
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // Top-left origin, as Finder lays the window out.
    context.translateBy(x: 0, y: canvas.height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    drawBackground()
    NSGraphicsContext.current = nil

    let name = scale == 1 ? "background.png" : "background@\(scale)x.png"
    let png = (rep.retagging(with: .sRGB) ?? rep).representation(using: .png, properties: [:])!
    try png.write(to: here.appending(path: name))
    print("Wrote scripts/dmg/\(name)")
}
