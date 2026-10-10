// Ported from Node.js lib/path.js (the posix implementation).

import Foundation

/// String path operations with Node's `path.posix` semantics, including its
/// edge cases (`join` returns `"."` for nothing, `normalize` keeps a trailing
/// slash, `resolve` strips one).
public enum POSIXPath {
    public static let separator = "/"

    /// Whether `path` is absolute.
    public static func isAbsolute(_ path: String) -> Bool {
        path.utf8.first == slash
    }

    /// Normalizes `path`, resolving `..` and `.` segments and collapsing
    /// repeated separators. Keeps a trailing separator. An empty path
    /// normalizes to `"."`.
    public static func normalize(_ path: String) -> String {
        let bytes = Array(path.utf8)
        if bytes.isEmpty {
            return "."
        }

        let absolute = bytes.first == slash
        let trailingSeparator = bytes.last == slash

        var result = normalizeString(bytes, allowAboveRoot: !absolute)

        if result.isEmpty {
            if absolute {
                return "/"
            }
            return trailingSeparator ? "./" : "."
        }
        if trailingSeparator {
            result.append(slash)
        }
        return (absolute ? "/" : "") + String(decoding: result, as: UTF8.self)
    }

    /// Joins the non-empty segments with `/` and normalizes the result.
    public static func join(_ segments: String...) -> String {
        join(segments)
    }

    /// Joins the non-empty segments with `/` and normalizes the result.
    public static func join(_ segments: [String]) -> String {
        let joined = segments.filter { !$0.isEmpty }.joined(separator: "/")
        return joined.isEmpty ? "." : normalize(joined)
    }

    /// Resolves the segments into an absolute path, right to left, until an
    /// absolute path is formed, falling back to the current directory.
    /// Removes trailing separators.
    public static func resolve(_ segments: String...) -> String {
        resolve(segments)
    }

    /// Resolves the segments into an absolute path, right to left, until an
    /// absolute path is formed, falling back to `currentDirectory`.
    ///
    /// When there is nothing to resolve (no segments, or just `""` or `"."`)
    /// and `currentDirectory` is absolute, returns it as is, without
    /// normalizing it, as Node does.
    public static func resolve(
        _ segments: [String],
        currentDirectory: @autoclosure () -> String = FileManager.default.currentDirectoryPath
    ) -> String {
        var cwd: String?
        if segments.isEmpty || (segments.count == 1 && (segments[0].isEmpty || isDot(segments[0]))) {
            let directory = currentDirectory()
            if directory.utf8.first == slash {
                return directory
            }
            cwd = directory
        }

        var resolvedPath: [UInt8] = []
        var resolvedAbsolute = false

        var index = segments.count - 1
        while index >= -1, !resolvedAbsolute {
            let path = index >= 0 ? segments[index] : (cwd ?? currentDirectory())
            index -= 1
            if path.isEmpty {
                continue
            }
            resolvedPath = Array(path.utf8) + [slash] + resolvedPath
            resolvedAbsolute = path.utf8.first == slash
        }

        let normalized = normalizeString(resolvedPath, allowAboveRoot: !resolvedAbsolute)
        if resolvedAbsolute {
            return "/" + String(decoding: normalized, as: UTF8.self)
        }
        return normalized.isEmpty ? "." : String(decoding: normalized, as: UTF8.self)
    }

