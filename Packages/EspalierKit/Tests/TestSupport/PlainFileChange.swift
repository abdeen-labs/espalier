import GitKit

/// A plain `FileChange`: GitKit's `FileChange` is a protocol, so tests that
/// need one that's neither a working directory nor a committed change use
/// this conformer.
public struct PlainFileChange: FileChange {
    public let id: String
    public let path: String
    public let status: AppFileStatus

    public init(_ path: String, _ status: AppFileStatus) {
        // The ID: the status kind, the path, and the old path if any.
        if let oldPath = status.oldPath {
            self.id = "\(status.kind.rawValue)+\(path)+\(oldPath)"
        } else {
            self.id = "\(status.kind.rawValue)+\(path)"
        }
        self.path = path
        self.status = status
    }
}
