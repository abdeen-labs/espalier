// Refreshing every repository's status, now.

extension AppModel {
    /// Refreshes every repository's status now: the selected repository's,
    /// then every other repository's indicator in a pass of the indicator
    /// updater's own (after the one in progress, if any; the updater's
    /// schedule stays). Returns once they're all done.
    public func refreshRepositoryStatuses() async {
        guard loadState == .ready else {
            return
        }
        if let selected = selectedRepository, !selected.record.isMissing {
            await selected.refresh(.status, reason: .user)
        }
        await background.indicators.refreshNow()
    }
}