    /// The directory portion of `path`.
    public static func dirname(_ path: String) -> String {
        let bytes = Array(path.utf8)
        if bytes.isEmpty {
            return "."
        }
        let hasRoot = bytes[0] == slash
        var end = -1
        var matchedSlash = true
        var index = bytes.count - 1
        while index >= 1 {
            if bytes[index] == slash {
                if !matchedSlash {
                    end = index
                    break
                }
            } else {
                matchedSlash = false
            }
            index -= 1
        }

        if end == -1 {
            return hasRoot ? "/" : "."
        }
        if hasRoot, end == 1 {
            return "//"
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    /// The last portion of `path`, without `suffix` when it ends with it.
    public static func basename(_ path: String, _ suffix: String? = nil) -> String {
        let bytes = Array(path.utf8)
        var start = 0
        var end = -1
        var matchedSlash = true

        // Node only tries the suffix when it is no longer than the path in
        // UTF-16 code units. The scan below works on UTF-8 bytes and agrees
        // with Node's once it runs, but deciding by byte count would try
        // suffixes that Node skips, and a suffix the last component only
        // partly matches keeps trailing separators ("b/" rather than "b").
        if let suffix, !suffix.isEmpty, suffix.utf16.count <= path.utf16.count {
            let ext = Array(suffix.utf8)
            if ext == bytes {
                return ""
            }
            var extIndex = ext.count - 1
            var firstNonSlashEnd = -1
            var index = bytes.count - 1
            while index >= 0 {
                let code = bytes[index]
                if code == slash {
                    if !matchedSlash {
                        start = index + 1
                        break
                    }
                } else {
                    if firstNonSlashEnd == -1 {
                        matchedSlash = false
                        firstNonSlashEnd = index + 1
                    }
                    if extIndex >= 0 {
                        if code == ext[extIndex] {
                            extIndex -= 1
                            if extIndex == -1 {
                                end = index
                            }
                        } else {
                            extIndex = -1
                            end = firstNonSlashEnd
                        }
                    }
                }
                index -= 1
            }

            if start == end {
                end = firstNonSlashEnd
            } else if end == -1 {
                end = bytes.count
            }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        var index = bytes.count - 1
        while index >= 0 {
            if bytes[index] == slash {
                if !matchedSlash {
                    start = index + 1
                    break
                }
            } else if end == -1 {
                matchedSlash = false
                end = index + 1
            }
            index -= 1
        }

        if end == -1 {
            return ""
        }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// The extension of `path`, from the last `.` in its last portion, or an
    /// empty string.
    public static func extname(_ path: String) -> String {
        let bytes = Array(path.utf8)
        var startDot = -1
        var startPart = 0
        var end = -1
        var matchedSlash = true
        // Tracks the state of characters (if any) we see before the first
        // dot and after any path separator we find.
        var preDotState = 0

        var index = bytes.count - 1
        while index >= 0 {
            let code = bytes[index]
            if code == slash {
                if !matchedSlash {
                    startPart = index + 1
                    break
                }
                index -= 1
                continue
            }
            if end == -1 {
                matchedSlash = false
                end = index + 1
            }
            if code == dot {
                if startDot == -1 {
                    startDot = index
                } else if preDotState != 1 {
                    preDotState = 1
                }
            } else if startDot != -1 {
                preDotState = -1
            }
            index -= 1
        }

        if startDot == -1
            || end == -1
            || preDotState == 0
            || (preDotState == 1 && startDot == end - 1 && startDot == startPart + 1) {
            return ""
        }
        return String(decoding: bytes[startDot..<end], as: UTF8.self)
    }

    /// The relative path from `from` to `to`, after resolving both.
    public static func relative(_ from: String, _ to: String) -> String {
        // Compare code units, as JavaScript does. `==` would treat
        // canonically equivalent paths, such as precomposed and decomposed
        // "é", as the same path.
        if from.utf8.elementsEqual(to.utf8) {
            return ""
        }

        let fromResolved = Array(resolve(from).utf8)
        let toResolved = Array(resolve(to).utf8)
        if fromResolved == toResolved {
            return ""
        }

        let fromStart = 1
        let fromEnd = fromResolved.count
        let fromLength = fromEnd - fromStart
        let toStart = 1
        let toLength = toResolved.count - toStart

        let length = fromLength < toLength ? fromLength : toLength
        var lastCommonSeparator = -1
        var index = 0
        while index < length {
            let fromCode = fromResolved[fromStart + index]
            if fromCode != toResolved[toStart + index] {
                break
            } else if fromCode == slash {
                lastCommonSeparator = index
            }
            index += 1
        }

        if index == length {
            if toLength > length {
                if toResolved[toStart + index] == slash {
                    // `from` is the exact base path for `to`.
                    return String(decoding: toResolved[(toStart + index + 1)...], as: UTF8.self)
                }
                if index == 0 {
                    // `from` is the root.
                    return String(decoding: toResolved[(toStart + index)...], as: UTF8.self)
                }
            } else if fromLength > length {
                if fromResolved[fromStart + index] == slash {
                    // `to` is the exact base path for `from`.
                    lastCommonSeparator = index
                } else if index == 0 {
                    // `to` is the root.
                    lastCommonSeparator = 0
                }
            }
        }

        var out = ""
        // Generate the relative path based on the path difference between
        // `to` and `from`.
        var cursor = fromStart + lastCommonSeparator + 1
        while cursor <= fromEnd {
            if cursor == fromEnd || fromResolved[cursor] == slash {
                out += out.isEmpty ? ".." : "/.."
            }
            cursor += 1
        }

        // Lastly, append the rest of the destination (`to`) path that comes
        // after the common path parts.
        return out + String(decoding: toResolved[(toStart + lastCommonSeparator)...], as: UTF8.self)
    }

    // MARK: - Private

    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")

    /// Whether `path` is exactly `"."`.
    private static func isDot(_ path: String) -> Bool {
        path.utf8.count == 1 && path.utf8.first == dot
    }

    /// Resolves `.` and `..` elements in a path with directory names.
    private static func normalizeString(_ path: [UInt8], allowAboveRoot: Bool) -> [UInt8] {
        var result: [UInt8] = []
        var lastSegmentLength = 0
        var lastSlash = -1
        var dots = 0
        var code: UInt8 = 0

        var index = 0
        while index <= path.count {
            if index < path.count {
                code = path[index]
            } else if code == slash {
                break
            } else {
                code = slash
            }

            if code == slash {
                if lastSlash == index - 1 || dots == 1 {
                    // Nothing to do.
                } else if dots == 2 {
                    if result.count < 2
                        || lastSegmentLength != 2
                        || result[result.count - 1] != dot
                        || result[result.count - 2] != dot {
                        if result.count > 2 {
                            if let lastSlashIndex = result.lastIndex(of: slash) {
                                result.removeSubrange(lastSlashIndex...)
                                lastSegmentLength = result.count - 1 - (result.lastIndex(of: slash) ?? -1)
                            } else {
                                result = []
                                lastSegmentLength = 0
                            }
                            lastSlash = index
                            dots = 0
                            index += 1
                            continue
                        } else if !result.isEmpty {
                            result = []
                            lastSegmentLength = 0
                            lastSlash = index
                            dots = 0
                            index += 1
                            continue
                        }
                    }
                    if allowAboveRoot {
                        result.append(contentsOf: result.isEmpty ? [dot, dot] : [slash, dot, dot])
                        lastSegmentLength = 2
                    }
                } else {
                    let segment = path[(lastSlash + 1)..<index]
                    if result.isEmpty {
                        result.append(contentsOf: segment)
                    } else {
                        result.append(slash)
                        result.append(contentsOf: segment)
                    }
                    lastSegmentLength = index - lastSlash - 1
                }
                lastSlash = index
                dots = 0
            } else if code == dot, dots != -1 {
                dots += 1
            } else {
                dots = -1
            }
            index += 1
        }
        return result
    }
}
