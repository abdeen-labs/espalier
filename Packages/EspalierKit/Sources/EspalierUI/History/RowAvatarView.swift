// The avatar in History's AppKit rows (the graph's and the simple list's).
// It shows the person's monogram (their initials on their own color) until
// the loader has their image, draws the monogram again when the appearance
// changes, and tries again when the network comes back.

import AppKit
import GitHubKit
import QuartzCore

/// A row's avatar: the loaded image, or the person's monogram.
final class RowAvatarView: NSView {
    /// Whether a loaded image fades in over the monogram.
    var fadesIn = false

    private let imageLayer = CALayer()
    /// Who the avatar shows, at what size.
    private var identity: Identity?
    private var task: Task<Void, Never>?
    /// The loader still to be asked again when the network comes back.
    private var pendingLoader: (any AvatarLoading)?
    /// Where the monogram came from, while it shows.
    private var monograms: MonogramCache?
    private var monogramVariant: AppearanceVariant?

    private struct Identity: Equatable {
        var user: AvatarUser
        var pointSize: CGFloat
        var scale: CGFloat
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(imageLayer)
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(self, selector: #selector(networkDidReturn), name: GitHubAvatarLoader.networkDidReturn, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `user` at `pointSize` (nothing when nil): the loader's image
    /// when it has one, else the monogram while it loads.
    func show(_ user: AvatarUser?, pointSize: CGFloat, avatars: (any AvatarLoading)?, monograms: MonogramCache, scale: CGFloat) {
        let identity = user.map { Identity(user: $0, pointSize: pointSize, scale: scale) }
        guard identity != self.identity else {
            return
        }
        task?.cancel()
        task = nil
        pendingLoader = nil
        self.identity = identity
        self.monograms = nil
        guard let identity else {
            imageLayer.contents = nil
            return
        }
        if let cached = avatars?.cachedImage(for: identity.user, pointSize: pointSize, scale: scale) {
            imageLayer.contents = cached
            return
        }
        showMonogram(identity, from: monograms)
        if let avatars {
            load(identity, from: avatars)
        }
    }

    /// Stops loading (the row is reused); the next `show` starts over.
    func cancel() {
        task?.cancel()
        task = nil
        if pendingLoader != nil {
            identity = nil
            pendingLoader = nil
        }
    }

    private func showMonogram(_ identity: Identity, from monograms: MonogramCache) {
        let variant = AppearanceVariant.of(effectiveAppearance)
        self.monograms = monograms
        monogramVariant = variant
        imageLayer.contents = monograms.image(
            name: identity.user.name,
            email: identity.user.email,
            pointSize: identity.pointSize,
            scale: identity.scale,
            variant: variant
        )
    }

    private func load(_ identity: Identity, from avatars: any AvatarLoading) {
        pendingLoader = avatars
        task?.cancel()
        task = Task { [weak self] in
            let image = await avatars.image(for: identity.user, pointSize: identity.pointSize, scale: identity.scale)
            guard let self, !Task.isCancelled, self.identity == identity, let image else {
                return
            }
            self.pendingLoader = nil
            self.monograms = nil
            if self.fadesIn, Motion.animates(self) {
                Motion.crossfade(self.imageLayer, duration: Motion.leave)
            }
            self.imageLayer.contents = image
        }
    }

    /// The network came back: a monogram tries again.
    @objc private func networkDidReturn() {
        guard let identity, let loader = pendingLoader else {
            return
        }
        load(identity, from: loader)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let identity, let monograms, monogramVariant != AppearanceVariant.of(effectiveAppearance) else {
            return
        }
        showMonogram(identity, from: monograms)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        imageLayer.frame = bounds
        imageLayer.cornerRadius = min(bounds.width, bounds.height) / 2
    }
}

/// Monogram images by initials, color, size, and appearance, drawn once
/// each.
final class MonogramCache {
    private var images: [String: CGImage] = [:]

    func image(name: String, email: String, pointSize: CGFloat, scale: CGFloat, variant: AppearanceVariant) -> CGImage? {
        let hue = Monogram.hue(name: name, email: email)
        let key = "\(Monogram.initials(name: name, email: email))|\(hue)|\(pointSize)|\(scale)|\(variant.isDark)"
        if let image = images[key] {
            return image
        }
        let image = MonogramRenderer.image(name: name, email: email, pointSize: pointSize, scale: scale, variant: variant)
        if let image, images.count < 1_000 {
            images[key] = image
        }
        return image
    }
}
