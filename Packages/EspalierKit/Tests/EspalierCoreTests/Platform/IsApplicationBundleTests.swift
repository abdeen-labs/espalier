// The content type is read from the file system; these test the rules
// applied to it, with an application, a plain folder, and an unknown type
// that conforms to public.directory among the cases.

@testable import EspalierCore
import Foundation
import Testing
import TestSupport
import UniformTypeIdentifiers

@Suite("isApplicationBundle")
struct IsApplicationBundleTests {
    @Test("classifies content types with desktop's rules")
    func contentTypes() throws {
        #expect(try isApplicationBundle(contentType: .applicationBundle))
        #expect(try isApplicationBundle(contentType: .application))
        #expect(try isApplicationBundle(contentType: .unixExecutable))
        #expect(try !isApplicationBundle(contentType: .folder))
        #expect(throws: InconclusiveBundleMetadataError.self) {
            try isApplicationBundle(contentType: .bundle)
        }
        #expect(throws: InconclusiveBundleMetadataError.self) {
            try isApplicationBundle(contentType: .package)
        }
        #expect(throws: InconclusiveBundleMetadataError.self) {
            try isApplicationBundle(contentType: .volume)
        }
    }

    @Test("reads a path's content type from the file system, through symbolic links")
    func paths() async throws {
        let directory = try createTempDirectory()
        let app = try makeFakeApplication(in: directory, named: "Tool.app", bundleIdentifier: "com.example.tool")
        let folder = "\(directory)/Folder"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let bundle = "\(directory)/Plugin.bundle"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(directory)/Link", withDestinationPath: app)
        try FileManager.default.createSymbolicLink(atPath: "\(directory)/FolderLink", withDestinationPath: folder)

        #expect(try await isApplicationBundle(app))
        #expect(try await isApplicationBundle("\(directory)/Link"))
        #expect(try await !isApplicationBundle(folder))
        #expect(try await !isApplicationBundle("\(directory)/FolderLink"))
        await #expect(throws: InconclusiveBundleMetadataError.self) {
            try await isApplicationBundle(bundle)
        }
        await #expect(throws: (any Error).self) {
            try await isApplicationBundle("\(directory)/missing")
        }
    }
}
