// Ported from desktop/app/src/lib/patch-formatter.ts

import EspalierSupport
import os

private let logger = Log.logger(category: "patch-formatter")

/// Generates a string matching the format of a GNU unified diff header excluding
/// the (optional) timestamp fields
///
/// Note that this multi-line string includes a trailing newline.
///
/// - Parameters:
///   - from: The relative path to the original version of the file or
///     nil if the file is newly created.
///   - to: The relative path to the new version of the file or
///     nil if the file is the file is newly created.
private func formatPatchHeader(_ from: String?, _ to: String?) -> String {
    // https://en.wikipedia.org/wiki/Diff_utility
    //
    // > At the beginning of the patch is the file information, including the full
    // > path and a time stamp delimited by a tab character.
    // >
    // > [...] the original file is preceded by "---" and the new file is preceded
    // > by "+++".
    //
    // We skip the time stamp to match git
    let fromPath = from.flatMap { $0.isEmpty ? nil : quotePatchPath("a/\($0)") } ?? "/dev/null"
    let toPath = to.flatMap { $0.isEmpty ? nil : quotePatchPath("b/\($0)") } ?? "/dev/null"

    return "--- \(fromPath)\n+++ \(toPath)\n"
}

/// A patch header's path as git writes it (`quote_c_style`): in double
/// quotes with C escapes when it has a control character, a double quote,
/// or a backslash; otherwise as is (non-ASCII stays raw, as with
/// `core.quotePath` off, which `git apply` reads either way).
///
/// Written as is, a name with a tab would be read by `git apply` only up to
/// the tab, and a newline would break the header.
public func quotePatchPath(_ path: String) -> String {
    let needsQuoting = path.utf8.contains { $0 < 0x20 || $0 == 0x7F || $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") }
    guard needsQuoting else {
        return path
    }
    var quoted: [UInt8] = [UInt8(ascii: "\"")]
    for byte in path.utf8 {
        switch byte {
        case UInt8(ascii: "\""): quoted += Array("\\\"".utf8)
        case UInt8(ascii: "\\"): quoted += Array("\\\\".utf8)
        case 0x07: quoted += Array("\\a".utf8)
        case 0x08: quoted += Array("\\b".utf8)
        case 0x09: quoted += Array("\\t".utf8)
        case 0x0A: quoted += Array("\\n".utf8)
        case 0x0B: quoted += Array("\\v".utf8)
        case 0x0C: quoted += Array("\\f".utf8)
        case 0x0D: quoted += Array("\\r".utf8)
        case ..<0x20, 0x7F:
            let octal = String(byte, radix: 8)
            quoted += Array("\\\(String(repeating: "0", count: 3 - octal.count))\(octal)".utf8)
        default:
            quoted.append(byte)
        }
    }
    quoted.append(UInt8(ascii: "\""))
    return String(decoding: quoted, as: UTF8.self)
}

/// Generates a string matching the format of a GNU unified diff header excluding
/// the (optional) timestamp fields with the appropriate from/to file names based
/// on the file state of the given WorkingDirectoryFileChange
private func formatPatchHeaderForFile(_ file: WorkingDirectoryFileChange) -> String {
    switch file.status.kind {
    case .new, .untracked:
        return formatPatchHeader(nil, file.path)

    // One might initially believe that renamed files should diff
    // against their old path. This is, after all, how git diff
    // does it right after a rename. But if we're creating a patch
    // to be applied along with a rename we must target the renamed
    // file.
    case .renamed, .deleted, .modified, .copied,
        // We should not have the ability to format a file that's marked as
        // conflicted without more information about it's current state.
        .conflicted:
        return formatPatchHeader(file.path, file.path)
    }
}

/// Generates a string matching the format of a GNU unified diff hunk header.
/// Note that this single line string includes a single trailing newline.
///
/// - Parameters:
///   - oldStartLine: The line in the old (or original) file where this diff
///     hunk starts.
///   - oldLineCount: The number of lines in the old (or original) file that
///     this diff hunk covers.
///   - newStartLine: The line in the new file where this diff hunk starts
///   - newLineCount: The number of lines in the new file that this diff hunk
///     covers
private func formatHunkHeader(
    _ oldStartLine: Int,
    _ oldLineCount: Int,
    _ newStartLine: Int,
    _ newLineCount: Int,
    _ sectionHeading: String? = nil
) -> String {
    // > @@ -l,s +l,s @@ optional section heading
    // >
    // > The hunk range information contains two hunk ranges. The range for the hunk of the original
    // > file is preceded by a minus symbol, and the range for the new file is preceded by a plus
    // > symbol. Each hunk range is of the format l,s where l is the starting line number and s is
    // > the number of lines the change hunk applies to for each respective file.
    // >
    // > In many versions of GNU diff, each range can omit the comma and trailing value s,
    // > in which case s defaults to 1
    let lineInfoBefore = oldLineCount == 1 ? "\(oldStartLine)" : "\(oldStartLine),\(oldLineCount)"

    let lineInfoAfter = newLineCount == 1 ? "\(newStartLine)" : "\(newStartLine),\(newLineCount)"

    let heading = sectionHeading.flatMap { $0.isEmpty ? nil : " \($0)" } ?? ""

    return "@@ -\(lineInfoBefore) +\(lineInfoAfter) @@\(heading)\n"
}

/// Creates a GNU unified diff based on the original diff and a number
/// of selected or unselected lines (from file.selection). The patch is
/// formatted with the intention of being used for applying against an index
/// with git apply.
///
/// Note that the file must have at least one selected addition or deletion,
/// ie it's not supported to use this method as a general purpose diff
/// formatter.
///
/// - Parameters:
///   - file: The file that the resulting patch will be applied to.
///     This is used to determine the from and to paths for the
///     patch header as well as retrieving the line selection state
///   - diff: The source diff
/// - Throws: `GitLibError` when the selection includes no changes.
public func formatPatch(_ file: WorkingDirectoryFileChange, _ diff: some TextDiffData) throws -> String {
    guard isByteExact(diff) else {
        throw GitLibError(notByteExactMessage(file.path, "committed"))
    }

    var patch = ""

    for hunk in diff.hunks {
        var hunkLines: [PatchLine] = []

        var oldCount = 0
        var newCount = 0

        var anyAdditionsOrDeletions = false

        for (lineIndex, line) in hunk.lines.enumerated() {
            let absoluteIndex = hunk.unifiedDiffStart + lineIndex

            // We write our own hunk headers
            if line.type == .hunk {
                continue
            }

            // Context lines can always be let through, they will
            // never appear for new files.
            if line.type == .context {
                hunkLines.append(PatchLine(line, " "))
                oldCount += 1
                newCount += 1
            } else if file.selection.isSelected(absoluteIndex) {
                // A line selected for inclusion.

                // Use the line as-is
                hunkLines.append(PatchLine(line, line.type == .add ? "+" : "-"))

                if line.type == .add {
                    newCount += 1
                }
                if line.type == .delete {
                    oldCount += 1
                }

                anyAdditionsOrDeletions = true
            } else {
                // Unselected lines in new files needs to be ignored. A new file by
                // definition only consists of additions and therefore so will the
                // partial patch. If the user has elected not to commit a particular
                // addition we need to generate a patch that pretends that the line
                // never existed.
                if file.status.kind == .new || file.status.kind == .untracked {
                    continue
                }

                // An unselected added line has no impact on this patch, pretend
                // it was never added to the old file by dropping it.
                if line.type == .add {
                    continue
                }

                // An unselected deleted line has never happened as far as this patch
                // is concerned which means that we should treat it as if it's still
                // in the old file so we'll convert it to a context line.
                hunkLines.append(PatchLine(line, " "))
                oldCount += 1
                newCount += 1
            }
        }

        // Skip writing this hunk if all there is is context lines.
        if !anyAdditionsOrDeletions {
            continue
        }

        patch += formatHunkHeader(hunk.header.oldStartLine, oldCount, hunk.header.newStartLine, newCount)
        patch += formatHunkLines(hunkLines)
    }

    // If we get into this state we should never have been called in the first
    // place. Someone gave us a faulty diff and/or faulty selection state.
    if patch.isEmpty {
        logger.debug("formatPatch: empty path for \(file.path, privacy: .private)")
        throw GitLibError("Could not generate a patch, no changes")
    }

    patch = formatPatchHeaderForFile(file) + patch

    return patch
}

/// Whether a patch built from `diff`'s lines writes back the file's bytes:
/// no line has U+FFFD, which stands for bytes that aren't UTF-8 (a Latin-1
/// file's), since the diff is read as UTF-8.
///
/// A patch from such lines would write U+FFFD's bytes in place of the
/// file's (or fail on a context line), whether committing some lines of a
/// Latin-1 file or discarding a removed line. A file that really has U+FFFD
/// is refused too, as the two can't be told apart from the text.
public func isByteExact(_ diff: some TextDiffData) -> Bool {
    !diff.hunks.contains { hunk in
        hunk.lines.contains { $0.text.unicodeScalars.contains("\u{FFFD}") }
    }
}

/// Why lines of `path`, whose diff a textconv program converts, can't be
/// `verb` ("committed", "discarded").
public func textConvertedMessage(_ path: String, _ verb: String) -> String {
    "Some lines of \(path) can't be \(verb) on their own because a diff driver converts its text for display. Include or discard the whole file instead."
}

/// Why lines of `path` can't be `verb` ("committed", "discarded").
public func notByteExactMessage(_ path: String, _ verb: String) -> String {
    "Some lines of \(path) can't be \(verb) on their own because the file isn't UTF-8 text. Include or discard the whole file instead."
}

/// Creates a GNU unified diff to discard a set of changes (determined by the selection object)
/// based on the passed diff and a number of selected or unselected lines.
///
/// The patch is formatted with the intention of being used for applying against an index
/// with git apply.
///
/// Note that the diff must have at least one selected addition or deletion.
///
/// This method is the opposite of formatPatch().
///
/// - Parameters:
///   - filePath: The path of the file that the resulting patch will be applied to.
///     This is used to determine the from and to paths for the
///     patch header.
///   - diff: All the local changes for that file.
///   - selection: A selection of lines from the diff object that we want to discard.
public func formatPatchToDiscardChanges(
    _ filePath: String,
    _ diff: some TextDiffData,
    _ selection: DiffSelection
) -> String? {
    var patch = ""

    for hunk in diff.hunks {
        var hunkLines: [PatchLine] = []

        var oldCount = 0
        var newCount = 0

        var anyAdditionsOrDeletions = false

        for (lineIndex, line) in hunk.lines.enumerated() {
            let absoluteIndex = hunk.unifiedDiffStart + lineIndex

            // We write our own hunk headers
            if line.type == .hunk {
                continue
            }

            // Context lines can always be let through, they will
            // never appear for new files.
            if line.type == .context {
                hunkLines.append(PatchLine(line, " "))
                oldCount += 1
                newCount += 1
            } else if selection.isSelected(absoluteIndex) {
                // Reverse the change (if it was an added line, treat it as removed and vice versa).
                if line.type == .add {
                    hunkLines.append(PatchLine(line, "-"))
                    newCount += 1
                } else {
                    hunkLines.append(PatchLine(line, "+"))
                    oldCount += 1
                }

                anyAdditionsOrDeletions = true
            } else {
                if line.type == .add {
                    // An unselected added line will stay in the file after discarding the changes,
                    // so we just print it untouched on the diff.
                    oldCount += 1
                    newCount += 1
                    hunkLines.append(PatchLine(line, " "))
                } else {
                    // An unselected removed line has no impact on this patch since it's not
                    // found on the current working copy of the file, so we can ignore it.
                    continue
                }
            }
        }

        // Skip writing this hunk if all there is is context lines.
        if !anyAdditionsOrDeletions {
            continue
        }

        patch += formatHunkHeader(hunk.header.newStartLine, newCount, hunk.header.oldStartLine, oldCount)
        patch += formatHunkLines(hunkLines)
    }

    if patch.isEmpty {
        // The selection resulted in an empty patch.
        return nil
    }

    return formatPatchHeader(filePath, filePath) + patch
}

/// A line of a hunk being written: a diff line under the prefix it takes in
/// the patch (" ", "+", or "-").
private struct PatchLine {
    let line: DiffLine
    let prefix: Unicode.Scalar

    init(_ line: DiffLine, _ prefix: Unicode.Scalar) {
        self.line = line
        self.prefix = prefix
    }
}

/// The lines of a hunk, each with "No newline at end of file" after it
/// where it ends its side of the file without one.
///
/// A line the diff marks as having no newline ends the file it comes from,
/// so the marker always holds on the patch's old side. On the new side it
/// holds only while no line follows there: an added line followed by
/// another line on the new side is written with its newline, and a
/// context line followed by one becomes a removal (with the marker) and an
/// addition (with the newline). Otherwise git would join the next line to
/// it.
private func formatHunkLines(_ lines: [PatchLine]) -> String {
    // A line before the last one on the new side (context or an addition)
    // is followed by a line there.
    let lastOnNewSide = lines.lastIndex { $0.prefix != "-" } ?? -1
    var buf = ""
    for (index, patchLine) in lines.enumerated() {
        let line = patchLine.line
        let newSideFollows = index < lastOnNewSide
        switch patchLine.prefix {
        case "-":
            buf.appendLine(line.text, prefix: "-")
            if line.noTrailingNewLine {
                buf += noNewlineMarker
            }
        case "+":
            buf.appendLine(line.text, prefix: "+")
            if line.noTrailingNewLine, !newSideFollows {
                buf += noNewlineMarker
            }
        default:
            if line.noTrailingNewLine, newSideFollows {
                buf.appendLine(line.text, prefix: "-")
                buf += noNewlineMarker
                buf.appendLine(line.text, prefix: "+")
            } else {
                buf.appendLine(line.text, prefix: " ")
                if line.noTrailingNewLine {
                    buf += noNewlineMarker
                }
            }
        }
    }
    return buf
}

private let noNewlineMarker = "\\ No newline at end of file\n"

extension String {
    /// Appends `line` with `prefix` in place of its first character (its
    /// own prefix), and a newline.
    fileprivate mutating func appendLine(_ line: String, prefix: Unicode.Scalar) {
        if line.unicodeScalars.first == prefix {
            append(line)
        } else {
            unicodeScalars.append(prefix)
            unicodeScalars.append(contentsOf: line.unicodeScalars.dropFirst())
        }
        append("\n")
    }
}
