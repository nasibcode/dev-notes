//
//  DashboardView.swift
//  DashboardConcurrencyDemo/Features/Dashboard
//
//  Implements the SwiftUI side of Part 1 (`.task` lifetime == view lifetime) and Part 2 (MainActor VM).
//

import SwiftUI // Declarative UI, `.task`, lists, navigation primitives.

/// Primary SwiftUI screen — intentionally verbose comments map 1:1 to the Medium article’s snippets.
struct DashboardView: View { // `View` protocol conformance is synthesized by stored properties + `body`.
    /// Holds the view model — `@State` is correct for `@Observable` classes in modern SwiftUI (article Part 2 note).
    @State private var viewModel = DashboardViewModel() // Constructed on the MainActor when the view first appears.

    /// Describes the user-visible tree for this screen — SwiftUI calls this frequently during state changes.
    var body: some View { // `some View` hides the opaque return type (`VStack`, `Group`, etc.) behind a protocol.
        NavigationStack { // Stack-based navigation container — gives a title bar + push/pop affordances if expanded.
            content // Extracted subview keeps `body` readable — still one combined render tree from SwiftUI’s POV.
                .navigationTitle("Dashboard") // Large title style on iOS — helps orient readers opening the demo.
        } // End `NavigationStack` — wraps everything in a navigation context for consistent platform chrome.
    } // End `body` — no side effects here beyond describing UI; async work is started in `.task` below.

    /// Core scrollable content — split out only so `body` stays short; not a separate “mini feature module.”
    @ViewBuilder // Allows `switch`/`if` to compile to a single opaque `View` type without manual `AnyView` erasure.
    private var content: some View { // `private` — an implementation detail of `DashboardView`’s layout.
        List { // `List` is lazy and system-styled — good enough for teaching data presentation.
            Section("State") { // First section — shows the view model’s high-level `State` enum value as text.
                Text(stateDescription) // `Text` is a leaf view — reads derived string from `viewModel.state`.
                    .font(.footnote.monospaced()) // Monospace helps readers compare enum cases while debugging UI.
            } // End section — SwiftUI inserts default section headers on iOS.

            Section("Notes") { // Second section — surfaces `lastLoadNote` for cancellation teaching moments.
                Text(viewModel.lastLoadNote) // Binds to observable property — updates when `load()` mutates it.
                    .font(.footnote) // Smaller type — this is auxiliary narrative, not primary UI content.
            } // End section.

            if case let .loaded(snapshot) = viewModel.state { // Conditional UI only when data exists — avoids crashes.
                Section("Profile") { // Profile subsection — maps `ProfileDTO` fields to simple `Text` rows.
                    Text("ID: \(snapshot.profile.id)") // Read-only string interpolation — `id` is a `String`.
                    Text("Name: \(snapshot.profile.displayName)") // Display name from mock `fetchProfile()` path.
                } // End profile section.

                Section("Settings") { // Settings subsection — mirrors `SettingsDTO` fields from the service mock.
                    Text("Reduced motion: \(snapshot.settings.prefersReducedMotion ? "YES" : "NO")") // Bool → readable.
                } // End settings section.

                Section("Flags") { // Flags subsection — shows remote-config style booleans from `FlagsDTO`.
                    Text("New dashboard: \(snapshot.flags.enableNewDashboard ? "ON" : "OFF")") // Simple on/off labeling.
                } // End flags section.

                Section("Recommendations") { // List of `RecommendationDTO` rows — uses `Identifiable.id` for stability.
                    ForEach(snapshot.recommendations) { rec in // `ForEach` expands to one row per recommendation.
                        VStack(alignment: .leading, spacing: 4) { // Vertical stack for title + small metadata line.
                            Text(rec.title) // Primary line — human-readable title from mock network payload.
                            Text("id: \(rec.id)") // Secondary line — shows stable identity for TaskGroup demos later.
                                .font(.caption2) // Smaller secondary text — de-emphasizes compared to the title line.
                                .foregroundStyle(.secondary) // Semantic secondary color — adapts in light/dark mode.
                        } // End `VStack` — one cell worth of content per recommendation row.
                    } // End `ForEach` — if recommendations change, SwiftUI diffs rows by `id` where possible.
                } // End recommendations section.
            } // End `if case` — when not loaded, these sections simply don’t exist in the hierarchy.

            Section("Actions") { // Demo buttons — each action is intentionally small and teaching-oriented.
                Button("Reload") { // Tapping schedules async work — still structured under SwiftUI’s event mechanisms.
                    Task { await viewModel.load() } // `Task {}` inherits MainActor context from the button action site.
                } // End button — **not** `Task.detached` — matches the article’s warning about UI updates (Part 1).

                if case .loaded = viewModel.state { // Only offer “download many” when you can derive URLs from rows.
                    Button("Download first avatars (sequential)") { // Demonstrates cancellation-friendly sequential loop.
                        Task { @MainActor in // Explicit `@MainActor` task — reads `viewModel.state` on the UI lane safely.
                            guard case let .loaded(snapshot) = viewModel.state else { return } // Re-check loaded — defensive.
                            let urls = snapshot.recommendations.compactMap(\.avatarURL) // Collect optional URLs for download.
                            _ = try? await viewModel.downloadMany(urls: urls) // Await service-backed I/O off the hot path.
                        } // End `Task` — unstructured bridge from sync button action — **not** `Task.detached` (Part 1).
                    } // End button — pedagogy: sequential downloads vs `TaskGroup` trade-offs (article Part 6 vs 7).
                } // End conditional section — hides the button unless a snapshot exists.
            } // End actions section.
        } // End `List` — single scrollable surface for the whole dashboard teaching UI.
        .task { await viewModel.load() } // **Key idea:** lifetime tied to view — auto-cancel on disappear (Part 1).
    } // End `content` — extracted builder keeps `body` small while preserving one logical screen.
} // End `DashboardView`.

extension DashboardView { // Presentation helpers — keeps `content` focused on layout, not string formatting.
    /// Human-readable `State` description for the “State” section header area — avoids duplicating `switch` UI.
    fileprivate var stateDescription: String { // `fileprivate` — only this file needs this helper.
        switch viewModel.state { // Exhaustive switch over nested `enum` — compiler enforces handling new cases.
        case .idle: return "idle" // Short lowercase label — matches case name for easy scanning in screenshots.
        case .loading: return "loading" // Indicates in-flight work — should correlate with spinner if you add one.
        case .loaded: return "loaded" // Don’t stringify whole snapshot here — keep the row compact and stable.
        case .failed(let message): return "failed: \(message)" // Surface the failure string for quick debugging reads.
        } // End `switch` — if you add a case, Swift compiler forces you to update this helper too.
    } // End `stateDescription` — derived state only — no async work.
} // End extension.
