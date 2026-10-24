// The Changes list's header: every file included, some, and none; the
// filter hiding some; no changes, its checkbox disabled; and columns too
// narrow for the title, which gives way at its end.

import AppKit
@testable import EspalierCore
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Changes header", .captures) @MainActor
struct ChangesHeaderCaptures {
    private let area = "Changes"

    @Test("every file included, some, and none; filtered; no changes; narrow columns")
    func header() {
        func content(_ fileCount: Int, shown: Int? = nil, included: Int, includeAll: Bool?) -> ChangesHeaderContent {
            ChangesHeaderContent(
                title: ChangesHeaderContent.title(fileCount: fileCount, visibleCount: shown ?? fileCount, numberFormat: defaultNumberFormat),
                included: fileCount == 0 ? "" : ChangesHeaderContent.included(count: included, numberFormat: defaultNumberFormat),
                includeAll: includeAll,
                isIncludeAllEnabled: fileCount > 0,
                filter: FilterMenuContent(),
                fileCount: fileCount
            )
        }
        let width = Metrics.Column.changesFileList.ideal
        let headers: [(content: ChangesHeaderContent, width: CGFloat)] = [
            (content(7, included: 7, includeAll: true), width),
            (content(7, included: 3, includeAll: nil), width),
            (content(1, included: 0, includeAll: false), width),
            (content(1_204, shown: 12, included: 1_204, includeAll: true), width),
            (content(0, included: 0, includeAll: false), width),
            (content(1_204, shown: 12, included: 1_204, includeAll: true), 200),
            (content(1_204, shown: 12, included: 1_204, includeAll: true), 130),
        ]
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                ChangesHeader(header.content)
                    .frame(width: header.width)
                Hairline()
            }
        }
        .frame(width: width, alignment: .leading)
        .background(Color(espalier: Palette.background))
        capture(view, named: "header", area: area)
    }
}
