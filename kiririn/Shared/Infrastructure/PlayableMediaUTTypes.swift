import Foundation
import UniformTypeIdentifiers

enum PlayableMediaUTTypes {
    static let allowedContentTypes: [UTType] = {
        uniqued(baseContentTypes + extensionFallbackTypes + infoPlistDocumentVideoTypes)
    }()

    private static let baseContentTypes: [UTType] = [
        .video,
        .movie,
        .audiovisualContent,
        .mpeg2TransportStream,
        .mpeg4Movie,
        .quickTimeMovie,
    ]

    private static let extensionFallbackTypes: [UTType] = [
        "m2t", "m2ts", "ts", "mts", "mmts", "mkv",
    ].compactMap { UTType(filenameExtension: $0) }

    private static let infoPlistDocumentVideoTypes: [UTType] = {
        var types: [UTType] = []

        guard
            let documentTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
                as? [[String: Any]]
        else {
            return []
        }

        for documentType in documentTypes {
            guard let identifiers = documentType["LSItemContentTypes"] as? [String] else {
                continue
            }

            for identifier in identifiers {
                guard let type = UTType(identifier), type.conforms(to: .video) else {
                    continue
                }

                types.append(type)
            }
        }

        return uniqued(types)
    }()

    private static func uniqued(_ types: [UTType]) -> [UTType] {
        var identifiers = Set<String>()
        var result: [UTType] = []
        for type in types where identifiers.insert(type.identifier).inserted {
            result.append(type)
        }
        return result
    }
}
