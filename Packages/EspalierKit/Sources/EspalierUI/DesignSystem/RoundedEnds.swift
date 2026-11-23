// A rectangle whose two ends round separately: what AppKit rows draw when
// a shape runs across several rows (a run of selected commits, a block of
// added lines, an included run's gutter pill) and only its first and last
// row round their outer corners.

import AppKit

extension NSBezierPath {
    /// `rect` with the corners at its minimum y rounded by `minYRadius` and
    /// those at its maximum y by `maxYRadius` (each at most half the
    /// rectangle's smaller side).
    static func roundedEnds(_ rect: CGRect, minYRadius: CGFloat, maxYRadius: CGFloat) -> NSBezierPath {
        let limit = max(min(rect.width, rect.height) / 2, 0)
        let minYRadius = min(max(minYRadius, 0), limit)
        let maxYRadius = min(max(maxYRadius, 0), limit)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + minYRadius, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - minYRadius, y: rect.minY))
        if minYRadius > 0 {
            path.appendArc(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY + minYRadius), radius: minYRadius)
        }
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - maxYRadius))
        if maxYRadius > 0 {
            path.appendArc(from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.maxX - maxYRadius, y: rect.maxY), radius: maxYRadius)
        }
        path.line(to: CGPoint(x: rect.minX + maxYRadius, y: rect.maxY))
        if maxYRadius > 0 {
            path.appendArc(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY - maxYRadius), radius: maxYRadius)
        }
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + minYRadius))
        if minYRadius > 0 {
            path.appendArc(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.minX + minYRadius, y: rect.minY), radius: minYRadius)
        }
        path.close()
        return path
    }
}
