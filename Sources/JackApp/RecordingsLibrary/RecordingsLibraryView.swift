import AppKit
import SwiftUI

// MARK: - ConvexRecordingItem

struct ConvexRecordingItem: Identifiable {
    let id: String
    let title: String
    let duration: TimeInterval
    let createdAt: Date
    let storageId: String
    let shareToken: String?
    let spaceId: String?
    let thumbnailUrl: String?
    let videoUrl: String?

    var formattedDuration: String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    var shareUrl: String? {
        guard let shareToken else { return nil }
        return AppConfig.convexSiteUrl + "/share/" + shareToken
    }
}

// MARK: - SortOrder

enum SortOrder: String, CaseIterable, Identifiable {
    case dateDesc = "Newest"
    case dateAsc = "Oldest"
    case nameAsc = "Name"

    var id: String { rawValue }
}

// MARK: - RecordingsLibraryView

struct RecordingsLibraryView: View {
    var spaceController: SpaceController?
    var onStartRecording: (() -> Void)?
    var isLoadingSetup: Bool = false
    var showStartButton: Bool = true

    @State private var recordings: [ConvexRecordingItem] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .dateDesc
    @State private var errorMessage: String?
    @State private var linkCopiedId: String?
    @State private var enablingShareIds: Set<String> = []
    @State private var hoveredCardId: String?

