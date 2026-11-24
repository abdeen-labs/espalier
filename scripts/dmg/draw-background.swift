#!/usr/bin/env swift
// Draws the picture behind the icons in the disk image's window: Espalier's
// mark and name, a line saying what it is, the headline, an arrow from the
// app to Applications, and a pill behind each icon's name.
//
//   swift scripts/dmg/draw-background.swift
//
// writes background.png and background@2x.png next to this script, in the
// app's fonts (Allo and Maple Mono, from EspalierUI's resources) and the
// app's colors: cream, espresso, and the mark's peach. settings.py puts the icons where this draws around
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

let paper = color(0xFFFBF3)
let ink = color(0x2B2119)
let quietInk = color(0x7A6858)
/// The mark's peach: its body, lit and in shadow, its blush, its shine,
/// its crease, and its leaf.
let peach = color(0xFF9F6B)
let peachLight = color(0xFFC98F)
let peachShadow = color(0xFF7F5C)
let blush = color(0xFF5E7A)
let shine = color(0xFFE6C4)
let crease = color(0xE8603F)
let leaf = color(0x3FA35B)

// MARK: - Fonts

let here = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
let fontsFolder = here.appending(path: "../../Packages/EspalierKit/Sources/EspalierUI/Resources/Fonts").standardizedFileURL

for file in ["allo/AlloVariable-Round.ttf", "maple-mono/MapleMonoNL[wght].ttf"] {
    var error: Unmanaged<CFError>?
    guard CTFontManagerRegisterFontsForURL(fontsFolder.appending(path: file) as CFURL, .process, &error) else {
        fatalError("Couldn't register \(file): \(String(describing: error?.takeRetainedValue()))")
    }
}

