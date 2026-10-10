// Layout constants for the sheets, popovers, and panels outside Changes,
// the diff, and History, beside `Metrics`' own.

import AppKit
import SwiftUI

extension Typography {
    /// The device code to enter when signing in (SF Mono, 22, semibold).
    public static let deviceCode: Font = .system(.title, design: .monospaced).weight(.semibold)
    /// The welcome flow's paragraphs (15).
    public static let welcomeBody: Font = .title3
}

extension Metrics.Welcome {
    /// Between the welcome flow's parts (the icon, the heading, the form,
    /// the buttons).
    public static let sectionSpacing: CGFloat = 24
}

extension Metrics {
    /// The branch popover and the pickers inside sheets.
    public enum BranchPicker {
        /// The popover's width.
        public static let popoverWidth: CGFloat = 380
        /// The popover's list height.
        public static let popoverListHeight: CGFloat = 340
        /// A picker's list height inside a sheet.
        public static let sheetListHeight: CGFloat = 300
    }

    /// Get Started, the window with no repositories.
    public enum GetStarted {
        /// The account's repositories.
        public static let listWidth: CGFloat = 400
    }

    /// Signing in.
    public enum SignIn {
        /// Between the device code's characters.
        public static let codeKerning: CGFloat = 4
    }

    /// A symbol in a soft circle heading a centered state (cloning, push
    /// protection), and a sheet's call to action.
    public enum StateIcon {
        public static let size: CGFloat = 44
        /// A call to action's (signing in, publishing).
        public static let callToActionSize: CGFloat = 36
    }

    /// Small popovers (a failure's details, the checks, a gate).
    public enum Popover {
        public static let width: CGFloat = 320
        /// Around a popover's content.
        public static let padding: CGFloat = 16
    }

    /// The repository popover: as tall as its rows, up to the window's
    /// height.
    public enum RepositoryPopover {
        public static let width: CGFloat = 360
    }

    /// A list inside a sheet (repositories to clone, a branch picker's
    /// list): the `field` fill in a card's shape.
    public enum SheetList {
        public static let inset: CGFloat = 6
    }
}
