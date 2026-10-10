// An image cache for the image loaders' tests.

import Foundation
import Synchronization
@testable import EspalierUI

/// Keeps every image until it's removed. The app's `NSCache` may let any
/// image go when memory runs low, so tests that check what's cached, or that
/// a loaded image isn't requested again, use this one.
final class RetainingImageCache: ImageCache {
    private let images = Mutex<[URL: CGImageBox]>([:])

    func object(forKey url: URL) -> CGImageBox? {
        images.withLock { $0[url] }
    }

    func setObject(_ box: CGImageBox, forKey url: URL) {
        images.withLock { $0[url] = box }
    }

    func removeAllObjects() {
        images.withLock { $0.removeAll() }
    }
}
