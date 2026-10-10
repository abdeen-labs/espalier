// Ported from desktop/app/src/lib/editors/darwin.ts

import EspalierSupport
import GitKit
import os

private let logger = Log.logger(category: "integrations")

/// Represents an external editor on macOS
struct DarwinExternalEditor: Sendable, Hashable {
    /// Name of the editor. It will be used both as identifier and user-facing.
    let name: String

    /// List of bundle identifiers that are used by the app in its multiple
    /// versions.
    let bundleIdentifiers: [String]
}

/// This list contains all the external editors supported on macOS. Add a new
/// entry here to add support for your favorite editor.
///
/// The order matters: the first installed editor is the default.
let darwinExternalEditors: [DarwinExternalEditor] = [
    DarwinExternalEditor(name: "Atom", bundleIdentifiers: ["com.github.atom"]),
    DarwinExternalEditor(name: "Aptana Studio", bundleIdentifiers: ["aptana.studio"]),
    DarwinExternalEditor(name: "Eclipse IDE for Java Developers", bundleIdentifiers: ["epp.package.java"]),
    DarwinExternalEditor(
        name: "Eclipse IDE for Enterprise Java and Web Developers",
        bundleIdentifiers: ["epp.package.jee"]
    ),
    DarwinExternalEditor(name: "Eclipse IDE for C/C++ Developers", bundleIdentifiers: ["epp.package.cpp"]),
    DarwinExternalEditor(name: "Eclipse IDE for Eclipse Committers", bundleIdentifiers: ["epp.package.committers"]),
    DarwinExternalEditor(
        name: "Eclipse IDE for Embedded C/C++ Developers",
        bundleIdentifiers: ["epp.package.embedcpp"]
    ),
    DarwinExternalEditor(name: "Eclipse IDE for PHP Developers", bundleIdentifiers: ["epp.package.php"]),
    DarwinExternalEditor(name: "Eclipse IDE for Java and DSL Developers", bundleIdentifiers: ["epp.package.dsl"]),
    DarwinExternalEditor(name: "Eclipse IDE for RCP and RAP Developers", bundleIdentifiers: ["epp.package.rcp"]),
    DarwinExternalEditor(name: "Eclipse Modeling Tools", bundleIdentifiers: ["epp.package.modeling"]),
    DarwinExternalEditor(name: "Eclipse IDE for Scientific Computing", bundleIdentifiers: ["epp.package.parallel"]),
    DarwinExternalEditor(name: "Eclipse IDE for Scout Developers", bundleIdentifiers: ["epp.package.scout"]),
    DarwinExternalEditor(name: "MacVim", bundleIdentifiers: ["org.vim.MacVim"]),
    DarwinExternalEditor(name: "Neovide", bundleIdentifiers: ["com.neovide.neovide"]),
    DarwinExternalEditor(name: "VimR", bundleIdentifiers: ["com.qvacua.VimR"]),
    DarwinExternalEditor(name: "Visual Studio Code", bundleIdentifiers: ["com.microsoft.VSCode"]),
    DarwinExternalEditor(name: "Visual Studio Code (Insiders)", bundleIdentifiers: ["com.microsoft.VSCodeInsiders"]),
    DarwinExternalEditor(name: "VSCodium", bundleIdentifiers: ["com.visualstudio.code.oss", "com.vscodium"]),
    DarwinExternalEditor(
        name: "Sublime Text",
        bundleIdentifiers: ["com.sublimetext.4", "com.sublimetext.3", "com.sublimetext.2"]
    ),
    DarwinExternalEditor(name: "BBEdit", bundleIdentifiers: ["com.barebones.bbedit"]),
    DarwinExternalEditor(name: "PhpStorm", bundleIdentifiers: ["com.jetbrains.PhpStorm"]),
    DarwinExternalEditor(name: "PyCharm", bundleIdentifiers: ["com.jetbrains.PyCharm"]),
    DarwinExternalEditor(name: "PyCharm Community Edition", bundleIdentifiers: ["com.jetbrains.pycharm.ce"]),
    DarwinExternalEditor(name: "DataSpell", bundleIdentifiers: ["com.jetbrains.DataSpell"]),
    DarwinExternalEditor(name: "RubyMine", bundleIdentifiers: ["com.jetbrains.RubyMine"]),
    DarwinExternalEditor(name: "RustRover", bundleIdentifiers: ["com.jetbrains.RustRover"]),
    DarwinExternalEditor(name: "RStudio", bundleIdentifiers: ["org.rstudio.RStudio", "com.rstudio.desktop"]),
    DarwinExternalEditor(name: "TextMate", bundleIdentifiers: ["com.macromates.TextMate"]),
    DarwinExternalEditor(name: "Brackets", bundleIdentifiers: ["io.brackets.appshell"]),
    DarwinExternalEditor(name: "WebStorm", bundleIdentifiers: ["com.jetbrains.WebStorm"]),
    DarwinExternalEditor(name: "CLion", bundleIdentifiers: ["com.jetbrains.CLion"]),
    DarwinExternalEditor(name: "Typora", bundleIdentifiers: ["abnerworks.Typora"]),
    DarwinExternalEditor(name: "CodeRunner", bundleIdentifiers: ["com.krill.CodeRunner"]),
    DarwinExternalEditor(
        name: "SlickEdit",
        bundleIdentifiers: [
            "com.slickedit.SlickEditPro2018",
            "com.slickedit.SlickEditPro2017",
            "com.slickedit.SlickEditPro2016",
            "com.slickedit.SlickEditPro2015",
        ]
    ),
    DarwinExternalEditor(name: "IntelliJ", bundleIdentifiers: ["com.jetbrains.intellij"]),
    DarwinExternalEditor(name: "IntelliJ Community Edition", bundleIdentifiers: ["com.jetbrains.intellij.ce"]),
    DarwinExternalEditor(name: "Xcode", bundleIdentifiers: ["com.apple.dt.Xcode"]),
    DarwinExternalEditor(name: "GoLand", bundleIdentifiers: ["com.jetbrains.goland"]),
    DarwinExternalEditor(name: "Android Studio", bundleIdentifiers: ["com.google.android.studio"]),
    DarwinExternalEditor(name: "Rider", bundleIdentifiers: ["com.jetbrains.rider"]),
    DarwinExternalEditor(name: "Nova", bundleIdentifiers: ["com.panic.Nova"]),
    DarwinExternalEditor(name: "Emacs", bundleIdentifiers: ["org.gnu.Emacs"]),
    DarwinExternalEditor(name: "Lite XL", bundleIdentifiers: ["com.lite-xl"]),
    DarwinExternalEditor(name: "Fleet", bundleIdentifiers: ["Fleet.app"]),
    DarwinExternalEditor(name: "Pulsar", bundleIdentifiers: ["dev.pulsar-edit.pulsar"]),
    DarwinExternalEditor(name: "Zed", bundleIdentifiers: ["dev.zed.Zed"]),
    DarwinExternalEditor(name: "Zed (Preview)", bundleIdentifiers: ["dev.zed.Zed-Preview"]),
    DarwinExternalEditor(name: "Cursor", bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"]),
    DarwinExternalEditor(name: "Windsurf", bundleIdentifiers: ["com.exafunction.windsurf"]),
]

/// The installed copy of `editor`: the first of its bundle identifiers that
/// Launch Services knows and whose application still exists.
func findApplication(_ editor: DarwinExternalEditor, locator: any ApplicationLocator) async -> String? {
    for identifier in editor.bundleIdentifiers {
        // Not finding the app isn't an error, it just means the bundle isn't
        // registered on the machine.
        let installPath = locator.appPath(identifier)

        if let installPath, await pathExists(installPath) {
            return installPath
        }

        logger.debug(
            "App installation for \(editor.name, privacy: .public) not found at '\(installPath ?? "null", privacy: .private)'"
        )
    }

    return nil
}

/// Lookup known external editors using the bundle ID that each uses
/// to register itself on a user's machine when installing.
///
/// The editors come back in the order of `darwinExternalEditors`.
@concurrent
func getAvailableEditorsDarwin(locator: any ApplicationLocator) async -> [FoundEditor] {
    var results: [FoundEditor] = []

    for editor in darwinExternalEditors {
        if let path = await findApplication(editor, locator: locator) {
            results.append(FoundEditor(editor: editor.name, path: path))
        }
    }

    return results
}
