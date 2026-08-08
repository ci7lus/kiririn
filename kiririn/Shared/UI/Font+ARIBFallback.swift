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
    private struct ARIBFontCacheKey: Hashable {
        let size: CGFloat
        let weight: CGFloat
    }

    @MainActor private static var aribFontCache: [ARIBFontCacheKey: Font] = [:]
    private static let aribFontCacheLimit = 64

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
        let preferredFont = PlatformFont.preferredFont(forTextStyle: platformTextStyle(for: style))
        return cachedARIBFont(size: preferredFont.pointSize, weight: weight)
    }

    static func systemWithARIBFallback(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        cachedARIBFont(size: size, weight: weight)
    }

    private static func cachedARIBFont(size: CGFloat, weight: Font.Weight) -> Font {
        let platformWeight = platformFontWeight(for: weight)
        let key = ARIBFontCacheKey(size: size, weight: platformWeight.rawValue)
        if let cachedFont = aribFontCache[key] {
            return cachedFont
        }

        let font = cascadingARIBFont(
            from: PlatformFont.systemFont(ofSize: size, weight: platformWeight)
        )
        if aribFontCache.count >= aribFontCacheLimit {
            aribFontCache.removeAll(keepingCapacity: true)
        }
        aribFontCache[key] = font
        return font
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
