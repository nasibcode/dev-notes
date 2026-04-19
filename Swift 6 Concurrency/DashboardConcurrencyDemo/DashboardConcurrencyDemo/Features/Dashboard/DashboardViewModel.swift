//
//  DashboardViewModel.swift
//  DashboardConcurrencyDemo/Features/Dashboard
//
//  Implements Part 2 (`@MainActor` + `@Observable`) and Part 8 wiring from the article:
//  UI state on the main actor, services off it, subsystem hops via `await`.
//

import Foundation // `String(describing:)` for simple error surfaces — keep dependencies minimal here.
import Observation // `@Observable` macro and the observation machinery used by SwiftUI in iOS 17+ patterns.

/// View model isolated to the main actor — **all** UI-bound mutations happen on the UI lane (article Part 2).
@MainActor // Compiler-enforced: methods/properties are main-actor unless explicitly opted out with `nonisolated`.
@Observable // Macro synthesizes observation hooks so SwiftUI tracks property reads/writes without `@Published`.
final class DashboardViewModel { // `final` keeps dynamic dispatch smaller and clarifies you don’t subclass this.
    /// High-level UI state machine — `enum` makes invalid combinations (e.g. loaded+failed) unrepresentable.
    enum State { // Not `Equatable`: `DashboardSnapshot` carries `URL`/`Data` paths in later features; SwiftUI doesn’t require `==` here.
        case idle // Initial — user has not triggered a load yet (or you reset after teardown).
        case loading // Fetch in flight — show spinner / skeleton UI while this is active.
        case loaded(DashboardSnapshot) // Success — carries an immutable snapshot for rendering lists and text.
        case failed(String) // Failure — carries a user-presentable string (demo simplicity over localization).
    } // End `State` — nested inside the VM keeps naming tight (`DashboardViewModel.State`).

    /// Published to UI — `private(set)` prevents views from mutating state directly; only the VM changes it.
    private(set) var state: State = .idle // Starts idle — `DashboardView` will call `load()` from `.task`.

    /// Log line for teaching — shows last cancellation vs error outcome without a full logging framework.
    private(set) var lastLoadNote: String = "" // Updated on cancellation paths — bound read-only to SwiftUI.

    /// Service that performs parallel `async let` fan-out — not `@MainActor` (article Part 8 separation).
    private let service: DashboardService // Immutable dependency — constructed once per view model lifetime.

    /// Lazily resolved `PreferencesStore` — avoids `@PreferencesActor` default values on a `@MainActor` initializer (Swift 6).
    private var preferences: PreferencesStore? // First `load()` assigns this via explicit global-actor hop (article Part 3).

    /// Actor-backed avatar repository — constructed per view model so `@State` construction stays isolation-clean.
    private let avatars: AvatarRepository // `actor` handle — all cache mutations go through `await` at call sites.

    /// Primary initializer — only `DashboardService` / `AvatarRepository` use defaults safe on the main actor here.
    init( // Dependency injection hook — previews/tests can substitute `service` / `avatars` without touching preferences.
        service: DashboardService = DashboardService(), // Default service — `Sendable` struct with `URLSession` inside.
        avatars: AvatarRepository = AvatarRepository() // Default repository — one cache per VM instance in this demo app.
    ) { // End parameter list — `DashboardView` still uses `DashboardViewModel()` with zero explicit arguments at call sites.
        self.service = service // Store service — `DashboardService` is a `Sendable` struct, safe to hold on MainActor.
        self.avatars = avatars // Store repository — actor hops happen only when calling `await avatars.avatar(...)` etc.
    } // End `init` — preferences resolve lazily because `PreferencesStore.shared` lives on a different global actor executor.

    /// Resolves `PreferencesStore.shared` on `PreferencesActor` — makes the `await` boundary obvious for readers (Part 3).
    private func resolvedPreferences() async -> PreferencesStore { // `async` because hopping global actors can suspend.
        if let preferences { return preferences } // Reuse cached handle after first load — avoids repeating actor hops.
        let store = await { @PreferencesActor in // Enter the preferences subsystem’s serialized global lane explicitly.
            PreferencesStore.shared // `static let` is initialized lazily under this actor — matches article’s store shape.
        }() // Immediately-invoked async closure — returns the shared store reference to the `@MainActor` view model instance.
        preferences = store // Cache for subsequent loads — storing the reference does not bypass method-level isolation rules.
        return store // Provide a local binding for immediate `await prefs...` calls in `load()` below.
    } // End `resolvedPreferences` — teaching note: default parameter `= .shared` on `@MainActor init` fails strict isolation.

    /// Entry point called from SwiftUI `.task` — cancellation when the view disappears maps to `CancellationError`.
    func load() async { // `async` allows awaiting service/repository calls without blocking the main thread.
        state = .loading // Immediate UI transition — still on MainActor because this whole type is `@MainActor`.
        lastLoadNote = "" // Reset the teaching label — avoids stale cancellation text across reload taps.
        do { // `do/catch` separates expected cancellation from “real” errors (article Part 1 snippet).
            let snapshot = try await service.loadSnapshot() // Hop off MainActor for parallel child tasks — then return.
            try Task.checkCancellation() // Extra guard after awaits — avoids committing UI if already cancelled mid-flight.

            if let firstURL = snapshot.recommendations.compactMap(\.avatarURL).first { // Pick one URL to prove cache path.
                _ = try await avatars.avatar(for: firstURL) // `await` enters actor — warms cache for demo storytelling.
            } // End optional warm — ignores returned bytes in UI, but proves cross-actor call compiles and runs.

            let prefs = await resolvedPreferences() // Ensure `PreferencesStore` exists — hops via `@PreferencesActor` closure.
            let version = await prefs.lastSeenDashboardVersion() // Read prior version — second hop onto preferences lane.
            await prefs.setLastSeenDashboardVersion(version + 1) // Write hop — demonstrates global actor use from MainActor VM.

            state = .loaded(snapshot) // Commit UI snapshot — still MainActor-isolated after background work finished.
            lastLoadNote = "Loaded snapshot (preferences version now \(version + 1))." // Human-readable success note.
        } catch is CancellationError { // Special-case cooperative cancellation — not a “bug” (article guidance).
            state = .idle // Return to idle — alternative: keep last good snapshot; product decision, not compiler rule.
            lastLoadNote = "Cancelled: SwiftUI `.task` cancelled this load when the view hierarchy changed." // Teachable.
        } catch { // Any other error — surface as a simple string for the demo UI.
            state = .failed(String(describing: error)) // `String(describing:)` is quick-and-dirty, not user-facing polish.
            lastLoadNote = "Failed with error: \(error.localizedDescription)" // Slightly nicer string for debugging demos.
        } // End `catch` — in production you’d classify errors (network, decode, auth) for actionable UI.
    } // End `load` — this is the “happy path coordinator” the Medium article’s architecture section describes.

    /// Thin wrapper so SwiftUI can call the service’s sequential downloader without reaching into `DashboardService`.
    func downloadMany(urls: [URL]) async throws -> [Data] { // `throws` bubbles `URLError` / cancellation as needed.
        try await service.downloadMany(urls: urls) // Delegate I/O to nonisolated service — keeps MainActor light (Part 2).
    } // End `downloadMany` — mirrors the article’s `downloadMany(urls:)` behavior without duplicating networking code.
} // End `DashboardViewModel` — SwiftUI holds this in `@State` per Observation guidance from the article.
