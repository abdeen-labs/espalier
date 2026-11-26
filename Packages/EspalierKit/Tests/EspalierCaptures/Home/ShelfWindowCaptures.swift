// The main window with the shelf: harbor's Changes under the shelf of the
// work in five repositories, with the Home button in the toolbar; the same
// with Home off (no Home button); and the window on Home (the "Home"
// capsule and the jump field, no repository's items, and no shelf), with
// four cards and docs-site In Progress, the first card alone ringed.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

extension MainToolbarWindows {
    @Suite("Shelf window", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
    struct ShelfWindowCaptures {
        private let area = "ShelfWindow"

        /// harbor, selected at Changes with two changed files, then
        /// pier-api, buoy-ios, lighthouse, and docs-site with changed files
        /// of their own. Status is on. Every repository but docs-site was
        /// last written 20 minutes before the app's clock, so its work needs
        /// the user; docs-site a minute before, so it's changing now.
        private func fixture() async throws -> MainWindowFixture {
            let now = ManualScheduler().now
            let local = try setupEmptyRepository("main")
            try await makeCommit(local, Tree(entries: [
                TreeEntry(path: "TideStore.swift", contents: "import Foundation\n\nfinal class TideStore {}\n"),
                TreeEntry(path: "StationView.swift", contents: "import SwiftUI\n"),
            ]))
            try Data("import Foundation\n\n/// Keeps the last tides on disk.\nfinal class TideStore {}\n".utf8)
                .write(to: URL(filePath: POSIXPath.join(local.path, "TideStore.swift")))
            try Data("import SwiftUI\nimport Charts\n".utf8)
                .write(to: URL(filePath: POSIXPath.join(local.path, "StationView.swift")))
            try setModified(local, ["TideStore.swift", "StationView.swift"], to: now.addingTimeInterval(-20 * 60))
            let fixture = try await MainWindowFixture.make(local)
            let app = fixture.app
            app.preferences.repositoryIndicatorsEnabled = true
            for (name, changed) in [("pier-api", 3), ("buoy-ios", 2), ("lighthouse", 5), ("docs-site", 1)] {
                let repository = try setupEmptyRepository("main")
                let files = (1...changed).map { "File\($0).swift" }
                try await makeCommit(repository, Tree(entries: files.map { TreeEntry(path: $0, contents: "// \(name)\n") }))
                for file in files {
                    try Data("// \(name), changed\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, file)))
                }
                try setModified(repository, files, to: now.addingTimeInterval(name == "docs-site" ? -60 : -20 * 60))
                let model = try await fixture.harness.addAndSelect(repository, to: app)
                await app.idle()
                app.setAlias(name, for: model.id)
            }
            app.select(.repository(fixture.repository.id))
            app.setAlias("harbor", for: fixture.repository.id)
            fixture.context.state.select(.changes, in: fixture.repository.id)
            await fixture.settle()
            return fixture
        }

        /// Sets `files` and the record of HEAD's moves (what a piece of
        /// work's last change is read from) in `repository` to have last
        /// changed at `date`.
        private func setModified(_ repository: Repository, _ files: [String], to date: Date) throws {
            let paths = files.map { POSIXPath.join(repository.path, $0) } + [POSIXPath.join(repository.path, ".git/logs/HEAD")]
            for path in paths {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
            }
        }

        /// Draws `fixture`'s window in each appearance once it has stopped
        /// changing.
        private func captureWindow(_ fixture: MainWindowFixture, named name: String) async {
            FlatWindowChrome.install()
            for appearance in CaptureAppearance.allCases {
                var stage: MainWindowStage? = autoreleasepool {
                    MainWindowStage(fixture.context, appearance: appearance)
                }
                await stage?.settle { true }
                let image = stage?.image
                autoreleasepool {
                    stage?.close()
                    stage = nil
                }
                if let image {
                    capture(named: name, area: area, appearances: [appearance]) { _ in image }
                }
                // The window's toolbar leaves the family once it's released.
                await Task.yield()
            }
            await fixture.settle()
        }

        @Test("Changes under the shelf, the Home button before the location control")
        func changes() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await fixture()
                fixture.app.preferences.showsHome = true
                await captureWindow(fixture, named: "changes")
            }
        }

        @Test("Changes under the shelf with Home off: the toolbar as before")
        func homeOff() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await fixture()
                fixture.app.preferences.showsHome = false
                await captureWindow(fixture, named: "changes-home-off")
            }
        }

        @Test("on Home: the Home capsule and the jump field, and no shelf")
        func home() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await fixture()
                fixture.app.preferences.showsHome = true
                fixture.context.state.isShowingHome = true
                await captureWindow(fixture, named: "home")
            }
        }

        @Test("on Home, the window becoming key with nothing holding the keyboard gives it to Home; a field keeps it")
        func homeTakesKeyboard() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await fixture()
                fixture.app.preferences.showsHome = true
                fixture.context.state.isShowingHome = true
                FlatWindowChrome.install()
                var stage: MainWindowStage? = MainWindowStage(fixture.context, appearance: .light)
                await stage?.settle { true }
                let window = try #require(stage?.window)
                let becomeKey = {
                    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
                }

                // As at launch: the window becomes key with nothing holding
                // the keyboard, and Home takes it.
                window.makeFirstResponder(nil)
                #expect(window.firstResponder === window)
                becomeKey()
                await stage?.settle { true }
                #expect(window.firstResponder !== window && window.firstResponder !== window.contentView)

                // A field the user put the keyboard in keeps it.
                let field = NSTextField()
                window.contentView?.addSubview(field)
                window.makeFirstResponder(field)
                let held = window.firstResponder
                becomeKey()
                await stage?.settle { true }
                #expect(window.firstResponder === held)

                field.removeFromSuperview()
                stage?.close()
                stage = nil
                await Task.yield()
                await fixture.settle()
            }
        }
    }
}
