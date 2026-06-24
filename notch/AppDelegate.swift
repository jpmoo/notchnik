//
//  AppDelegate.swift
//  notch
//

import AppKit
import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = AppSettingsStore()
    /// Lazily constructed so the Settings scene (which is built before `applicationDidFinishLaunching`
    /// runs) can inject it as an environment object without crashing on a force-unwrapped optional.
    private(set) lazy var clipboardStore = ClipboardHistoryStore(settings: settingsStore)
    @MainActor private(set) lazy var calendarStore = CalendarFeedStore()
    @MainActor private(set) lazy var filePenStore = FilePenStore()
    @MainActor private(set) lazy var fileDragMonitor = FileDragMonitor()
    @MainActor private(set) lazy var insightsChatStore = InsightsChatStore()
    @MainActor private(set) lazy var activityWatcher = ActivityWatcher()
    @MainActor private(set) lazy var insightsCommentator = InsightsCommentator(
        chat: insightsChatStore,
        activity: activityWatcher,
        calendar: calendarStore,
        settings: settingsStore
    )
    @MainActor private(set) lazy var focusScoreEngine = FocusScoreEngine(
        chat: insightsChatStore,
        activity: activityWatcher,
        calendar: calendarStore,
        settings: settingsStore
    )
    let sessionActions = NotchSessionActions()

    private var panel: NotchOverlayPanel?
    /// Separate floating panel hosting `NotchDropPillView` — a small drop target that appears
    /// well below the notch only while a file drag is in progress.
    private var dropPillPanel: NotchOverlayPanel?
    private var layoutModel: NotchLayoutModel!
    private var screenObserver: NSObjectProtocol?
    private var outsideClickMonitors: [Any] = []
    private var swipeMonitor: Any?
    /// Horizontal scroll delta accumulated since the last section commit. Reset after each commit so a
    /// continuous gesture that reverses direction (e.g., swipe forward then back) can undo itself.
    private var swipeAccum: CGFloat = 0
    /// CACurrentMediaTime() of the last swipe-driven section change. Used to debounce so a single fast
    /// trackpad gesture doesn't cycle through multiple sections.
    private var lastSwipeCommitTime: TimeInterval = 0
    private var panelFrameAnimationTimer: Timer?
    /// True while a resize-to-collapsed animation is running (`isClickExpanded` is still true until it finishes).
    private var isCollapsingPanel = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the app dock-icon-free for the entire session, even when Settings or Quick Look open.
        // (Both work fine in `.accessory` — they just need the app to be activated, not promoted to
        // a regular Dock-app.)
        NSApp.setActivationPolicy(.accessory)

        let screen = builtInOrMainScreen() ?? NSScreen.main!
        layoutModel = NotchLayoutModel(screen: screen)
        // Touch lazy properties so loading/polling happens at launch, not on first Settings open.
        _ = clipboardStore
        _ = calendarStore
        _ = filePenStore

        // Forward pasteboard file captures to the File Pen when the user opts in. The hook fires
        // for every file URL the clipboard captures; we gate on the live setting here so flipping
        // the toggle takes effect immediately without re-wiring.
        clipboardStore.onFileURLCaptured = { [weak self] url in
            guard let self else { return }
            guard self.settingsStore.filePenAutoCaptureFromPasteboard else { return }
            self.filePenStore.add(url)
        }

        // Cascade clipboard deletions into the pen — regardless of whether auto-capture is on,
        // since the user explicitly chose to remove the clip. (Adding back is gated; removing
        // is not.)
        clipboardStore.onFileURLRemoved = { [weak self] url in
            self?.filePenStore.removeMatching(url: url)
        }
        _ = insightsCommentator   // wires up its settings subscription so the timer flips on/off live
        _ = focusScoreEngine      // starts hourly focus scoring at launch

        sessionActions.collapseExpandedPanel = { [weak self] in
            guard let self, self.layoutModel.isClickExpanded else { return }
            self.requestAnimatedCollapse(completion: nil)
        }

        let hosting = NSHostingView(
            rootView: NotchOverlayView()
                .environmentObject(layoutModel)
                .environmentObject(clipboardStore)
                .environmentObject(sessionActions)
                .environmentObject(settingsStore)
                .environmentObject(calendarStore)
                .environmentObject(filePenStore)
                .environmentObject(insightsChatStore)
                .environmentObject(activityWatcher)
                .environmentObject(focusScoreEngine)
        )
        Self.configureOverlayOverflowRoot(hosting)

        let panel = NotchOverlayPanelFactory.makeHostingRoot(hosting)
        self.panel = panel

        // Track section changes so `.lastUsed` default can re-open on the right tool next time.
        layoutModel.$currentSection
            .dropFirst()
            .sink { [weak self] section in
                self?.settingsStore.recordLastUsedSection(section)
            }
            .store(in: &cancellables)

        // Forward the retention preference into the activity watcher so it prunes accordingly.
        settingsStore.$activityRetentionDays
            .sink { [weak self] days in
                Task { @MainActor in self?.activityWatcher.retentionDays = days }
            }
            .store(in: &cancellables)

        // Persisted "watch in background" toggle drives the watcher's start/stop. We also re-check
        // on AX-permission change because the watcher needs that grant to capture window titles —
        // turning AX off out-of-band shouldn't leave a stale watcher running.
        settingsStore.$activityWatchingEnabled
            .sink { [weak self] enabled in
                Task { @MainActor in self?.applyActivityWatching(enabled: enabled) }
            }
            .store(in: &cancellables)
        activityWatcher.$hasAccessibilityPermission
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyActivityWatching(enabled: self.settingsStore.activityWatchingEnabled)
                }
            }
            .store(in: &cancellables)

        // If the user hides the section that's currently active, switch the panel to a visible one
        // so we don't leave an off-screen-but-still-current section in `layoutModel`.
        settingsStore.$visibleSections
            .dropFirst()
            .sink { [weak self] visible in
                guard let self else { return }
                if !visible.contains(self.layoutModel.currentSection) {
                    if let target = PanelSection.allCases.first(where: { visible.contains($0) }) {
                        self.layoutModel.currentSection = target
                    }
                }
            }
            .store(in: &cancellables)

        layoutModel.$isClickExpanded
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                guard let self, let panel = self.panel else { return }
                if expanded {
                    self.isCollapsingPanel = false
                    self.animatePanelToClickExpanded(expanded, panel: panel) { [weak self] in
                        guard let self, self.layoutModel.isClickExpanded else { return }
                        // Defer the first capture so SwiftUI gets a clean frame to populate the grid before
                        // `captureCurrentPasteboardIfMissing` runs `imagesEqual` (TIFF re-encode per stored
                        // image — heavy enough to stall the main thread right at the end of the animation).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                            guard let self, self.layoutModel.isClickExpanded else { return }
                            self.clipboardStore.refreshFileExistenceFlags()
                            self.filePenStore.refreshMissingFlags()
                            self.clipboardStore.captureCurrentPasteboardIfMissing()
                            // Kick off a calendar fetch so the agenda reflects newly-added/changed
                            // events without waiting for the 15-minute auto-refresh timer.
                            Task { [weak self] in await self?.calendarStore.refreshAll() }
                        }
                        // Universal Clipboard can arrive shortly after the initial local expand.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                            guard let self, self.layoutModel.isClickExpanded else { return }
                            self.clipboardStore.captureCurrentPasteboardIfMissing()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in
                            guard let self, self.layoutModel.isClickExpanded else { return }
                            self.clipboardStore.captureCurrentPasteboardIfMissing()
                        }
                    }
                    self.installOutsideClickMonitors()
                    self.installSwipeMonitor()
                } else {
                    // Collapse is animated in `requestAnimatedCollapse` before this flips to false.
                    self.removeOutsideClickMonitors()
                    self.removeSwipeMonitor()
                }
            }
            .store(in: &cancellables)

        positionExpandedPanel(panel)
        panel.orderFrontRegardless()

        // Drop-pill panel: a separate borderless window below the notch that shows itself when
        // FileDragMonitor detects a file drag anywhere on the system. Hosting it in its own
        // window keeps the geometry and hit-testing independent of the main notch panel.
        let pillHosting = NSHostingView(
            rootView: NotchDropPillView()
                .environmentObject(filePenStore)
                .environmentObject(fileDragMonitor)
        )
        let pillPanel = NotchOverlayPanelFactory.makeHostingRoot(pillHosting)
        self.dropPillPanel = pillPanel
        positionDropPillPanel(pillPanel)
        pillPanel.orderFrontRegardless()
        // Visibility is driven entirely by the SwiftUI body inside (opacity / hit-testing on
        // FileDragMonitor.isFileDragActive). We deliberately do NOT re-position the panel on
        // every flag flip — calling `setFrame` mid-drop wedges the in-flight drop delivery.

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let screen = self.builtInOrMainScreen() ?? NSScreen.main else { return }
            self.layoutModel.update(from: screen)
            if let panel = self.panel {
                self.positionExpandedPanel(panel)
            }
            if let pillPanel = self.dropPillPanel {
                self.positionDropPillPanel(pillPanel)
            }
        }

        // Wake from sleep: macOS suspends Timer firing during sleep, so the activity watcher's
        // 30-second tick AND the focus engine's hourly tick both miss everything that would
        // have happened during the sleep window. On wake we force a fresh capture, a backfill
        // pass to fill any hours the activity log can cover, and a recompute of the current
        // hour — getting the chart and the pill back in sync with reality.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.activityWatcher.captureNow()
                await self.focusScoreEngine.recomputeNow()
                self.focusScoreEngine.backfillMissingHours()
            }
        }
    }

    /// Single source of truth for whether the watcher should be running. Combines the persisted
    /// preference with the live AX permission status — both must be true to start.
    @MainActor
    private func applyActivityWatching(enabled: Bool) {
        let shouldRun = enabled && activityWatcher.hasAccessibilityPermission
        if shouldRun, !activityWatcher.isWatching {
            activityWatcher.start()
        } else if !shouldRun, activityWatcher.isWatching {
            activityWatcher.stop()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        removeOutsideClickMonitors()
        removeSwipeMonitor()
        panelFrameAnimationTimer?.invalidate()
    }

    /// Collapse the expanded pane when the user clicks outside its window (screen coordinates).
    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.collapseExpandedIfClickOutside()
        }
        if let global {
            outsideClickMonitors.append(global)
        }

        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.collapseExpandedIfClickOutside()
            return event
        }
        if let local {
            outsideClickMonitors.append(local)
        }
    }

    /// Installs a local monitor that watches for horizontal-dominant trackpad scrolls over our panel
    /// and turns them into section changes (next/prev). Runs only while the panel is expanded.
    private func installSwipeMonitor() {
        removeSwipeMonitor()
        swipeAccum = 0

        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            // Only react to scrolls inside our panel.
            guard let target = self.panel, event.window === target else { return event }

            // Reset accumulator on the start of each gesture.
            if event.phase == .began {
                self.swipeAccum = 0
            }

            // Horizontal-dominant scrolls become section swipes; vertical ones (grid scrolling) pass through.
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                // Only the active-finger phase contributes to swipe detection. Momentum events would
                // otherwise pile up and over-fire (a single hard swipe coasts for hundreds of points).
                if event.momentumPhase.isEmpty {
                    self.swipeAccum += event.scrollingDeltaX
                    let threshold: CGFloat = 50
                    let now = CACurrentMediaTime()
                    let cooldown: TimeInterval = 0.32
                    if abs(self.swipeAccum) >= threshold,
                       now - self.lastSwipeCommitTime >= cooldown {
                        let current = self.layoutModel.currentSection
                        let order = self.settingsStore.orderedVisibleSections
                        // On macOS trackpads with natural scrolling, swiping LEFT (fingers move left)
                        // yields a NEGATIVE scrollingDeltaX — that's the *next* section. Navigation
                        // skips hidden sections and respects user's chosen ordering.
                        let target = self.swipeAccum < 0
                            ? current.next(in: order)
                            : current.previous(in: order)
                        if target != current {
                            self.layoutModel.switchSection(to: target)
                            self.lastSwipeCommitTime = now
                        }
                        self.swipeAccum = 0
                    }
                }
                if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                    self.swipeAccum = 0
                }
                // Consume all horizontal events (including momentum) so they don't bubble to the grid.
                return nil
            }

            return event
        }
    }

    private func removeSwipeMonitor() {
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
        }
        swipeMonitor = nil
        swipeAccum = 0
    }

    private func removeOutsideClickMonitors() {
        for monitor in outsideClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitors.removeAll()
    }

    private func collapseExpandedIfClickOutside() {
        guard layoutModel.isClickExpanded, !isCollapsingPanel, let panel else { return }
        // While a Quick Look preview is showing, treat clicks inside QL as "inside" — otherwise any
        // click in the QL window would dismiss our expanded panel.
        if QuickLookPreviewer.shared.isVisible { return }
        // Same idea for the focus-score detail floater — clicks inside (or that closed) it
        // shouldn't collapse the notch panel underneath.
        if FocusScoreDetailPresenter.shared.isVisible {
            let mouse = NSEvent.mouseLocation
            for window in NSApp.windows where window.isVisible && window !== panel {
                if window.frame.contains(mouse) { return }
            }
        }
        let mouse = NSEvent.mouseLocation
        if !panel.frame.contains(mouse) {
            requestAnimatedCollapse(completion: nil)
        }
    }

    /// Shrinks the window back to the notch (center/top) first, then clears expanded state so SwiftUI matches.
    private func requestAnimatedCollapse(completion: (() -> Void)?) {
        guard layoutModel.isClickExpanded, !isCollapsingPanel, let panel else {
            completion?()
            return
        }
        isCollapsingPanel = true
        animatePanelToClickExpanded(false, panel: panel) { [weak self] in
            guard let self else {
                completion?()
                return
            }
            self.isCollapsingPanel = false
            self.layoutModel.isClickExpanded = false
            completion?()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Lets outward top arcs render past view bounds; otherwise AppKit clips before layers paint.
    private static func configureOverlayOverflowRoot(_ rootView: NSView) {
        rootView.wantsLayer = true
        rootView.clipsToBounds = false
        rootView.layer?.masksToBounds = false
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.autoresizingMask = [.width, .height]
    }

    /// Panel frame for collapsed (hover) vs expanded. Content height includes `expandedPanelTopCornerBleed` for the lip.
    ///
    /// **Critical:** The window’s **top** must stay at or below `NSScreen.frame.maxY`. The old formula
    /// `originY = maxY - h + nudge + bleed` made `originY + height = maxY + nudge + bleed`, i.e. the window extended
    /// **above** the screen top. The compositor then clipped the top — horizontal cut through both rounded lips → it
    /// looked like **square 90° corners** even though the path was curved.
    private func panelFrame(clickExpanded: Bool, screen: NSScreen) -> NSRect {
        let topBleed = NotchMetrics.expandedPanelTopCornerBleed
        let sideBleed = NotchMetrics.expandedPanelSideCornerBleed
        let contentW: CGFloat
        let contentH: CGFloat
        if clickExpanded {
            contentW = NotchMetrics.clickExpandedWidth + 2 * sideBleed
            contentH = NotchMetrics.clickExpandedHeight + topBleed
        } else {
            // Wide enough for hover width (`NotchOverlayView`) so growth stays symmetric and isn’t clipped.
            contentW = layoutModel.baseWidth + 2 * NotchMetrics.hoverHorizontalExpansion + 2 * sideBleed
            contentH = layoutModel.baseHeight + NotchMetrics.hoverExpansion + topBleed
        }

        let pad = NotchMetrics.shadowPadding
        let w = contentW + 2 * pad
        // Only bottom + horizontal shadow gutter; no top inset so the panel lip sits flush with the screen top anchor.
        let h = contentH + pad
        let centerX = NotchGeometry.notchCenterX(for: screen)
        // Anchor the window’s **top** to the screen top (AppKit y increases upward). Optional nudge moves that anchor *down* only.
        let screenTopY = screen.frame.maxY
        let anchorTopY = screenTopY - NotchMetrics.panelNudgeUp
        let originY = anchorTopY - h

        return NSRect(
            x: centerX - w / 2,
            y: originY,
            width: w,
            height: h
        )
    }

    /// Instant positioning (launch, screen change, or non-interactive updates).
    /// Centers the drop-pill panel horizontally with the notch and anchors its top at
    /// `dropPillTopOffset` below the screen's top edge. Frame is slightly oversized so the
    /// transition's scale-up doesn't clip.
    private func positionDropPillPanel(_ panel: NSWindow) {
        guard let screen = panel.screen ?? builtInOrMainScreen() ?? NSScreen.main else { return }
        let pad: CGFloat = 12
        let w = NotchMetrics.dropPillWidth + 2 * pad
        let h = NotchMetrics.dropPillHeight + 2 * pad
        let centerX = NotchGeometry.notchCenterX(for: screen)
        let screenTopY = screen.frame.maxY
        let topY = screenTopY - NotchMetrics.dropPillTopOffset
        let originY = topY - h
        panel.setFrame(NSRect(x: centerX - w / 2, y: originY, width: w, height: h), display: true)
    }

    private func positionExpandedPanel(_ panel: NSWindow) {
        guard let screen = builtInOrMainScreen() ?? NSScreen.main else { return }
        panel.setFrame(panelFrame(clickExpanded: layoutModel.isClickExpanded, screen: screen), display: true)
    }

    /// Animates by interpolating width/height, then placing the frame from the **notch center** and **screen top** each tick.
    /// `NSAnimationContext` + `setFrame` instead interpolates `origin` and `size` independently, which shifts the window sideways during the transition.
    private func animatePanelToClickExpanded(_ expanded: Bool, panel: NSWindow, completion: (() -> Void)? = nil) {
        panelFrameAnimationTimer?.invalidate()
        guard let screen = builtInOrMainScreen() ?? NSScreen.main else {
            completion?()
            return
        }

        let from = panelFrame(clickExpanded: !expanded, screen: screen)
        let to = panelFrame(clickExpanded: expanded, screen: screen)
        let w0 = from.width
        let h0 = from.height
        let w1 = to.width
        let h1 = to.height

        let centerX = NotchGeometry.notchCenterX(for: screen)
        let duration = NotchMetrics.panelExpandAnimationDuration
        let startTime = CACurrentMediaTime()
        layoutModel.isFrameAnimating = true

        func setFrame(progress u: CGFloat) {
            let w = w0 + (w1 - w0) * u
            let h = h0 + (h1 - h0) * u
            let x = centerX - w / 2
            let y = from.origin.y + (to.origin.y - from.origin.y) * u
            // `display: false` lets CA coalesce redraws on the run loop; `display: true` forced a synchronous
            // redraw per tick that piled up SwiftUI layout cost faster than it could complete.
            panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        }

        setFrame(progress: 0)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timerRef in
            guard let self else {
                timerRef.invalidate()
                completion?()
                return
            }
            let elapsed = CACurrentMediaTime() - startTime
            let linearT = min(1.0, elapsed / duration)
            let u = CGFloat(Self.easeOutCubic(linearT))
            setFrame(progress: u)
            if linearT >= 1 {
                timerRef.invalidate()
                self.panelFrameAnimationTimer = nil
                setFrame(progress: 1)
                self.layoutModel.isFrameAnimating = false
                completion?()
            }
        }
        panelFrameAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Fast departure, gentle landing — avoids the "hesitation" feel of an ease-in-out start.
    private static func easeOutCubic(_ t: Double) -> Double {
        let m = 1 - t
        return 1 - m * m * m
    }

    /// Prefer the built-in MacBook panel so an external display does not capture the overlay.
    private func builtInOrMainScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(id) != 0 {
                return screen
            }
        }
        return NSScreen.main
    }
}
