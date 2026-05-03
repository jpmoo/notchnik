//
//  NotchGeometry.swift
//  notch
//

import AppKit

enum NotchGeometry {
    /// Sizes that match the camera housing using the gap between the menu-bar “ears” (same approach as system layout).
    /// See `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
    static func notchSize(for screen: NSScreen) -> (width: CGFloat, height: CGFloat) {
        if #available(macOS 12.0, *) {
            if let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea {
                let width = right.minX - left.maxX
                if width > 1 {
                    let height = screen.frame.maxY - min(left.minY, right.minY)
                    return (width, max(height, 1))
                }
            }
        }

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return (180, max(menuBarHeight, 25))
    }

    /// Horizontal center of the camera cutout in **screen** coordinates (midpoint between menu-bar ears).
    /// Using `NSScreen.frame.midX` can disagree slightly and makes hover/resize look off-center.
    static func notchCenterX(for screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            if let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea {
                let width = right.minX - left.maxX
                if width > 1 {
                    return (left.maxX + right.minX) / 2
                }
            }
        }
        return screen.frame.midX
    }
}