/// A face of a variable family at `weight` on its weight axis, and at
/// `size` on its optical size axis, as far as that goes, where it has one.
func font(_ family: String, size: CGFloat, weight: CGFloat) -> NSFont {
    let weightAxis = 0x7767_6874 // 'wght'
    let opticalSizeAxis = 0x6F70_737A // 'opsz'
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontFamilyNameAttribute: family,
        kCTFontVariationAttribute: [weightAxis: weight, opticalSizeAxis: min(size, 32)],
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

/// The mark, a peach with its stem and leaf, as the app draws it
/// (EspalierUI's BrandMark): `height` is the mark's, from the stem's tip to
/// the peach's foot; `origin` is its top left.
func drawMark(origin: CGPoint, height: CGFloat) {
    // The mark's ink around the peach's center.
    let bounds = CGRect(x: -47, y: -58, width: 94, height: 106)
    let scale = height / bounds.height
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.translateBy(x: origin.x, y: origin.y)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)

    // The stem, and the leaf from its foot.
    context.setLineCap(.round)
    context.setStrokeColor(ink.cgColor)
    context.setLineWidth(8)
    context.move(to: CGPoint(x: 2, y: -38))
    context.addCurve(to: CGPoint(x: 11, y: -54), control1: CGPoint(x: 2, y: -46), control2: CGPoint(x: 5, y: -51))
    context.strokePath()
    context.saveGState()
    context.translateBy(x: 1, y: -41)
    context.rotate(by: -150 * .pi / 180)
    context.scaleBy(x: 1.45, y: 1.45)
    context.move(to: .zero)
    context.addCurve(to: CGPoint(x: 22, y: -20), control1: CGPoint(x: 0, y: -12), control2: CGPoint(x: 9, y: -20))
    context.addCurve(to: .zero, control1: CGPoint(x: 22, y: -8), control2: CGPoint(x: 13, y: 0))
    context.setFillColor(leaf.cgColor)
    context.fillPath()
    context.restoreGState()

    // The body: round, with a dip at the stem, lit from the upper left,
    // with a blush on its cheek.
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 2, y: -36))
    body.addCurve(to: CGPoint(x: 47, y: 2), control1: CGPoint(x: 16, y: -46), control2: CGPoint(x: 47, y: -34))
    body.addCurve(to: CGPoint(x: 0, y: 48), control1: CGPoint(x: 47, y: 30), control2: CGPoint(x: 26, y: 48))
    body.addCurve(to: CGPoint(x: -47, y: 2), control1: CGPoint(x: -26, y: 48), control2: CGPoint(x: -47, y: 30))
    body.addCurve(to: CGPoint(x: 2, y: -36), control1: CGPoint(x: -47, y: -34), control2: CGPoint(x: -12, y: -46))
    body.closeSubpath()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    context.saveGState()
    context.addPath(body)
    context.clip()
    let shades = CGGradient(colorsSpace: space, colors: [peachLight.cgColor, peach.cgColor, peachShadow.cgColor] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(shades, start: CGPoint(x: -32, y: -38), end: CGPoint(x: 32, y: 45), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let cheek = CGGradient(colorsSpace: space, colors: [blush.withAlphaComponent(0.75).cgColor, blush.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(cheek, startCenter: CGPoint(x: 20, y: 20), startRadius: 0, endCenter: CGPoint(x: 20, y: 20), endRadius: 46, options: [])
    context.restoreGState()

    context.setStrokeColor(shine.withAlphaComponent(0.85).cgColor)
    context.setLineWidth(5)
    context.move(to: CGPoint(x: -30, y: -6))
    context.addCurve(to: CGPoint(x: -16, y: -27), control1: CGPoint(x: -30, y: -16), control2: CGPoint(x: -24, y: -24))
    context.strokePath()
    context.setStrokeColor(crease.cgColor)
    context.setLineWidth(4.5)
    context.move(to: CGPoint(x: 2, y: -36))
    context.addCurve(to: CGPoint(x: -7, y: -13), control1: CGPoint(x: -3, y: -30), control2: CGPoint(x: -6, y: -22))
    context.strokePath()
    context.restoreGState()
}

/// The arrow from the app to Applications: a branch with a peach-colored
/// dot where it starts.
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
    context.setFillColor(peach.cgColor)
    context.fillEllipse(in: CGRect(x: start - 7, y: y - 7, width: 14, height: 14))
    context.restoreGState()
}

/// The pill behind an icon's name.
func drawPill(under icon: CGPoint) {
    let size = CGSize(width: 118, height: 26)
    let rect = CGRect(x: icon.x - size.width / 2, y: icon.y + nameOffset - size.height / 2, width: size.width, height: size.height)
    peach.setFill()
    NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
}

func drawBackground() {
    paper.setFill()
    CGRect(origin: .zero, size: canvas).fill()

    // The mark, the name, and what Espalier is, on one line.
    let name = Line("Espalier", font: font("Allo Variable", size: 19, weight: 900), color: ink, tracking: -0.02)
    let what = Line("A GIT CLIENT FOR THE MAC", font: font("Maple Mono NL", size: 10.5, weight: 600), color: quietInk, tracking: 0.1)
    let nameBaseline: CGFloat = 54
    let markHeight: CGFloat = 28
    drawMark(origin: CGPoint(x: margin, y: nameBaseline - markHeight + 5), height: markHeight)
    let nameX = margin + 94 / 106 * markHeight + 8
    name.draw(x: nameX, baseline: nameBaseline)
    what.draw(x: nameX + name.inkWidth + 16, baseline: nameBaseline - 0.5)

    // The headline, sized to run from margin to margin.
    let headlineText = "Put down roots."
    let measured = Line(headlineText, font: font("Allo Variable", size: 100, weight: 900), color: ink, tracking: -0.035)
    let headlineSize = 100 * (canvas.width - margin * 2) / measured.inkWidth
    let headline = Line(headlineText, font: font("Allo Variable", size: headlineSize, weight: 900), color: ink, tracking: -0.035)
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
