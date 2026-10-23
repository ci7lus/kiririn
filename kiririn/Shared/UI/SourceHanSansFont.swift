import CoreText
import Foundation
import SwiftUI

#if os(iOS)
    import UIKit
    private typealias SourceHanPlatformFont = UIFont
#elseif os(macOS)
    import AppKit
    private typealias SourceHanPlatformFont = NSFont
#endif

@MainActor
final class SourceHanSansFont {
    static let shared: SourceHanSansFont? = {
        guard let url = Bundle.main.url(forResource: "SourceHanSans-VF", withExtension: "ttf")
        else { return nil }
        return SourceHanSansFont(url: url)
    }()

    private struct Key: Hashable {
        let size: CGFloat
        let weight: CGFloat
    }

    private let descriptor: CTFontDescriptor
    private var fonts: [Key: CTFont] = [:]
    private var cascadingFonts: [SourceHanPlatformFont: CTFont] = [:]

    init?(url: URL) {
        guard
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor], let descriptor = descriptors.first
        else { return nil }
        self.descriptor = descriptor
    }

    static func baseSize(style: Font.TextStyle) -> CGFloat {
        let textStyle = platformTextStyle(style)
        #if os(iOS)
            let size = UIFont.preferredFont(
                forTextStyle: textStyle,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
            ).pointSize
        #else
            let size = NSFont.preferredFont(forTextStyle: textStyle).pointSize
        #endif
        return size
    }

    static func systemFont(size: CGFloat, weight: Font.Weight) -> CTFont {
        SourceHanPlatformFont.systemFont(ofSize: size, weight: platformWeight(weight))
    }

    func cascadingFont(from baseFont: CTFont) -> CTFont {
        let key = baseFont as SourceHanPlatformFont
        if let font = cascadingFonts[key] { return font }
        let systemFallbacks =
            CTFontCopyDefaultCascadeListForLanguages(baseFont, nil) as? [CTFontDescriptor] ?? []
        let cascade =
            systemFallbacks.filter { descriptor in
                let name =
                    CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? ""
                let family =
                    CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
                    ?? ""
                return !name.lowercased().contains("lastresort")
                    && !family.lowercased().contains("lastresort")
                    && !name.hasPrefix("SourceHanSansVF-") && family != "Source Han Sans VF"
            } + [CTFontCopyFontDescriptor(font(matching: baseFont))]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(baseFont),
            [kCTFontCascadeListAttribute: cascade] as CFDictionary
        )
        let font = CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(baseFont), nil)
        if cascadingFonts.count >= 64 { cascadingFonts.removeAll(keepingCapacity: true) }
        cascadingFonts[key] = font
        return font
    }

    func styled(_ value: NSAttributedString, defaultFont: CTFont) -> NSAttributedString {
        let styled = NSMutableAttributedString(attributedString: value)
        value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) {
            attribute, range, _ in
            let nativeFont =
                (attribute as? SourceHanPlatformFont).map { $0 as CTFont } ?? defaultFont
            styled.addAttribute(.font, value: cascadingFont(from: nativeFont), range: range)
        }
        return styled
    }

    private func font(matching nativeFont: CTFont) -> CTFont {
        let traits = CTFontCopyTraits(nativeFont) as NSDictionary
        let nativeWeight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        let anchors: [(CGFloat, CGFloat)] = [
            (SourceHanPlatformFont.Weight.ultraLight.rawValue, 250),
            (SourceHanPlatformFont.Weight.thin.rawValue, 250),
            (SourceHanPlatformFont.Weight.light.rawValue, 300),
            (SourceHanPlatformFont.Weight.regular.rawValue, 400),
            (SourceHanPlatformFont.Weight.medium.rawValue, 500),
            (SourceHanPlatformFont.Weight.semibold.rawValue, 600),
            (SourceHanPlatformFont.Weight.bold.rawValue, 700),
            (SourceHanPlatformFont.Weight.heavy.rawValue, 800),
            (SourceHanPlatformFont.Weight.black.rawValue, 900),
        ]
        var weight: CGFloat = 250
        for (lower, upper) in zip(anchors, anchors.dropFirst()) {
            guard nativeWeight > lower.0 else { break }
            let fraction = min((nativeWeight - lower.0) / (upper.0 - lower.0), 1)
            weight = lower.1 + (upper.1 - lower.1) * fraction
        }
        let key = Key(size: CTFontGetSize(nativeFont), weight: weight)
        if let font = fonts[key] { return font }
        let weighted = CTFontDescriptorCreateCopyWithAttributes(
            descriptor,
            [kCTFontVariationAttribute: [NSNumber(value: 0x7767_6874): weight]] as CFDictionary
        )
        let font = CTFontCreateWithFontDescriptor(weighted, key.size, nil)
        if fonts.count >= 64 { fonts.removeAll(keepingCapacity: true) }
        fonts[key] = font
        return font
    }

    private static func platformTextStyle(_ style: Font.TextStyle)
        -> SourceHanPlatformFont.TextStyle
    {
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

    private static func platformWeight(_ weight: Font.Weight) -> SourceHanPlatformFont.Weight {
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

private struct BroadcastFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(style: Font.TextStyle, weight: Font.Weight) {
        _size = ScaledMetric(
            wrappedValue: SourceHanSansFont.baseSize(style: style), relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        let systemFont = SourceHanSansFont.systemFont(size: size, weight: weight)
        let font = SourceHanSansFont.shared?.cascadingFont(from: systemFont) ?? systemFont
        content.font(Font(font))
    }
}

extension View {
    @MainActor func broadcastFont(
        _ style: Font.TextStyle = .body,
        weight: Font.Weight = .regular
    ) -> some View {
        modifier(BroadcastFontModifier(style: style, weight: weight))
    }
}
