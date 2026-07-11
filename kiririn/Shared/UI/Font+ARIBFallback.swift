import CoreText
import Foundation
import SwiftUI

#if os(iOS)
    import UIKit

    private typealias PlatformFont = UIFont
#elseif os(macOS)
    import AppKit

    private typealias PlatformFont = NSFont
#endif

extension Font {
    private static let aribFallbackDescriptor: CTFontDescriptor? = {
        guard
            let url = Bundle.main.url(
                forResource: "rounded-mplus-1m-wadalab-comp-arib",
                withExtension: "ttf"
            ),
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor]
        else {
            return nil
        }

        return descriptors.first
    }()

    static func systemWithARIBFallback(
        _ style: Font.TextStyle,
        weight: Font.Weight = .regular
    ) -> Font {
        cascadingARIBFont(from: systemFont(style: style, weight: weight))
    }

    static func systemWithARIBFallback(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        cascadingARIBFont(from: systemFont(size: size, weight: weight))
    }

    private static func cascadingARIBFont(from baseFont: CTFont) -> Font {
        guard let aribFallbackDescriptor else { return Font(baseFont) }

        let size = CTFontGetSize(baseFont)
        let fallbackDescriptor = CTFontDescriptorCreateCopyWithAttributes(
            aribFallbackDescriptor,
            [kCTFontSizeAttribute: size] as CFDictionary
        )
        let systemFallbackDescriptors =
            CTFontCopyDefaultCascadeListForLanguages(baseFont, nil) as? [CTFontDescriptor] ?? []
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(baseFont),
            [kCTFontCascadeListAttribute: [fallbackDescriptor] + systemFallbackDescriptors]
                as CFDictionary
        )
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }

    private static func systemFont(style: Font.TextStyle, weight: Font.Weight) -> CTFont {
        let preferredFont = PlatformFont.preferredFont(forTextStyle: platformTextStyle(for: style))
        return PlatformFont.systemFont(
            ofSize: preferredFont.pointSize,
            weight: platformFontWeight(for: weight)
        )
    }

    private static func systemFont(size: CGFloat, weight: Font.Weight) -> CTFont {
        PlatformFont.systemFont(ofSize: size, weight: platformFontWeight(for: weight))
    }

    private static func platformTextStyle(for style: Font.TextStyle) -> PlatformFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }

    private static func platformFontWeight(for weight: Font.Weight) -> PlatformFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
