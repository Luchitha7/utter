import Foundation

/// Decides when the user has finished speaking. Apple's recogniser keeps listening until told to
/// stop, so Utter finishes the command itself after a pause with no new words.
struct Endpointer {
    enum Outcome: Equatable { case listen, finish, noSpeech }

    /// Seconds without a new word before the command counts as finished.
    var silence: TimeInterval = 1.5
    /// Seconds to wait for the first word before giving up.
    var noSpeechTimeout: TimeInterval = 8

    func check(startedAt: Date, lastWordAt: Date?, now: Date) -> Outcome {
        guard let lastWordAt else { return now.timeIntervalSince(startedAt) >= noSpeechTimeout ? .noSpeech : .listen }
        return now.timeIntervalSince(lastWordAt) >= silence ? .finish : .listen
    }
}
