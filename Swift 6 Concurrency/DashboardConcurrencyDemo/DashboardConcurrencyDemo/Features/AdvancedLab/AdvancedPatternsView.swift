//
//  AdvancedPatternsView.swift
//  DashboardConcurrencyDemo/Features/AdvancedLab
//
//  SwiftUI surface for the appendix demos — each row triggers a `Task` and writes human-readable output text.
//

import SwiftUI // `View`, `List`, `Section`, `Button`, `Task` — standard SwiftUI building blocks for this lab screen.

/// Interactive “lab bench” UI for `AdvancedConcurrencyShowcase` — intended for reading alongside the Medium article.
struct AdvancedPatternsView: View { // Another `View` struct — tabs keep this isolated from dashboard production UI.
    /// Latest demo output — `@State` because buttons mutate it from `Task` completions running back on MainActor.
    @State private var output: String = "Tap a demo row." // Initial copy — replaced after each successful button run.

    /// Prevents double-taps from interleaving logs while a prior `Task` is still in flight — simple UX guard.
    @State private var isRunning: Bool = false // When `true`, buttons early-return — avoids overlapping network demos.

    /// Builds the lab UI — `List` keeps rows standard and accessible on iOS without custom layout engineering.
    var body: some View { // Computed property — SwiftUI may call frequently; keep work cheap in `body` itself.
        NavigationStack { // Navigation container — title helps readers know this tab is “appendix / edge cases.”
            List { // Vertical list of grouped rows — each button demonstrates one article subsection in isolation.
                Section("Output") { // First section — always-visible transcript of the last demo execution path.
                    Text(output) // `Text` shows multi-line strings — wrap works because default line limit is effectively nil.
                        .font(.footnote.monospaced()) // Monospace helps compare numbers / error names in screenshots.
                        .textSelection(.enabled) // Lets readers copy strings out of the simulator for notes / diffs.
                } // End output section.

                Section("Appendix demos") { // Each button corresponds to a subsection heading in the Medium article.
                    Button("1) Continuation bridge (resume exactly once)") { // Appendix 1 — callback → async bridging rule.
                        startDemo { // `startDemo` wraps `Task { @MainActor in ... }` — keeps each row’s intent identical.
                            let data = try await AdvancedConcurrencyShowcase.continuationBridgeDemo() // Await bridged bytes.
                            return String(decoding: data, as: UTF8.self) // Explicit `return` — multi-line closure isn’t a single expr.
                        } // End `startDemo` trailing closure — must return `String` for unified `output` assignment policy.
                    } // End button 1.

                    Button("2) AsyncStream cleanup (NotificationCenter)") { // Appendix 2 — `onTermination` unregister rule.
                        startDemo { // Same wrapper — ensures `isRunning` toggles consistently across heterogeneous demos.
                            await AdvancedConcurrencyShowcase.notificationPingDemo() // Await ping demo string (`"ping"`).
                        } // End closure — `notificationPingDemo` is non-throwing — still wrapped by `startDemo` for uniformity.
                    } // End button 2.

                    Button("3) Legacy cancellation bridge (URLSession)") { // Appendix 3 — `withTaskCancellationHandler`.
                        startDemo { // Wrapper still uses `try await` internally because `startDemo` accepts throwing work.
                            let count = try await AdvancedConcurrencyShowcase.cancellableDownloadDemo() // Await byte count.
                            return "Downloaded \(count) bytes from example.com" // Compose readable proof line for the UI log.
                        } // End closure — may fail offline — `startDemo` catches errors into `output` as red-text-ish strings.
                    } // End button 3.

                    Button("4) Actor refresh (await API, then mutate actor)") { // Appendix 4 — avoid `await` while locked.
                        startDemo { // Demonstrates `IDStore` + `IDsAPI` coordination — no `NSLock` in the happy path at all.
                            try await AdvancedConcurrencyShowcase.idStoreRefreshDemo() // Await joined ids string output.
                        } // End closure — throws if `fetchIDs` fails — unlikely in this mocked demo unless concurrency bugs.
                    } // End button 4.

                    Button("5) Best-effort TaskGroup (Result per child)") { // Appendix 5 — don’t fail the whole group.
                        startDemoNonThrowing { // Separate wrapper — avoids `try` noise when demo itself won’t throw.
                            let tuple = await AdvancedConcurrencyShowcase.bestEffortDemo() // Await `(ok,bad)` score tuple.
                            return "Successes: \(tuple.ok), failures: \(tuple.bad)" // Render tuple into one line for `Text`.
                        } // End closure — deterministic API means tuple is stable for screenshots / learner expectations.
                    } // End button 5.

                    Button("6) AsyncStream bufferingNewest(1)") { // Appendix 6 — avoid unbounded buffering in hot streams.
                        startDemoNonThrowing { // Non-throwing — stream draining ends normally unless task cancelled externally.
                            let last = await AdvancedConcurrencyShowcase.latestOnlyDemo() // Await last int from demo stream.
                            return "Last value seen: \(last)" // Expect `199` if fully drained — proves policy behavior simply.
                        } // End closure — no network — safe demo for airplane mode classrooms.
                    } // End button 6.

                    Button("7) Timeout helper (operation wins)") { // Appendix 7 — `withThrowingTaskGroup` + `cancelAll`.
                        startDemo { // Throwing — `withTimeout` uses a throwing group; operation path should win quickly here.
                            try await AdvancedConcurrencyShowcase.timeoutDemo() // Await `"Timeout race winner: finished"` text.
                        } // End closure — if sleep wins unexpectedly, you’d see cancellation-shaped errors — investigate sleeps.
                    } // End button 7.

                    Button("8) TaskGroup details fetch (service)") { // Part 7 — dynamic N structured concurrency with `try`.
                        startDemo { // Uses `DashboardService.fetchRecommendationsDetails` — may hit network for picsum URLs.
                            let service = DashboardService() // Fresh service instance — owns its own `URLSession` reference.
                            let items = try await service.fetchRecommendationsDetails(ids: ["r1", "r2", "r3"]) // Await DTOs.
                            return items.map(\.title).joined(separator: " | ") // Join titles — order may vary — lesson note.
                        } // End closure — first thrown error fails whole group — differs from best-effort `Result` pattern.
                    } // End button 8.

                    Button("9) Bounded thumbnail batching (service)") { // Part 7 — chunking + inner groups + cancellation checks.
                        startDemo { // Uses real `URLSession` downloads — requires network — can throw `URLError` on failure.
                            let service = DashboardService() // Fresh service — same as dashboard tab but focused on chunking demo.
                            let datas = try await service.fetchAllThumbnailsBounded(ids: ["r1", "r2", "r3"], maxConcurrent: 2) // Await.
                            let counts = datas.map(\.count).map(String.init).joined(separator: ",") // Per-thumbnail byte counts list.
                            return "Downloaded \(datas.count) thumbnails (byte counts: \(counts))" // Single-line summary for UI.
                        } // End closure — demonstrates bounded concurrency — never launches thousands of tasks at once.
                    } // End button 9.

                    Button("10) BankAccount deposit/withdraw (actor invariants)") { // Part 4 — synchronous withdraw inside actor.
                        startDemo { // Uses `BankAccount` actor — shows `await` hops + `try` for throwing `withdraw` boundary.
                            let account = BankAccount() // Fresh actor instance — no shared global bank state in this demo tab.
                            await account.deposit(50) // `await` crosses into actor — `deposit` itself has no internal `await`.
                            try await account.withdraw(20) // `try await` — withdrawal can throw insufficient funds errors.
                            let balance = await account.currentBalance() // `await` read — returns copied `Int` value to UI.
                            return "Balance after deposit 50 withdraw 20: \(balance)" // Expected `"30"` for this arithmetic path.
                        } // End closure — mental exercise: compare to article’s wrong `async` withdraw + sleep interleaving story.
                    } // End button 10.
                } // End demos section — explicit buttons trade “elegant abstraction” for maximum readability in a study repo.
            } // End `List` — scrolling is automatic when content exceeds screen height on iPhone layouts.
            .navigationTitle("Advanced patterns") // Title for orientation — matches `RootTabView` tab label closely.
        } // End `NavigationStack` — keeps large title behavior consistent with other tabs in this demo target.
    } // End `body`.
} // End `AdvancedPatternsView`.

