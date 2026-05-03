//
//  NotchSessionActions.swift
//  notch
//

import Combine
import Foundation

/// Bridges SwiftUI (expanded panel) to `AppDelegate` when opening Settings (`SettingsLink` handles the window).
final class NotchSessionActions: ObservableObject {
    /// Collapses the click-expanded notch panel (e.g. before/during opening Settings).
    var collapseExpandedPanel: (() -> Void)?

    func triggerCollapseExpandedPanel() {
        collapseExpandedPanel?()
    }
}
