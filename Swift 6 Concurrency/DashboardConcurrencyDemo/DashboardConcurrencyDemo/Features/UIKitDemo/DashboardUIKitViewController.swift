//
//  DashboardUIKitViewController.swift
//  DashboardConcurrencyDemo/Features/UIKitDemo
//
//  Implements Part 1’s UIKit pattern: store a `Task`, start it from a lifecycle hook, cancel when the
//  screen should stop loading. `UIViewController` is `@MainActor` in current SDKs — matches the article.
//

import UIKit // `UIViewController`, `UILabel`, Auto Layout, colors — UIKit module for non-SwiftUI screens.

/// Minimal UIKit screen that loads the same dashboard snapshot as SwiftUI — compares lifecycle cancellation.
@MainActor // Explicit for readers — `UIViewController` is already main-actor isolated in modern SDKs anyway.
final class DashboardDemoViewController: UIViewController { // `final` — not designed for subclassing in demos.
    /// Handle to in-flight async work — `Task<Void, Never>` means “no return value, never throws” for simplicity.
    private var loadTask: Task<Void, Never>? // Optional because there may be no task between runs / after cancel.

    /// Primary status label — kept as a field so async load methods can update text without rebuilding hierarchy.
    private let statusLabel: UILabel = { // Closure initializes constant properties before `self` is fully ready.
        let label = UILabel() // Construct system label — default font/color are fine for teaching UI.
        label.numberOfLines = 0 // Allow multi-line text — cancellation notes can be longer than one line.
        label.textAlignment = .center // Center within the controller — quick readability in a tab demo host.
        label.translatesAutoresizingMaskIntoConstraints = false // We’ll use Auto Layout anchors below.
        return label // Return configured label to assign into the stored property initializer.
    }() // End property closure — runs once per view-controller instance during field initialization.

    /// UIKit calls this after the view loads — safe place to build hierarchy and kick off async loads.
    override func viewDidLoad() { // `override` because we extend `UIViewController`’s default implementation.
        super.viewDidLoad() // Always call super first — Apple template rule for lifecycle overrides.
        view.backgroundColor = .systemBackground // Semantic background color — adapts light/dark appearance modes.
        statusLabel.text = "Idle — will start loading…" // Initial copy — user sees something before async begins.
        view.addSubview(statusLabel) // Mount label into the root view — still empty frame until constraints activate.
        NSLayoutConstraint.activate([ // Activate a batch of constraints — common Auto Layout style in modern UIKit.
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor), // Left margin inset.
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor), // Right inset.
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor), // Vertically centered — simple layout.
        ]) // End constraint activation — label now participates in layout passes.

        loadTask = Task { [weak self] in // `Task {}` inherits `@MainActor` context — matches article guidance.
            await self?.runDemoLoad() // `weak` avoids retaining `self` if the controller dismisses before completion.
        } // End `Task` closure — unstructured task stored in `loadTask` for explicit cancellation later.
    } // End `viewDidLoad` — note: article mentions `viewIsAppearing` if geometry matters — not needed for text-only UI.

    /// Called when the view is about to disappear — cancel in-flight loads to mirror SwiftUI `.task` teardown.
    override func viewWillDisappear(_ animated: Bool) { // Runs for pushes/pops/modals — article’s nuance applies.
        super.viewWillDisappear(animated) // Preserve superclass behavior — sometimes important for animation hooks.
        loadTask?.cancel() // Cooperative cancellation — `runDemoLoad` should respect `CancellationError` paths.
    } // End `viewWillDisappear` — article warns this also runs when covered by modal; product code may gate cancel.

    /// Backstop cancellation — synchronous and safe, but **not** a substitute for explicit lifecycle cancel (Part 1).
    deinit { // `deinit` cannot be `async` — only synchronous cleanup should live here in strict isolation worlds.
        loadTask?.cancel() // Sets cancellation flag — may not instantly stop work, but stops structured child tasks soon.
    } // End `deinit` — article: `deinit` can run later than you think — prefer `viewWillDisappear` for predictable UX.

    /// Async load routine — separated so `Task` closure stays tiny and readable for teaching scans.
    private func runDemoLoad() async { // `private` — internal implementation detail of this view controller.
        statusLabel.text = "Loading dashboard snapshot…" // UI mutation on MainActor — legal because type is `@MainActor`.
        let service = DashboardService() // Construct service locally — `Sendable` struct, fine to create on MainActor.
        do { // Separate success vs cancellation vs other errors — mirrors SwiftUI view model policy in this repo.
            let snapshot = try await service.loadSnapshot() // Await parallel fan-out — hops off thread as needed.
            statusLabel.text = "Loaded: \(snapshot.profile.displayName)" // Success string — simple, student-friendly.
        } catch is CancellationError { // Expected when user leaves tab / pops screen — not an “error UI” moment.
            statusLabel.text = "Cancelled (expected if you left while loading)." // Educational copy for screenshots.
        } catch { // Any other failure — show compact description — demo doesn’t include a full alert controller.
            statusLabel.text = "Failed: \(error.localizedDescription)" // `localizedDescription` is OK for lab builds.
        } // End `catch` — production might log `error` and show a retry affordance.
    } // End `runDemoLoad` — no `Task.detached` — avoids the article’s “UI update from detached task” footgun.
} // End `DashboardDemoViewController` — pair this with `UIKitDashboardHost` for SwiftUI tab embedding.