extension AdvancedPatternsView { // Small helpers — each line commented so the concurrency story stays obvious in isolation.
    /// Runs a throwing async demo on the MainActor — updates `output` and uses `isRunning` as a simple mutex-like flag.
    @MainActor // Makes explicit that `output` / `isRunning` mutations are main-thread safe without extra hopping.
    fileprivate func startDemo(_ work: @escaping @Sendable () async throws -> String) { // `@Sendable` because it enters `Task`.
        guard !isRunning else { return } // If a demo is already running, ignore the tap — avoids confusing interleaved logs.
        isRunning = true // Mark running — paired with `false` in `defer` inside the `Task` for reliable cleanup semantics.
        Task { @MainActor in // Still MainActor — explicit annotation helps readers who skim for `@MainActor` discipline.
            defer { isRunning = false } // Always clear running flag — even if `work()` throws — prevents “stuck UI” state.
            do { // Separate success vs failure — matches dashboard VM policy: errors become human-readable strings, not crashes.
                output = try await work() // Await demo closure — assign resulting string to `output` for SwiftUI refresh.
            } catch { // Catch any `Error` — includes `URLError`, `CancellationError`, etc. — show localized description text.
                output = "Error: \(error.localizedDescription)" // Enough for labs — production would classify errors carefully.
            } // End `catch` — consider logging `error` to `os.Logger` in real apps — omitted to reduce noise in teaching target.
        } // End `Task` — unstructured task for button tap — inherits MainActor — **not** `Task.detached` (article Part 1).
    } // End `startDemo` — throwing variant — used by most demos that call `URLSession` / `withTimeout` / actor `withdraw`.

    /// Runs a non-throwing async demo — same `isRunning` policy — avoids forcing `try` into demos that don’t need it.
    @MainActor // Same rationale as throwing helper — `@State` mutations belong on the main actor in SwiftUI apps.
    fileprivate func startDemoNonThrowing(_ work: @escaping @Sendable () async -> String) { // `async` only — simpler typing.
        guard !isRunning else { return } // Same guard — prevents overlapping runs — important when demos hit real networks.
        isRunning = true // Same flag flip — symmetry between helpers reduces cognitive load while reading two wrappers.
        Task { @MainActor in // Same `Task` pattern — explicit MainActor — keeps cancellation + UI updates predictable here.
            defer { isRunning = false } // Same cleanup guarantee — symmetry again — teaching code benefits from repetition.
            output = await work() // No `try` — cannot throw — if you later add throws, migrate to `startDemo` for clarity.
        } // End `Task` — still unstructured — still not detached — still tied to app priority unless you change that policy.
    } // End `startDemoNonThrowing` — used for purely local async work like counting stream values / best-effort summaries.
} // End extension — keeping helpers `fileprivate` avoids polluting the module’s API surface with demo-only utilities.
