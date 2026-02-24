import AppKit
import Combine
@preconcurrency import ConvexMobile
import SwiftUI

// MARK: - RecordingItem

struct RecordingItem: Identifiable, Decodable {
    let _id: String
    let title: String?
    let duration: Double
    let _creationTime: Double?
    let organizationId: String?
    let shareToken: String?
    let shareEnabled: Bool?

    var id: String { _id }

    var displayTitle: String {
        title ?? "Untitled Recording"
    }

    var formattedDuration: String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var creationDate: Date? {
        guard let ts = _creationTime else { return nil }
        return Date(timeIntervalSince1970: ts / 1000)
    }

    var formattedDate: String {
        guard let date = creationDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
    let spaceController: SpaceController
    let authController: AuthController

    @State private var recordings: [RecordingItem] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .dateDesc
    @State private var errorMessage: String?
    @State private var subscription: AnyCancellable?

    private var filteredRecordings: [RecordingItem] {
        var items = recordings

        // Apply search filter
        if !searchText.isEmpty {
            items = items.filter { recording in
                recording.displayTitle.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Apply sort
        switch sortOrder {
        case .dateDesc:
            items.sort { ($0._creationTime ?? 0) > ($1._creationTime ?? 0) }
        case .dateAsc:
            items.sort { ($0._creationTime ?? 0) < ($1._creationTime ?? 0) }
        case .nameAsc:
            items.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        }

        return items
    }

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recordings")
                        .font(.title2.weight(.semibold))
                    Text(spaceController.activeSpace.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search recordings...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            // Content area
            if isLoading {
                Spacer()
                ProgressView("Loading recordings...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Failed to load recordings")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        subscribeToRecordings()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
            } else if filteredRecordings.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    if searchText.isEmpty {
                        Text("No Recordings Yet")
                            .font(.headline)
                        Text("Recordings made in this space will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No Results")
                            .font(.headline)
                        Text("No recordings match \"\(searchText)\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredRecordings) { recording in
                            recordingCard(recording)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            subscribeToRecordings()
        }
        .onChange(of: spaceController.activeSpace) {
            subscribeToRecordings()
        }
        .onDisappear {
            subscription?.cancel()
        }
    }

    // MARK: - Recording Card

    private func recordingCard(_ recording: RecordingItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Thumbnail placeholder (16:9)
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .aspectRatio(16 / 9, contentMode: .fit)

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary.opacity(0.5))
            }

            // Title
            Text(recording.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            // Metadata row
            HStack(spacing: 8) {
                Label(recording.formattedDuration, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if recording.shareEnabled == true {
                    Label("Shared", systemImage: "link")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }

                Spacer()

                if let dateStr = recording.creationDate.map({ date in
                    let fmt = RelativeDateTimeFormatter()
                    fmt.unitsStyle = .abbreviated
                    return fmt.localizedString(for: date, relativeTo: Date())
                }) {
                    Text(dateStr)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contextMenu {
            Button {
                Task { await shareRecording(recording) }
            } label: {
                Label("Share Link", systemImage: "link")
            }

            Menu("Move to...") {
                ForEach(spaceController.availableSpaces) { space in
                    Button(space.name) {
                        Task { await moveRecording(recording, to: space) }
                    }
                    .disabled(space.id == spaceController.activeSpace.id)
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

    private func subscribeToRecordings() {
        guard let client = authController.convexClient else {
            errorMessage = "Not connected to backend"
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        // Cancel any existing subscription before creating a new one
        subscription?.cancel()

        var args: [String: ConvexEncodable?] = [:]
        if let orgId = spaceController.currentOrganizationId {
            args["organizationId"] = orgId
        }

        let publisher: AnyPublisher<[RecordingItem], ClientError> = client.subscribe(
            to: "recordings:list",
            with: args
        )

        subscription = publisher
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        print("[RecordingsLibrary] Subscription error: \(error)")
                        errorMessage = String(describing: error)
                        isLoading = false
                    }
                },
                receiveValue: { items in
                    recordings = items
                    errorMessage = nil
                    isLoading = false
                }
            )
    }

    // MARK: - Actions

    private func shareRecording(_ recording: RecordingItem) async {
        guard let client = authController.convexClient else { return }

        do {
            let token: String = try await client.mutation(
                "recordings:enableSharing",
                with: ["recordingId": recording._id]
            )
            let shareUrl = AppConfig.convexSiteUrl + "/share/" + token
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(shareUrl, forType: .string)
        } catch {
            print("[RecordingsLibrary] Failed to enable sharing: \(error)")
        }
    }

    private func moveRecording(_ recording: RecordingItem, to space: Space) async {
        guard let client = authController.convexClient else { return }

        do {
            var args: [String: ConvexEncodable?] = ["recordingId": recording._id]
            if !space.isPersonal {
                args["targetOrganizationId"] = space.id
            }
            try await client.mutation("recordings:moveToSpace", with: args)
        } catch {
            print("[RecordingsLibrary] Failed to move recording: \(error)")
        }
    }

    private func deleteRecording(_ recording: RecordingItem) async {
        guard let client = authController.convexClient else { return }

        do {
            let args: [String: ConvexEncodable?] = ["recordingId": recording._id]
            try await client.mutation("recordings:remove", with: args)
        } catch {
            print("[RecordingsLibrary] Failed to delete recording: \(error)")
        }
    }
}
