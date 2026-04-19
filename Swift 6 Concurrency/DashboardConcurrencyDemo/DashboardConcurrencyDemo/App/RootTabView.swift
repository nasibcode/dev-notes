//
//  RootTabView.swift
//  DashboardConcurrencyDemo/App
//
//  Small navigation shell so one Xcode target can host:
//  - SwiftUI dashboard (`.task` cancellation story)
//  - UIKit dashboard (stored `Task` cancellation story)
//  - Advanced patterns (continuations, streams, timeouts) from the article’s appendix
//

import SwiftUI // UI primitives for tabs, navigation titles, and `UIViewControllerRepresentable`.

/// Root container using a tab bar — each tab is an isolated “feature island” for teaching clarity.
struct RootTabView: View { // `View` is the core SwiftUI protocol for anything renderable.
    /// `body` describes the tab bar; SwiftUI diff’s it against the previous render tree.
    var body: some View { // `some View` keeps the concrete `TupleView` / `_VariadicView` types private.
        TabView { // System tab control; each child is one tab item.
            DashboardView() // Article Part 1–6 + Part 8: SwiftUI + `@Observable` view model + `.task`.
                .tabItem { Label("Dashboard", systemImage: "rectangle.grid.2x2") } // Tab chrome: title + SF Symbol.

            UIKitDashboardHost() // Article Part 1: `UIViewController` + stored `Task` + explicit cancel.
                .tabItem { Label("UIKit", systemImage: "square.stack.3d.up") } // Separate tab so UIKit stays obvious.

            AdvancedPatternsView() // Article “Advanced edge cases” section — interactive teaching surface.
                .tabItem { Label("Advanced", systemImage: "bolt.horizontal.circle") } // Grouped demos, not production UI.
        } // End `TabView` — switching tabs does not cancel the other tab’s in-flight work unless you code that.
    } // End `body`.
} // End `RootTabView`.
