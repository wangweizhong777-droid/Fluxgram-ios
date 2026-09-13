import UIKit

/// Shared presentation tokens for Fluxgram screens, extracted from the home page.
public enum FluxgramDesign {
    public enum Spacing {
        public static let pageHorizontalPadding: CGFloat = 20.0
        public static let sectionSpacing: CGFloat = 16.0
        public static let cardPadding: CGFloat = 16.0
        public static let metricSpacing: CGFloat = 8.0
        public static let iconToText: CGFloat = 12.0
        public static let titleToSubtitle: CGFloat = 4.0
        public static let rowVerticalPadding: CGFloat = 16.0
        public static let separatorInset = cardPadding + Size.iconContainerSize + iconToText
    }
    public enum Size {
        public static let cardCornerRadius: CGFloat = 24.0
        public static let metricCornerRadius: CGFloat = 16.0
        public static let iconContainerSize: CGFloat = 44.0
        public static let iconSize: CGFloat = 20.0
        public static let rowHeight: CGFloat = 68.0
        public static let chevronSize: CGFloat = 12.0
        public static let iconCornerRadius: CGFloat = 16.0
        public static let statusHeaderHeight: CGFloat = 60.0
        public static let statusMetricHeight: CGFloat = 92.0
        public static let secondaryHeight: CGFloat = 42.0
    }
    public enum Font {
        public static let sectionTitle = UIFont.systemFont(ofSize: 22.0, weight: .semibold)
        public static let featureTitle = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        public static let statusValue = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        public static let secondary = UIFont.systemFont(ofSize: 14.0, weight: .regular)
        public static let metricLabel = UIFont.systemFont(ofSize: 14.0, weight: .medium)
        public static let metricStatus = UIFont.systemFont(ofSize: 14.0, weight: .medium)
    }
    public enum Surface {
        public static let page = UIColor.systemGroupedBackground
        public static let card = UIColor.systemBackground
        public static let metric = UIColor.systemGray6
        public static let surfaceBackground = page
        public static let auxiliary = UIColor.tertiarySystemFill
        public static let secondaryText = UIColor.secondaryLabel
        public static let separator = UIColor.separator.withAlphaComponent(0.35)
    }

    public static let primaryTextStyle = Font.featureTitle
    public static let secondaryTextStyle = Font.secondary

    public static func scaledFont(_ font: UIFont, category: UIContentSizeCategory) -> UIFont {
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: font, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }
}
