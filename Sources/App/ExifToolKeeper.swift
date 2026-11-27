// ExifToolKeeper.swift
// 0.18.9: Settings > ExifTool Behavior - when Find's kept-running ExifTools are started and stopped:
//   with Find (ready at all times), with Photography Mode (started when a pane enters it, kept while
//   any pane is in it, stopped when the last one leaves), or only when needed (stopped after the idle
//   time). Metadata work outside these times still starts them, and they stop after the idle time.

import Foundation

enum ExifToolKeeper {
    private static var photoPanes = Set<String>()

    /// At start, from Settings.
    static func configure() {
        ExifToolPool.mode = ExifToolPool.Mode(rawValue: Prefs.exifToolMode) ?? .photoPanes
        ExifToolPool.count = Prefs.exifToolCount
        ExifToolPool.idleSeconds = Double(Prefs.exifToolIdleMinutes) * 60
        apply()
    }

    static func paneEnteredPhotography(_ id: String) {
        photoPanes.insert(id)
        if ExifToolPool.mode == .photoPanes { ExifToolPool.shared.hold("pane " + id) }
    }

    static func paneLeftPhotography(_ id: String) {
        photoPanes.remove(id)
        ExifToolPool.shared.release("pane " + id)
    }

    /// After a change in Settings.
    static func apply() {
        ExifToolPool.idleSeconds = Double(Prefs.exifToolIdleMinutes) * 60
        ExifToolPool.mode = ExifToolPool.Mode(rawValue: Prefs.exifToolMode) ?? .photoPanes
        switch ExifToolPool.mode {
        case .always:
            ExifToolPool.shared.hold("Find")
            for p in photoPanes { ExifToolPool.shared.release("pane " + p) }
        case .photoPanes:
            for p in photoPanes { ExifToolPool.shared.hold("pane " + p) }
            ExifToolPool.shared.release("Find")
        case .onDemand:
            for p in photoPanes { ExifToolPool.shared.release("pane " + p) }
            ExifToolPool.shared.release("Find")
        }
        Log.shared?.info("ExifTool behaviour: \(["with Find", "with Photography Mode", "only when needed"][ExifToolPool.mode.rawValue]), \(ExifToolPool.count) at a time, idle stop \(Prefs.exifToolIdleMinutes) min")
    }
}
