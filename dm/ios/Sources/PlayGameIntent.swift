// App Intents: launch this game from Siri, Shortcuts or the Action Button ("Play <game>").
// The per-game URL scheme is registered by build_ipa.sh (nxnative-<title id>); opening the
// app is all the intent does — the game's own launcher/settings flow then runs as usual.
import AppIntents
import UIKit

struct PlayGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Play"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct PlayGameShortcuts: AppShortcutsProvider {
    static var shortcutTitle: LocalizedStringResource = "Play the game"

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayGameIntent(),
            phrases: [
                "Play \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Play",
            systemImageName: "gamecontroller.fill"
        )
    }
}
