// The avatar view. A monogram first, then the loaded image cross-fades in
// (0.15 s; at once with Reduce Motion). A monogram tries again when the
// network comes back.

import GitHubKit
import SwiftUI

/// An avatar in the theme's shape (a circle in Classic): the environment's
/// loader's image, or a monogram.
public struct Avatar: View {
    private let identity: AvatarUser
    private let size: CGFloat
    @Environment(\.avatarLoader) private var loader
    @Environment(\.displayScale) private var scale
    @Environment(\.motion) private var motion
    @State private var image: CGImage?
    /// How many times the network came back while this showed a monogram.
    @State private var retries = 0

    /// - Parameters:
    ///   - identity: Who the avatar shows.
    ///   - size: The diameter in points (16 in rows).
    public init(_ identity: AvatarUser, size: CGFloat = Metrics.CommitRow.avatarSize) {
        self.identity = identity
        self.size = size
    }

    public var body: some View {
        ZStack {
            MonogramView(name: identity.name, email: identity.email, size: size)
            if let image {
                Image(decorative: image, scale: scale)
                    .resizable()
                    .interpolation(.high)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(AvatarClipShape())
        .accessibilityHidden(true)
        .task(id: TaskKey(identity: identity, size: size, scale: scale, retries: retries)) {
            if let cached = loader.cachedImage(for: identity, pointSize: size, scale: scale) {
                image = cached
                return
            }
            image = nil
            let loaded = await loader.image(for: identity, pointSize: size, scale: scale)
            guard !Task.isCancelled else {
                return
            }
            withMotion(motion, Motion.leave) {
                image = loaded
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GitHubAvatarLoader.networkDidReturn)) { _ in
            if image == nil {
                retries += 1
            }
        }
    }

    private struct TaskKey: Hashable {
        let identity: AvatarUser
        let size: CGFloat
        let scale: CGFloat
        let retries: Int
    }
}
