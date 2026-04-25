import Foundation

/// A note fetched from the Convex backend.
struct ConvexNote: Identifiable {
    let id: String          // Convex document _id
    let text: String
    let dayStamp: String
    let timestamp: String
    let spaceId: String?
}

/// Fetches and caches notes from the Convex HTTP API, filtered by space.
@MainActor @Observable
final class NoteListController {

    private(set) var notes: [ConvexNote] = []
    private(set) var isLoading = false
    var error: String?

    /// Fetch notes for the given space from Convex.
    /// Pass nil spaceId for personal space.
    func fetchNotes(spaceId: String?) async {
        isLoading = true
        error = nil

        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = [:]
            if let spaceId {
                args["spaceId"] = spaceId
            }

            let result = try await ConvexHTTPClient.query(
                function: "notes:list",
                args: args,
                token: token
            )

            guard let items = result as? [[String: Any]] else {
                notes = []
                isLoading = false
                return
            }

            notes = items.compactMap { item in
                guard let id = item["_id"] as? String,
                      let text = item["text"] as? String,
                      let dayStamp = item["dayStamp"] as? String,
                      let timestamp = item["timestamp"] as? String
                else { return nil }

                return ConvexNote(
                    id: id,
                    text: text,
                    dayStamp: dayStamp,
                    timestamp: timestamp,
                    spaceId: item["spaceId"] as? String
                )
            }
        } catch {
            self.error = error.localizedDescription
            NSLog("[NoteList] Failed to fetch notes: %@", String(describing: error))
        }

        isLoading = false
    }

    /// Move a note to a different space via Convex mutation.
    func moveNote(noteId: String, toSpaceId: String?) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            var args: [String: Any] = ["noteId": noteId]
            if let toSpaceId {
                args["targetSpaceId"] = toSpaceId
            }

            _ = try await ConvexHTTPClient.mutation(
                function: "notes:moveToSpace",
                args: args,
                token: token
            )
        } catch {
            NSLog("[NoteList] Failed to move note: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }

    /// Delete a note via Convex mutation.
    func deleteNote(noteId: String) async {
        do {
            let token = try await ConvexHTTPClient.getToken()

            _ = try await ConvexHTTPClient.mutation(
                function: "notes:remove",
                args: ["noteId": noteId],
                token: token
            )

            notes.removeAll { $0.id == noteId }
        } catch {
            NSLog("[NoteList] Failed to delete note: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }
}
