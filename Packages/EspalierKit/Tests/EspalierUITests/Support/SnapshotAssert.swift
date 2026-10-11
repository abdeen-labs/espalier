// Snapshot assertions. References are PNGs under
// `Tests/EspalierUITests/__Snapshots__/<Area>/<name>-<light|dark>.png`,
// recorded on this Mac with ESPALIER_RECORD_SNAPSHOTS=1 (or, for the new
// ones alone, ESPALIER_RECORD_MISSING_SNAPSHOTS=1) and compared with a
// tolerance (a channel may differ by 2; at most 0.1% of pixels may differ
// more). On failure the actual image and a difference image go to
// `$TMPDIR/espalier-snapshots/<Area>/`.
//
// Package.swift excludes the references from the test target: PNGs inside
// it would make SwiftPM warn about unhandled files.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import EspalierUI

/// Snapshot references and comparison.
enum SnapshotReferences {
    /// Whether this run records references instead of comparing.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["ESPALIER_RECORD_SNAPSHOTS"] == "1"
    }

    /// Whether this run records the references that don't exist yet (new
    /// states) and compares the rest, so one run can add new snapshots
    /// without re-recording the old ones.
    static var isRecordingMissing: Bool {
        ProcessInfo.processInfo.environment["ESPALIER_RECORD_MISSING_SNAPSHOTS"] == "1"
    }

    /// `Tests/EspalierUITests/__Snapshots__` (excluded from the target in
    /// Package.swift).
    static let directory: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()   // Support
        .deletingLastPathComponent()   // EspalierUITests
        .appending(path: "__Snapshots__", directoryHint: .isDirectory)

    /// Where failures are written.
    static let artifacts: URL = FileManager.default.temporaryDirectory
        .appending(path: "espalier-snapshots", directoryHint: .isDirectory)

    /// A channel may differ by this much.
    static let channelTolerance = 2
    /// At most this fraction of pixels may differ by more.
    static let pixelTolerance = 0.001
}

/// Compares (or records) a rendered image against its reference.
@MainActor
func assertSnapshot(
    _ image: NSBitmapImageRep,
    named name: String,
    area: String,
    appearance: SnapshotAppearance,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let png = image.representation(using: .png, properties: [:]) else {
        Issue.record("Couldn't encode \(name) as PNG", sourceLocation: sourceLocation)
        return
    }
    let fileName = "\(name)-\(appearance.rawValue).png"
    let reference = SnapshotReferences.directory.appending(path: area).appending(path: fileName)
    let fileManager = FileManager.default

    if SnapshotReferences.isRecording || (SnapshotReferences.isRecordingMissing && !fileManager.fileExists(atPath: reference.path(percentEncoded: false))) {
        do {
            try fileManager.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: reference)
        } catch {
            Issue.record("Couldn't record \(fileName): \(error)", sourceLocation: sourceLocation)
        }
        return
    }

    guard let referenceData = try? Data(contentsOf: reference) else {
        writeArtifact(png, area: area, fileName: fileName)
        Issue.record("No reference for \(area)/\(fileName); record it with ESPALIER_RECORD_SNAPSHOTS=1", sourceLocation: sourceLocation)
        return
    }
    guard let actual = RGBAImage(png), let expected = RGBAImage(referenceData) else {
        Issue.record("Couldn't decode \(area)/\(fileName)", sourceLocation: sourceLocation)
        return
    }
    guard actual.width == expected.width, actual.height == expected.height else {
        writeArtifact(png, area: area, fileName: fileName)
        Issue.record(
            "\(area)/\(fileName) is \(actual.width)×\(actual.height), the reference \(expected.width)×\(expected.height)",
            sourceLocation: sourceLocation
        )
        return
    }
    let comparison = actual.compare(to: expected, tolerance: SnapshotReferences.channelTolerance)
    let allowed = Int(Double(actual.width * actual.height) * SnapshotReferences.pixelTolerance)
    if comparison.differingPixels > allowed {
        writeArtifact(png, area: area, fileName: fileName)
        if let difference = comparison.difference.png {
            writeArtifact(difference, area: area, fileName: fileName.replacingOccurrences(of: ".png", with: "-difference.png"))
        }
        Issue.record(
            "\(area)/\(fileName): \(comparison.differingPixels) pixels differ (\(allowed) allowed); see \(SnapshotReferences.artifacts.path(percentEncoded: false))",
            sourceLocation: sourceLocation
        )
    }
}

/// Snapshots a SwiftUI view in each appearance.
@MainActor
func assertSnapshot(
    _ view: some View,
    named name: String,
    area: String,
    size: CGSize? = nil,
    appearances: [SnapshotAppearance] = SnapshotAppearance.allCases,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for appearance in appearances {
        let image = Snapshot.render(view, size: size, appearance: appearance)
        assertSnapshot(image, named: name, area: area, appearance: appearance, sourceLocation: sourceLocation)
    }
}

/// Snapshots an alert's card in each appearance. `prepare` sets its state
/// (the checkbox) first.
@MainActor
func assertSnapshot(
    _ alert: AlertContent,
    named name: String,
    area: String,
    appearances: [SnapshotAppearance] = SnapshotAppearance.allCases,
    prepare: (AlertCardModel) -> Void = { _ in },
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for appearance in appearances {
        let image = Snapshot.render(alert, appearance: appearance, prepare: prepare)
        assertSnapshot(image, named: name, area: area, appearance: appearance, sourceLocation: sourceLocation)
    }
}

/// Snapshots an AppKit view in each appearance.
@MainActor
func assertSnapshot(
    _ makeView: () -> NSView,
    named name: String,
    area: String,
    size: CGSize,
    appearances: [SnapshotAppearance] = SnapshotAppearance.allCases,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for appearance in appearances {
        let image = Snapshot.render(makeView(), size: size, appearance: appearance)
        assertSnapshot(image, named: name, area: area, appearance: appearance, sourceLocation: sourceLocation)
    }
}

private func writeArtifact(_ data: Data, area: String, fileName: String) {
    let directory = SnapshotReferences.artifacts.appending(path: area, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appending(path: fileName))
}

/// An image as 8-bit RGBA, premultiplied, in sRGB.
struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(_ png: Data) {
        guard let rep = NSBitmapImageRep(data: png), let image = rep.cgImage else {
            return nil
        }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return nil
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// The pixels that differ by more than `tolerance` in a channel, and an
    /// image that shows them in red.
    func compare(to other: RGBAImage, tolerance: Int) -> (differingPixels: Int, difference: RGBAImage) {
        var differing = 0
        var difference = RGBAImage(width: width, height: height, pixels: [UInt8](repeating: 0, count: pixels.count))
        for index in stride(from: 0, to: pixels.count, by: 4) {
            var differs = false
            for channel in 0..<4 where abs(Int(pixels[index + channel]) - Int(other.pixels[index + channel])) > tolerance {
                differs = true
            }
            if differs {
                differing += 1
                difference.pixels[index] = 255
                difference.pixels[index + 3] = 255
            } else {
                // The reference, faded, for orientation.
                difference.pixels[index] = other.pixels[index] / 4
                difference.pixels[index + 1] = other.pixels[index + 1] / 4
                difference.pixels[index + 2] = other.pixels[index + 2] / 4
                difference.pixels[index + 3] = 255
            }
        }
        return (differing, difference)
    }

    /// The image as PNG.
    var png: Data? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { buffer -> Data? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else {
                return nil
            }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
    }
}
