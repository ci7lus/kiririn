import SwiftUI

struct RecordRowView: View {
    let record: Recorded
    let thumbnailData: Data?
    let isThumbnailFailed: Bool
    let playbackPosition: Float?
    let downloadProgress: Double?
    let onCancelDownload: (() -> Void)?
    let manager: ServerManager
    let onTap: () -> Void

    @State private var decodedThumbnail: Image?

    private var formattedDate: String? {
        record.displayDate.map { $0.formatted(.displayDateTimeFull) }
    }

    private var formattedDuration: String? {
        guard let duration = record.duration, duration > 0 else { return nil }
        return "\(Int(duration / 60))分"
    }

    private var isLocalSaveInProgress: Bool {
        downloadProgress != nil
    }

    @ViewBuilder
    private var playbackProgressBar: some View {
        if let position = playbackPosition, position > 0.02, position < 0.98 {
            GeometryReader { geo in
                Rectangle()
                    .fill(.tint.opacity(0.8))
                    .frame(width: geo.size.width * CGFloat(position), height: 3)
            }
            .frame(height: 3)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack(alignment: .bottom) {
            if let decodedThumbnail {
                Color.kiririnSecondarySystemBackground
                    .overlay {
                        decodedThumbnail
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
            } else if record.hasThumbnail && !isThumbnailFailed {
                Color.kiririnSecondarySystemBackground
                    .overlay {
                        ProgressView().controlSize(.small)
                    }
            } else {
                Color.kiririnTertiarySystemFill
                    .overlay {
                        Image(systemName: "film")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
            }
            playbackProgressBar
        }
        .frame(width: 100, height: 56)
        .clipShape(.rect(cornerRadius: 8))
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                thumbnailView

                VStack(alignment: .leading, spacing: 4) {
                    BroadcastText(record.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    if let channelName = record.serviceName?.trimmingCharacters(
                        in: .whitespacesAndNewlines),
                        !channelName.isEmpty
                    {
                        BroadcastText(channelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if formattedDate != nil || formattedDuration != nil {
                        HStack(spacing: 4) {
                            if let date = formattedDate {
                                Text(date)
                            }
                            if let dur = formattedDuration {
                                Text("·")
                                Text(dur)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if record.isRecording {
                        HStack(spacing: 4) {
                            Circle().fill(.red).frame(width: 6, height: 6)
                            Text("録画中")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    if let progress = downloadProgress {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.tint)
                            Text("ダウンロード中")
                            Text("(\(Int(progress * 100))%)")
                                .monospacedDigit()
                            if let onCancelDownload {
                                Button(role: .destructive, action: onCancelDownload) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("ダウンロードをキャンセル")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task(id: thumbnailData) {
            guard let data = thumbnailData else {
                decodedThumbnail = nil
                return
            }
            decodedThumbnail = await decodeRecordingsImage(from: data)
        }
        .contextMenu {
            if isLocalSaveInProgress, let onCancelDownload {
                Button(role: .destructive, action: onCancelDownload) {
                    Label {
                        Text("ダウンロードをキャンセル")
                    } icon: {
                        accentMenuIcon(systemName: "xmark.circle")
                    }
                }
            } else {
                Button {
                    RecordDownloadManager.shared.downloadRecord(record, manager: manager)
                } label: {
                    Label {
                        Text("ダウンロード")
                    } icon: {
                        accentMenuIcon(systemName: "arrow.down.circle")
                    }
                }
            }
        }
    }
}

struct RecordDownloadRowView: View {
    let item: LocalRecordItem
    let record: Recorded
    let playbackPosition: Float?
    let downloadProgress: Double?
    let isDeleting: Bool
    let manager: ServerManager
    let onTap: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    private var isActiveDownload: Bool { downloadProgress != nil }

    var body: some View {
        Group {
            if isActiveDownload {
                downloadingRow
                    .contextMenu {
                        Button(role: .destructive, action: onCancel) {
                            Label {
                                Text("キャンセル")
                            } icon: {
                                accentMenuIcon(systemName: "xmark.circle")
                            }
                        }
                    }
            } else if item.downloadState == .downloaded {
                RecordRowView(
                    record: record,
                    thumbnailData: item.thumbnailData,
                    isThumbnailFailed: false,
                    playbackPosition: playbackPosition,
                    downloadProgress: nil,
                    onCancelDownload: nil,
                    manager: manager,
                    onTap: onTap
                )
                .contextMenu { contextMenuItems }
            } else if item.downloadState == .failed || item.downloadState == .downloading {
                failedRow
                    .contextMenu { contextMenuItems }
            } else {
                RecordRowView(
                    record: record,
                    thumbnailData: item.thumbnailData,
                    isThumbnailFailed: false,
                    playbackPosition: nil,
                    downloadProgress: nil,
                    onCancelDownload: nil,
                    manager: manager,
                    onTap: onTap
                )
                .contextMenu { contextMenuItems }
            }
        }
        .opacity(isDeleting ? 0.45 : 1)
        .allowsHitTesting(!isDeleting)
        .overlay(alignment: .trailing) {
            if isDeleting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("削除中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(.trailing, 8)
            }
        }
    }

    @ViewBuilder
    private var downloadingRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.kiririnSecondarySystemBackground
                if let progress = downloadProgress {
                    VStack(spacing: 6) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 72)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 100, height: 56)
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                BroadcastText(record.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                if let channelName = record.serviceName?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                    !channelName.isEmpty
                {
                    BroadcastText(channelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("ダウンロード中")
                    if let progress = downloadProgress {
                        Text("(\(Int(progress * 100))%)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var failedRow: some View {
        HStack(spacing: 12) {
            Color.kiririnTertiarySystemFill
                .frame(width: 100, height: 56)
                .overlay {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.red.opacity(0.7))
                }
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                BroadcastText(record.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(item.downloadState == .downloading ? "ダウンロード中断" : "ダウンロード失敗")
                }
                .font(.caption)
                .foregroundStyle(.red)

                if let msg = item.downloadErrorMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        localRecordRevealContextMenuItem(for: item)

        Button(role: .destructive, action: onDelete) {
            Label {
                Text("削除")
            } icon: {
                accentMenuIcon(systemName: "trash")
            }
        }
    }
}
