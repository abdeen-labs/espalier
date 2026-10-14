// How a file row shares its room among the name, a rename's source, and the
// folder: whole while they fit, the last cut first, a label cut below its
// shortest truncation left out with its gap, and the name cut last.

import CoreGraphics
import Testing
import TestSupport
@testable import EspalierUI

@Suite("File label widths")
struct FileLabelWidthsTests {
    /// Labels' whole widths and floors, the room they share with 8 points
    /// between them, and the widths they get.
    struct Labels: Sendable {
        var natural: [CGFloat]
        var floors: [CGFloat]
        var room: CGFloat
        var widths: [CGFloat]
    }

    @Test("the room shared among the labels, the last giving way first", arguments: [
        NamedCase("name and folder whole when they fit", Labels(natural: [100, 60], floors: [20, 25], room: 200, widths: [100, 60])),
        NamedCase("the folder cut to the room the name leaves", Labels(natural: [100, 80], floors: [20, 25], room: 150, widths: [100, 42])),
        NamedCase("the folder cut to its floor", Labels(natural: [100, 80], floors: [20, 25], room: 133, widths: [100, 25])),
        NamedCase("the folder gone, with its gap, below its floor", Labels(natural: [100, 80], floors: [20, 25], room: 132, widths: [100, 0])),
        NamedCase("the name cut once the folder is gone", Labels(natural: [160, 80], floors: [20, 25], room: 130, widths: [130, 0])),
        NamedCase("a folder narrower than its floor, whole or gone", Labels(natural: [100, 12], floors: [20, 25], room: 119, widths: [100, 0])),
        NamedCase("the source whole when the folder goes", Labels(natural: [100, 50, 80], floors: [20, 25, 25], room: 170, widths: [100, 50, 0])),
        NamedCase("the source cut after the folder", Labels(natural: [100, 50, 80], floors: [20, 25, 25], room: 144, widths: [100, 36, 0])),
        NamedCase("only the name below both floors", Labels(natural: [100, 50, 80], floors: [20, 25, 25], room: 120, widths: [100, 0, 0])),
        NamedCase("no room", Labels(natural: [100, 80], floors: [20, 25], room: 0, widths: [0, 0])),
    ])
    func widths(_ testCase: NamedCase<Labels>) {
        let labels = testCase.value
        #expect(FileLabelWidths.widths(natural: labels.natural, floors: labels.floors, room: labels.room, gap: 8) == labels.widths)
    }
}
