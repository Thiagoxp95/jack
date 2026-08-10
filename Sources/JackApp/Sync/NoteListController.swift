import Foundation

/// Loads voice notes from the local `Jack Notes` markdown files.
///
/// Auth and the Convex backend were removed, so notes live entirely on disk.
@MainActor @Observable
final class NoteListController {

    private(set) var notes: [VoiceNote] = []
    private(set) var isLoading = false
    var error: String?

    private let noteService: NoteService

    init(noteService: NoteService = NoteService()) {
        self.noteService = noteService
    }

    /// Reload notes from disk, newest first.
    func refresh() {
        isLoading = true
        error = nil
        notes = noteService.loadAllNotes()
        isLoading = false
    }

    /// Delete a note from its daily markdown file.
    func deleteNote(_ note: VoiceNote) {
        do {
            try noteService.deleteNote(dayStamp: note.dayStamp, timestamp: note.timestamp)
            notes.removeAll { $0.id == note.id }
        } catch {
            NSLog("[NoteList] Failed to delete note: %@", String(describing: error))
            self.error = error.localizedDescription
        }
    }
}
