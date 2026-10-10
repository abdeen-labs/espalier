// Ported from desktop/app/src/models/submodule.ts

public struct SubmoduleEntry: Hashable, Sendable {
    public let sha: String
    public let path: String
    public let describe: String

    public init(sha: String, path: String, describe: String) {
        self.sha = sha
        self.path = path
        self.describe = describe
    }
}
