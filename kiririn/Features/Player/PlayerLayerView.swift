import Logging
import SwiftUI
import VLCKit

#if os(macOS)
    import AppKit

    struct PlayerLayerView: NSViewRepresentable {
        let player: VLCMediaPlayer
        let isPipEnabled: Bool
        let isPlaying: Bool
        let onPipAvailableChanged: (Bool) -> Void
        let onPipEnabledChanged: (Bool) -> Void

        func makeNSView(context: Context) -> VLCPlayerView {
            let view = VLCPlayerView()
            view.onPipAvailableChanged = onPipAvailableChanged
            view.onPipEnabledChanged = onPipEnabledChanged
            view.bindPlayer(player)
            view.applyPipState(isEnabled: isPipEnabled)
            return view
        }

        func updateNSView(_ nsView: VLCPlayerView, context: Context) {
            nsView.onPipAvailableChanged = onPipAvailableChanged
            nsView.onPipEnabledChanged = onPipEnabledChanged
            nsView.bindPlayer(player)
            nsView.applyPipState(isEnabled: isPipEnabled)
        }
    }

    final class VLCPlayerView: NSView {
        private let videoView = GeometrySafeVLCVideoView()

        var onPipAvailableChanged: ((Bool) -> Void)?
        var onPipEnabledChanged: ((Bool) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            videoView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(videoView)
            NSLayoutConstraint.activate([
                videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
                videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
                videoView.topAnchor.constraint(equalTo: topAnchor),
                videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) {
            nil
        }

        func bindPlayer(_ player: VLCMediaPlayer) {
            if let current = player.drawable as AnyObject?, current !== videoView {
                player.drawable = videoView
            } else if player.drawable == nil {
                player.drawable = videoView
            }
            onPipAvailableChanged?(false)
            onPipEnabledChanged?(false)
        }

        func applyPipState(isEnabled _: Bool) {
            // macOS native PiP is not wired through this custom player view yet.
        }
    }

#else
    import UIKit

    struct PlayerLayerView: UIViewRepresentable {
        let player: VLCMediaPlayer
        let isPipEnabled: Bool
        let isPlaying: Bool
        let onPipAvailableChanged: (Bool) -> Void
        let onPipEnabledChanged: (Bool) -> Void

        func makeUIView(context: Context) -> VLCPlayerView {
            let view = VLCPlayerView()
            view.backgroundColor = .black
            view.onPipAvailableChanged = onPipAvailableChanged
            view.onPipEnabledChanged = onPipEnabledChanged
            view.bindPlayer(player)
            view.applyPipState(isEnabled: isPipEnabled)
            return view
        }

        func updateUIView(_ uiView: VLCPlayerView, context: Context) {
            uiView.onPipAvailableChanged = onPipAvailableChanged
            uiView.onPipEnabledChanged = onPipEnabledChanged
            uiView.bindPlayer(player)
            uiView.applyPipState(isEnabled: isPipEnabled)
            uiView.invalidatePipPlaybackState()
        }
    }

    final class VLCPlayerView: UIView, VLCPictureInPictureDrawable,
        VLCPictureInPictureMediaControlling
    {
        private weak var player: VLCMediaPlayer?
        private var pipController: (any VLCPictureInPictureWindowControlling)?
        private let logger = Logger(label: "PlayerLayerView")

        var onPipAvailableChanged: ((Bool) -> Void)?
        var onPipEnabledChanged: ((Bool) -> Void)?

        func bindPlayer(_ player: VLCMediaPlayer) {
            self.player = player
            onPipAvailableChanged?(pipController != nil)
            if pipController == nil {
                onPipEnabledChanged?(false)
            }
            if let current = player.drawable as AnyObject?, current !== self {
                player.drawable = self
            } else if player.drawable == nil {
                player.drawable = self
            }
        }

        func applyPipState(isEnabled: Bool) {
            guard let pipController else { return }
            if isEnabled {
                pipController.startPictureInPicture()
            } else {
                pipController.stopPictureInPicture()
            }
        }

        func invalidatePipPlaybackState() {
            pipController?.invalidatePlaybackState()
        }

        func mediaController() -> (any VLCPictureInPictureMediaControlling)! {
            self
        }

        func pictureInPictureReady() -> (((any VLCPictureInPictureWindowControlling)?) -> Void)! {
            { [weak self] controller in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.pipController = controller
                    self.onPipAvailableChanged?(controller != nil)
                    controller?.stateChangeEventHandler = { [weak self] isStarted in
                        DispatchQueue.main.async {
                            self?.onPipEnabledChanged?(isStarted)
                        }
                    }
                }
            }
        }

        func play() {
            player?.play()
        }

        func pause() {
            player?.pause()
        }

        func seek(by offset: Int64, completion: @escaping () -> Void) {
            jump(by: offset)
            completion()
        }

        private func jump(by offset: Int64) {
            guard let player, player.isSeekable else { return }
            let mediaLength = Double(player.media?.length.intValue ?? 0) / 1000
            guard mediaLength > 0 else { return }
            let currentPosition = player.position
            let currentTime = Double(player.time.intValue) / 1000
            let seconds = Double(offset) / 1000
            let oneSecondDelta = ((currentTime + 1) / mediaLength) - (currentTime / mediaLength)
            let requestedDelta = seconds * oneSecondDelta
            let targetPosition = currentPosition + requestedDelta
            logger.info(
                "[pip.jump] requested=\(seconds)s mediaLength=\(mediaLength)s currentPosition=\(currentPosition) currentTime=\(currentTime) oneSecondDelta=\(oneSecondDelta) requestedDelta=\(requestedDelta) targetPosition=\(targetPosition)"
            )
            guard (0...1).contains(targetPosition) else {
                logger.info("[pip.jump] targetPosition=\(targetPosition) out of range, skipping")
                return
            }
            player.position = targetPosition
        }

        func mediaLength() -> Int64 {
            Int64(player?.media?.length.intValue ?? 0)
        }

        func mediaTime() -> Int64 {
            Int64(player?.time.intValue ?? 0)
        }

        func isMediaSeekable() -> Bool {
            player?.isSeekable ?? false
        }

        func isMediaPlaying() -> Bool {
            player?.isPlaying ?? false
        }
    }
#endif