    private var filteredRecordings: [ConvexRecordingItem] {
        var items = recordings

        if !searchText.isEmpty {
            items = items.filter { recording in
                recording.title.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOrder {
        case .dateDesc:
            items.sort { $0.createdAt > $1.createdAt }
        case .dateAsc:
            items.sort { $0.createdAt < $1.createdAt }
        case .nameAsc:
            items.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }

        return items
    }

    private var pendingUploads: [UploadQueue.PendingUpload] {
        UploadQueue.shared.pending
    }

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 20)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("My Library")
                        .font(.title2.weight(.bold))
                    Text("\(recordings.count) recording\(recordings.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showStartButton, let onStart = onStartRecording {
                    Button {
                        onStart()
                    } label: {
                        HStack(spacing: 6) {
                            if isLoadingSetup {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "record.circle")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text("New Recording")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isLoadingSetup)
                }
            }
            .padding(.bottom, 16)

            // Search + Sort row
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    TextField("Search recordings...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                )

                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(.bottom, 16)

            // Content
            if isLoading {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Loading recordings...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if filteredRecordings.isEmpty && pendingUploads.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(pendingUploads) { upload in
                        pendingUploadCard(upload)
                    }

                    ForEach(filteredRecordings) { recording in
                        recordingCard(recording)
                    }
                }
            }

            if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            }
        }
        .task(id: spaceController?.activeSpace.id) {
            await loadRecordings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingExported)) { _ in
            Task { await loadRecordings() }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.quaternary.opacity(0.5))
                    .frame(width: 64, height: 64)
                Image(systemName: "video.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                if searchText.isEmpty {
                    Text("No recordings yet")
                        .font(.headline)
                    Text("Click \"New Recording\" to capture your first video.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No results")
                        .font(.headline)
                    Text("No recordings match \"\(searchText)\".")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Pending Upload Card

    private func pendingUploadCard(_ upload: UploadQueue.PendingUpload) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail area
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .aspectRatio(16 / 9, contentMode: .fit)

                VStack(spacing: 8) {
                    switch upload.status {
                    case .exporting:
                        ProgressView(value: upload.exportProgress, total: 1.0)
                            .progressViewStyle(.circular)
                            .controlSize(.regular)
                        Text("Exporting \(Int(upload.exportProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .uploading:
                        ProgressView()
                            .controlSize(.regular)
                        Text("Uploading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .queued:
                        ProgressView()
                            .controlSize(.regular)
                        Text("Queued...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text("Upload failed")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        if let error = upload.lastError {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                        Button("Retry") {
                            UploadQueue.shared.retryFailed()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                }
            }

            // Info area
            VStack(alignment: .leading, spacing: 6) {
                Text(upload.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    let totalSeconds = Int(upload.duration)
                    let minutes = totalSeconds / 60
                    let seconds = totalSeconds % 60
                    Text(String(format: "%d:%02d", minutes, seconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Recording Card

    private func recordingCard(_ recording: ConvexRecordingItem) -> some View {
        let isHovered = hoveredCardId == recording.id

        return VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            Button {
                if let shareUrl = recording.shareUrl, let url = URL(string: shareUrl) {
                    NSWorkspace.shared.open(url)
                } else if let videoUrl = recording.videoUrl, let url = URL(string: videoUrl) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .aspectRatio(16 / 9, contentMode: .fit)

                    if let thumbnailUrl = recording.thumbnailUrl,
                       let url = URL(string: thumbnailUrl)
                    {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                Color.clear
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    // Hover overlay
                    if isHovered {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.black.opacity(0.3))

                        Image(systemName: "play.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 6)
                    }

                    // Duration badge — bottom left
                    VStack {
                        Spacer()
                        HStack {
                            Text(recording.formattedDuration)
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(.black.opacity(0.7))
                                )
                            Spacer()
                        }
                        .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(isHovered ? 0.15 : 0.06), lineWidth: 1)
                )
                .shadow(
                    color: .black.opacity(isHovered ? 0.15 : 0.05),
                    radius: isHovered ? 12 : 4,
                    y: isHovered ? 4 : 2
                )
            }
            .buttonStyle(.plain)

            // Info area
            VStack(alignment: .leading, spacing: 6) {
                Text(recording.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(recording.formattedDate)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer()

                    // Share actions
                    if let shareUrl = recording.shareUrl {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(shareUrl, forType: .string)
                            linkCopiedId = recording.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                if linkCopiedId == recording.id { linkCopiedId = nil }
                            }
                        } label: {
                            Image(
                                systemName: linkCopiedId == recording.id
                                    ? "checkmark" : "link"
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(
                                linkCopiedId == recording.id ? .green : .secondary
                            )
                        }
                        .buttonStyle(.plain)
                        .help(
                            linkCopiedId == recording.id
                                ? "Copied!" : "Copy share link"
                        )

                        Button {
                            NSWorkspace.shared.open(URL(string: shareUrl)!)
                        } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open in browser")
                    } else if enablingShareIds.contains(recording.id) {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Button {
                            Task { await enableSharing(for: recording) }
                        } label: {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Get share link")
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredCardId = hovering ? recording.id : nil
            }
        }
        .contextMenu {
            if let shareUrl = recording.shareUrl {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shareUrl, forType: .string)
                } label: {
                    Label("Copy Share Link", systemImage: "link")
                }

                Button {
                    NSWorkspace.shared.open(URL(string: shareUrl)!)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
            } else {
                Button {
                    Task { await enableSharing(for: recording) }
                } label: {
                    Label("Get Share Link", systemImage: "link.badge.plus")
                }
            }

            if let videoUrl = recording.videoUrl, let url = URL(string: videoUrl) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Play Video", systemImage: "play.fill")
                }
            }

            if let sc = spaceController, sc.availableSpaces.count > 1 {
                Divider()

                Menu("Move to...") {
                    ForEach(sc.availableSpaces) { space in
                        let currentSpaceId = sc.currentSpaceId
                        let targetSpaceId = space.isPersonal ? nil : space.id
                        if targetSpaceId != currentSpaceId {
                            Button(space.name) {
                                Task {
                                    await moveRecording(
                                        recordingId: recording.id,
                                        toSpaceId: targetSpaceId
                                    )
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                Task { await deleteRecording(recording) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Data Loading

    private func loadRecordings() async {
        isLoading = true
        errorMessage = nil

        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = [:]
            if let spaceId = spaceController?.currentSpaceId {
                args["spaceId"] = spaceId
            }

            let result = try await ConvexHTTPClient.query(
                function: "recordings:list",
                args: args,
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                recordings = []
                isLoading = false
                return
            }

            recordings = items.compactMap { item in
                guard let id = item["_id"] as? String,
                      let title = item["title"] as? String,
                      let duration = item["duration"] as? Double,
                      let creationTime = item["_creationTime"] as? Double
                else { return nil }

                return ConvexRecordingItem(
                    id: id,
                    title: title,
                    duration: duration,
                    createdAt: Date(timeIntervalSince1970: creationTime / 1000),
                    storageId: item["storageId"] as? String ?? "",
                    shareToken: item["shareToken"] as? String,
                    spaceId: item["spaceId"] as? String,
                    thumbnailUrl: item["thumbnailUrl"] as? String,
                    videoUrl: item["videoUrl"] as? String
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            NSLog("[RecordingsLibrary] Failed to fetch: %@", String(describing: error))
        }

        isLoading = false
    }

    // MARK: - Actions

    private func moveRecording(recordingId: String, toSpaceId: String?) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            var args: [String: Any] = ["recordingId": recordingId]
            if let toSpaceId {
                args["targetSpaceId"] = toSpaceId
            }
            _ = try await ConvexHTTPClient.mutation(
                function: "recordings:moveToSpace",
                args: args,
                token: token
            )
            await loadRecordings()
        } catch {
            NSLog("[RecordingsLibrary] Move failed: %@", String(describing: error))
            errorMessage = error.localizedDescription
        }
    }

    private func enableSharing(for recording: ConvexRecordingItem) async {
        enablingShareIds.insert(recording.id)
        do {
            let token = try await ConvexHTTPClient.getToken()
            let result = try await ConvexHTTPClient.mutation(
                function: "recordings:enableSharing",
                args: ["recordingId": recording.id],
                token: token
            )
            if let shareToken = result as? String {
                let shareUrl = AppConfig.convexSiteUrl + "/share/" + shareToken
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(shareUrl, forType: .string)
                linkCopiedId = recording.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if linkCopiedId == recording.id { linkCopiedId = nil }
                }
            }
            await loadRecordings()
        } catch {
            NSLog("[RecordingsLibrary] Enable sharing failed: %@", String(describing: error))
            errorMessage = error.localizedDescription
        }
        enablingShareIds.remove(recording.id)
    }

    private func deleteRecording(_ recording: ConvexRecordingItem) async {
        do {
            let token = try await ConvexHTTPClient.getToken()
            _ = try await ConvexHTTPClient.mutation(
                function: "recordings:remove",
                args: ["recordingId": recording.id],
                token: token
            )
            recordings.removeAll { $0.id == recording.id }
        } catch {
            NSLog("[RecordingsLibrary] Delete failed: %@", String(describing: error))
            errorMessage = error.localizedDescription
        }
    }
}
