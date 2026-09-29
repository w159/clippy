import CoreGraphics

/// Pure header-priority rules for cards and rows (LAY-03). The timestamp, kind
/// glyph and pin badge are never dropped; under width pressure the app name goes
/// first, then category dots, then the rich-text badge, then the app icon. The
/// views build one `ViewThatFits` candidate per `Variant`, and `variant(...)`
/// mirrors that decision for callers that know the widths up front.
enum CardHeaderPlan {
    /// Header element that may be dropped, listed in drop order.
    enum Element: CaseIterable, Hashable {
        case appName, categories, richBadge, appIcon
    }

    /// One `ViewThatFits` candidate: which optional elements it keeps.
    enum Variant: CaseIterable, Equatable {
        /// Everything.
        case full
        /// App name dropped.
        case noAppName
        /// Only the app icon plus the essentials.
        case essentialsWithIcon
        /// Title, kind glyph, pin and timestamp only.
        case minimal

        /// Optional elements this variant keeps.
        var kept: Set<Element> {
            switch self {
            case .full: return Set(Element.allCases)
            case .noAppName: return [.categories, .richBadge, .appIcon]
            case .essentialsWithIcon: return [.appIcon]
            case .minimal: return []
            }
        }
    }

    /// Fixed widths of the header parts, measured or estimated by the caller.
    struct Widths: Equatable {
        var timestamp: CGFloat
        var kindGlyph: CGFloat
        var pin: CGFloat
        var titleMinimum: CGFloat
        var appName: CGFloat
        var categories: CGFloat
        var richBadge: CGFloat
        var appIcon: CGFloat
        var spacing: CGFloat

        func width(of element: Element) -> CGFloat {
            switch element {
            case .appName: return appName
            case .categories: return categories
            case .richBadge: return richBadge
            case .appIcon: return appIcon
            }
        }
    }

    /// Richest variant whose required width fits in `available`; `.minimal` is
    /// the floor (the title truncates instead).
    static func variant(available: CGFloat, widths: Widths) -> Variant {
        for candidate in Variant.allCases where required(candidate, widths) <= available {
            return candidate
        }
        return .minimal
    }

    /// Width a variant needs, title minimum included.
    static func required(_ variant: Variant, _ widths: Widths) -> CGFloat {
        var parts = [widths.titleMinimum, widths.timestamp, widths.kindGlyph, widths.pin]
        parts += variant.kept.map { widths.width(of: $0) }
        return parts.reduce(0, +) + widths.spacing * CGFloat(max(0, parts.count - 1))
    }
}
