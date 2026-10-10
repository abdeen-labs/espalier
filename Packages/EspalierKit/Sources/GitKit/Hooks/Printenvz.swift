// Ported from desktop/vendor/printenvz (src/printenvz.c and index.js)

import EspalierSupport
import Foundation

/// The program `getShellEnv` runs in the user's login shell. It prints a
/// begin marker, then every environment variable as `KEY=VALUE` followed by
/// a NUL byte, then an end marker.
///
/// A script, so there is no extra binary to build and sign.
private let printenvzScript = #"""
    #!/bin/sh
    # Written by Espalier. Prints the environment for running git hooks.
    printf '%s\n' '--printenvz--begin'
    /usr/bin/env -0
    printf '\n%s\n' '--printenvz--end'

    """#

private let printenvzData = Data(printenvzScript.utf8)

private let printenvzFileName = "espalier-printenvz"

/// Returns the path of the printenvz script, writing the script first if it
/// is missing or has been changed.
///
/// The script lives in the user's temporary directory, which only the user
/// can write to. It is rewritten whenever it is missing (macOS deletes old
/// temporary files), is not a regular file with mode 0700 owned by the
/// current user, or has different contents.
///
/// - Parameter directory: Where to keep the script. Defaults to the user's
///   temporary directory.
public func getPrintenvzPath(in directory: String? = nil) throws -> String {
    let directory = directory ?? FileManager.default.temporaryDirectory.path(percentEncoded: false)
    let path = POSIXPath.join(directory, printenvzFileName)
    if !isPrintenvzInstalled(at: path) {
        try installPrintenvz(at: path, in: directory)
    }
    return path
}

/// Whether `path` is the printenvz script: a regular file (not a symbolic
/// link) owned by the current user, with mode 0700 and the expected contents.
private func isPrintenvzInstalled(at path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == geteuid(),
          (info.st_mode & 0o7777) == 0o700
    else {
        return false
    }
    return FileManager.default.contents(atPath: path) == printenvzData
}

/// Writes the script to a new file in `directory` and renames it to `path`,
/// so that nobody ever runs a partly written or non-executable script.
private func installPrintenvz(at path: String, in directory: String) throws {
    let temporaryPath = POSIXPath.join(directory, ".\(printenvzFileName)-\(UUID().uuidString)")
    do {
        try printenvzData.write(to: URL(filePath: temporaryPath), options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryPath)
        guard rename(temporaryPath, path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    } catch {
        try? FileManager.default.removeItem(atPath: temporaryPath)
        throw error
    }
}
