import Logging
import SwiftUI
import UniformTypeIdentifiers

struct KiririnMediaDocument: FileDocument {
    static var readableContentTypes: [UTType] = PlayableMediaUTTypes.allowedContentTypes

    let displayName: String

    init(configuration: ReadConfiguration) throws {
        displayName = configuration.file.preferredFilename ?? "動画"
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteUnsupportedScheme)
    }
}

#if os(macOS)
    struct DocumentPlaybackView: View {
        private let logger = Logger(label: "DocumentPlaybackView")
        let fileURL: URL?
        let appModel: AppModel

        var body: some View {
            if let fileURL {
                PlayerWindowView_macOS(
                    appModel: appModel,
                    initialPlayable: Playable(
                        streamURL: fileURL, source: .fileURL(fileURL, bookmarkData: nil))
                )
                .onAppear {
                    logger.info("document playback opened with url=\(fileURL.absoluteString)")
                }
            } else {
                ContentUnavailableView(
                    "再生できません",
                    systemImage: "play.slash",
                    description: Text("ファイルURLを復元できませんでした")
                )
                .onAppear {
                    logger.error("document playback failed: fileURL is nil")
                }
            }
        }
    }
#endif
