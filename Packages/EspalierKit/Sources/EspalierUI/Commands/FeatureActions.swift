// Registers every feature's action handlers for a window. The shell
// registers first; each feature's `*Actions.register(into:context:)` follows
// and can replace the shell's stub for a kind it owns.

/// Calls every feature's registration.
@MainActor
enum FeatureActions {
    static func registerAll(into actions: WindowActions, context: WindowContext) {
        ShellActions.register(into: actions, context: context)
        Benchmarks.register(into: actions, context: context)
        DebugActions.register(into: actions, context: context)
        ChangesActions.register(into: actions, context: context)
        DiffActions.register(into: actions, context: context)
        HistoryActions.register(into: actions, context: context)
        BranchActions.register(into: actions, context: context)
        MultiCommitActions.register(into: actions, context: context)
        RepositoryActions.register(into: actions, context: context)
        GitHubActions.register(into: actions, context: context)
        StashActions.register(into: actions, context: context)
        WorktreeActions.register(into: actions, context: context)
        CommandLineToolInstaller.register(into: actions, context: context)
        CommandPaletteActions.register(into: actions, context: context)
    }
}
