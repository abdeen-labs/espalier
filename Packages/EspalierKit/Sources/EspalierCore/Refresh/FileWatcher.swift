// The selected repository is watched while its window is visible.

import CoreServices

/// Reports changes to files under a set of directories.
///
/// The app uses `FSEventsFileWatcher`; tests use `ManualFileWatcher`
/// (EspalierCoreTestSupport), which emits the events a test chooses.
public protocol FileWatcher: Sendable {
    /// Starts watching `paths` (directories, recursively), delivering events
    /// in batches at most every `latency`.
    ///
    /// Events are delivered until the subscription is cancelled, or its
    /// stream's consumer stops iterating; either way the stream finishes.
    func subscribe(to paths: [String], latency: Duration) -> FileWatchSubscription

    /// The ID of the most recent file system event. Event IDs only increase,
    /// so an event with an ID at or below this one happened before the call.
    func currentEventID() -> UInt64
}

/// A running watch.
public struct FileWatchSubscription: Sendable {
    /// The events, a batch at a time, in the order they happened.
    public let events: AsyncStream<[FileWatchEvent]>

    /// Stops watching and finishes `events`. Safe to call more than once.
    public let cancel: @Sendable () -> Void

    public init(events: AsyncStream<[FileWatchEvent]>, cancel: @escaping @Sendable () -> Void) {
        self.events = events
        self.cancel = cancel
    }
}

/// One change to the file system.
public struct FileWatchEvent: Sendable, Hashable {
    /// The changed item's path, as the file system reports it. It can
    /// differ from the watched path in Unicode normalization; compare with
    /// `WatchEventClassifier`'s normalized prefixes, never pass it to git.
    public let path: String
    public let flags: Flags
    /// The event's ID: increasing in the order events happened.
    public let id: UInt64

    public init(path: String, flags: Flags, id: UInt64) {
        self.path = path
        self.flags = flags
        self.id = id
    }

    /// What happened, with FSEvents' flag values
    /// (`kFSEventStreamEventFlag…`).
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        private init(_ flag: Int) {
            rawValue = UInt32(flag)
        }

        /// Events were coalesced or dropped: everything under `path` may
        /// have changed.
        public static let mustScanSubDirs = Flags(kFSEventStreamEventFlagMustScanSubDirs)
        /// Events were dropped in this process (comes with `mustScanSubDirs`).
        public static let userDropped = Flags(kFSEventStreamEventFlagUserDropped)
        /// Events were dropped in the kernel (comes with `mustScanSubDirs`).
        public static let kernelDropped = Flags(kFSEventStreamEventFlagKernelDropped)
        /// Event IDs wrapped around.
        public static let eventIDsWrapped = Flags(kFSEventStreamEventFlagEventIdsWrapped)
        /// The end of historical events (only for watches started in the past).
        public static let historyDone = Flags(kFSEventStreamEventFlagHistoryDone)
        /// A watched directory, or one of its parents, was moved, deleted, or
        /// created.
        public static let rootChanged = Flags(kFSEventStreamEventFlagRootChanged)
        /// A volume was mounted under a watched directory.
        public static let mount = Flags(kFSEventStreamEventFlagMount)
        /// A volume was unmounted from under a watched directory.
        public static let unmount = Flags(kFSEventStreamEventFlagUnmount)

        public static let itemCreated = Flags(kFSEventStreamEventFlagItemCreated)
        public static let itemRemoved = Flags(kFSEventStreamEventFlagItemRemoved)
        public static let itemInodeMetaMod = Flags(kFSEventStreamEventFlagItemInodeMetaMod)
        public static let itemRenamed = Flags(kFSEventStreamEventFlagItemRenamed)
        public static let itemModified = Flags(kFSEventStreamEventFlagItemModified)
        public static let itemFinderInfoMod = Flags(kFSEventStreamEventFlagItemFinderInfoMod)
        public static let itemChangeOwner = Flags(kFSEventStreamEventFlagItemChangeOwner)
        public static let itemXattrMod = Flags(kFSEventStreamEventFlagItemXattrMod)
        public static let itemIsFile = Flags(kFSEventStreamEventFlagItemIsFile)
        public static let itemIsDir = Flags(kFSEventStreamEventFlagItemIsDir)
        public static let itemIsSymlink = Flags(kFSEventStreamEventFlagItemIsSymlink)
        public static let ownEvent = Flags(kFSEventStreamEventFlagOwnEvent)
        public static let itemIsHardlink = Flags(kFSEventStreamEventFlagItemIsHardlink)
        public static let itemIsLastHardlink = Flags(kFSEventStreamEventFlagItemIsLastHardlink)
        public static let itemCloned = Flags(kFSEventStreamEventFlagItemCloned)
    }
}

/// The directories watched for one repository.
///
/// For a main worktree the git directory and the common directory are the
/// same (`<path>/.git`). A linked worktree's git directory is
/// `<main>/.git/worktrees/<name>`, inside the common directory, where the
/// refs it shares with the main worktree live.
///
/// FSEvents reports real paths (symbolic links resolved, so `/private/var`
/// for `/var`), so these should be real paths too (`realpath(3)`).
public struct WatchedPaths: Sendable, Hashable {
    /// The working directory.
    public var workingDirectory: String
    /// The repository's git directory (`git rev-parse --git-dir`).
    public var gitDirectory: String
    /// The directory shared by all worktrees (`git rev-parse --git-common-dir`).
    public var commonDirectory: String

    public init(workingDirectory: String, gitDirectory: String, commonDirectory: String) {
        self.workingDirectory = workingDirectory
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
    }

    /// The directories to subscribe to: each distinct one, skipping a
    /// directory inside another (the git directory of a main worktree is
    /// inside its working directory).
    public var roots: [String] {
        var roots: [(path: String, normalized: String)] = []
        for path in [workingDirectory, gitDirectory, commonDirectory] {
            let normalized = WatchEventClassifier.normalized(path)
            if roots.contains(where: { WatchEventClassifier.relativePath(of: normalized, under: $0.normalized) != nil }) {
                continue
            }
            roots.removeAll { WatchEventClassifier.relativePath(of: $0.normalized, under: normalized) != nil }
            roots.append((path, normalized))
        }
        return roots.map(\.path)
    }
}
