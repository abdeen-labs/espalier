// The date and time patterns a setting stores: ones that aren't desktop's
// read as the defaults.

import Testing
@testable import EspalierUI

@Suite("Date and time patterns")
struct RelativeTimeTests {
    @Test("stored patterns that aren't desktop's read as the defaults")
    func storedPatterns() {
        let formatting = DateTimeFormatting(preferAbsoluteDates: true, dateFormat: "yyyy", timeFormat: nil)
        #expect(formatting.dateFormat == .monthDayYear)
        #expect(formatting.timeFormat == TimeFormatPattern.default)
        #expect(DateTimeFormatting(preferAbsoluteDates: false, dateFormat: "dd.MM.yy", timeFormat: "HH:mm").dateFormat == .dotDayMonthShortYear)
    }
}
