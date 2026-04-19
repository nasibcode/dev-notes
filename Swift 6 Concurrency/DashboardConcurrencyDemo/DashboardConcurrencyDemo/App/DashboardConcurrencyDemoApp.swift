//
//  DashboardConcurrencyDemoApp.swift
//  DashboardConcurrencyDemo/App
//
//  Mirrors the article’s SwiftUI entry: a single `WindowGroup` hosts the demo UI.
//  Every line below is annotated so you can map it directly to Part 1 / Part 8 of
//  `medium-swift6-concurrency.md`.
//

import SwiftUI // Brings in `App`, `WindowGroup`, `Scene`, and SwiftUI’s declarative UI types.

/// The `@main` attribute tells the compiler this type is the process entry point.
/// Exactly one `@main` is required for an iOS app target.
@main // Marks the type below as the application’s entry type (replaces `main.swift`).
struct DashboardConcurrencyDemoApp: App { // `struct` synthesizes `init()` — `App` requires an `init()` declaration.
    /// SwiftUI calls `body` to build the root scene graph for the app.
    var body: some Scene { // `some Scene` hides the concrete scene type while preserving type safety.
        WindowGroup { // Creates a window (or windows on iPad) and hosts the root view hierarchy.
            RootTabView() // Our root view: tabs separate the “Dashboard story” from UIKit + advanced demos.
        } // End `WindowGroup` — lifecycle is tied to the scene, not individual screens (contrast with `.task` on views).
    } // End `body` — SwiftUI re-evaluates this when state that `body` reads changes (not much here).
} // End `DashboardConcurrencyDemoApp` — keep this file tiny: real work lives in feature modules.
