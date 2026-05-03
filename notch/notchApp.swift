//
//  notchApp.swift
//  notch
//
//  Created by J. P. Moore on 4/28/26.
//

import SwiftUI

@main
struct notchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Notch overlay + clipboard from `AppDelegate`. Preferences use SwiftUI `Settings`; the gear uses `SettingsLink`.
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
        .defaultLaunchBehavior(.suppressed)

        Settings {
            NotchNikSettingsView()
                .environmentObject(appDelegate.settingsStore)
                .environmentObject(appDelegate.clipboardStore)
                .environmentObject(appDelegate.calendarStore)
                .environmentObject(appDelegate.filePenStore)
                .environmentObject(appDelegate.activityWatcher)
                .environmentObject(appDelegate.insightsCommentator)
                .environmentObject(appDelegate.focusScoreEngine)
        }
    }
}
