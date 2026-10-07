import Foundation
import MinutesKit
import Observation

/// Long-lived app services, created once at launch.
@MainActor @Observable
final class AppModel {
    let notesBridge = NotesBridge()
    let indexer: NotesIndexer?
    let startupError: String?

    init() {
        do {
            let index = try NotesIndex(url: NotesIndex.defaultURL())
            indexer = NotesIndexer(index: index, bridge: notesBridge)
            startupError = nil
        } catch {
            indexer = nil
            startupError = "Minutes couldn't open its notes index: \(error)"
        }
        indexer?.start()
    }
}
