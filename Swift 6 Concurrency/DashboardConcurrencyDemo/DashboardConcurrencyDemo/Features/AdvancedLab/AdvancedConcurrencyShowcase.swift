//
//  AdvancedConcurrencyShowcase.swift
//  DashboardConcurrencyDemo/Features/AdvancedLab
//
//  Implements the “Advanced edge cases” appendix from `medium-swift6-concurrency.md`:
//  continuations, `AsyncStream` cleanup, Swift cancellation vs legacy cancellation, task-group semantics,
//  stream buffering, and timeouts. Each API is commented line-by-line for teaching reads.
//

import Foundation // `NotificationCenter`, `URLSession`, `URLError`, `Task`, `AsyncStream`, `withTaskGroup`, etc.

/// Notification name used by the `AsyncStream` demo — matches the article’s `"Ping"` string literal approach.
extension Notification.Name { // Extend `Notification.Name` so call sites can use a typed static constant.
    /// Demo ping — posted from UI to prove the stream yields events and then cleans up observers on termination.
    static let demoPing = Notification.Name("Ping") // Under the hood this wraps a `String` name table entry.
} // End extension — keeping demo names centralized avoids typos across producers and consumers.

/// Legacy-style callback client — `Sendable` so it can be captured in `@Sendable` continuation closures safely.
struct LegacyAPIClient: Sendable { // `struct` with no mutable storage — trivially `Sendable` under Swift 6 rules.
    /// Simulates `api.fetch { result in ... }` — completion may run on an arbitrary queue (here: global queue).
    func fetch(completion: @escaping @Sendable (Result<Data, Error>) -> Void) { // `@escaping` because async dispatch.
        DispatchQueue.global().async { // Hop off caller thread — mimics legacy networking callback timing/ordering.
            completion(.success(Data([104, 101, 108, 108, 111]))) // UTF-8 bytes for "hello" — deterministic demo output.
        } // End `async` block — resumes completion exactly once — satisfies “resume once” continuation rule (Appendix 1).
    } // End `fetch` — **Rule:** never call the completion twice — would double-resume a bridged continuation.
} // End `LegacyAPIClient` — in production, you’d wrap real SDK entry points, not toy byte payloads.

/// Bridges callback APIs into `async`/`await` using a checked continuation — Appendix 1 in the Medium article.
func fetchThingBridged(client: LegacyAPIClient) async throws -> Data { // `throws` because `resume(throwing:)` exists.
    try await withCheckedThrowingContinuation { continuation in // Allocates a continuation token tracked by the runtime.
        client.fetch { result in // Start legacy work — synchronous from caller POV until callback fires later.
            continuation.resume(with: result) // **Exactly once** resume — success or failure — never both, never zero.
        } // End `fetch` trailing closure — if you add branches, audit that exactly one `resume` happens on all paths.
    } // End continuation closure — if `fetch` stored the continuation and forgot to call it, you’d hang forever.
} // End `fetchThingBridged` — `withChecked*` traps double-resume in debug builds — use `with*Unsafe` only if required.

/// Boxes an Objective-C observer token so it can cross `@Sendable` boundaries in `onTermination` under Swift 6 rules.
private final class NotificationObserverToken: @unchecked Sendable { // `@unchecked` documents manual lifetime management.
    /// Underlying opaque token returned by `NotificationCenter.addObserver` — not `Sendable` without this wrapper type.
    let raw: NSObjectProtocol // Stored for `removeObserver` — must only be removed once, matching stream termination.
    /// Wraps the token at creation time — keeps `demoNotificationsStream`’s `onTermination` closure `@Sendable`-legal.
    init(_ raw: NSObjectProtocol) { self.raw = raw } // Simple initializer — no logic beyond capturing the token handle.
} // End `NotificationObserverToken` — keep this file-local — don’t generalize `@unchecked Sendable` without review.

/// Demonstrates `AsyncStream` cleanup — Appendix 2: unregister observers when the consumer stops listening.
func demoNotificationsStream() -> AsyncStream<String> { // Returns cold stream — nothing happens until consumer iterates.
    AsyncStream { continuation in // Builder closure runs when consumer starts — sets up producer-side resources.
        let token = NotificationObserverToken( // Wrap token immediately — Swift 6 requires `Sendable` captures in `onTermination`.
            NotificationCenter.default.addObserver( // Register Objective-C style observer — needs removal later.
                forName: .demoPing, // Filter to our demo ping name — avoids unrelated notifications waking the stream.
                object: nil, // Any object sender — fine for a demo; tighten in production to a known `object` identity.
                queue: nil // Deliver on posting thread — stream will hop as needed; for UI, prefer a main queue instead.
            ) { _ in // Observer closure — keep fast; heavy work should move to a dedicated task with backpressure policy.
                continuation.yield("ping") // Push one string event downstream — may buffer depending on stream policy.
            } // End observer closure — retain wrapper so `onTermination` can remove this observer deterministically.
        ) // End `NotificationObserverToken` construction — token now travels into `@Sendable` termination handler safely.

        continuation.onTermination = { _ in // Called when consumer cancels / finishes / deinits iteration context.
            NotificationCenter.default.removeObserver(token.raw) // Unwrap boxed token — prevents leaks after stream ends.
            continuation.finish() // Mark stream completed — future reads end the `for await` loop naturally.
        } // End `onTermination` — **Rule:** unregister KVO/timers/notifications here to avoid “zombie” work (Appendix 2).
    } // End `AsyncStream` builder — without `onTermination`, observer could outlive UI and waste CPU/battery.
} // End `demoNotificationsStream` — pair with `NotificationCenter.default.post(name: .demoPing, ...)` from a button.

/// Minimal legacy holder for a `URLSessionDataTask` — `final class` + `@unchecked Sendable` because task handle
/// is manually synchronized by always touching it from the same serial queue pattern in this tiny demo.
final class LegacyDownloadSession: @unchecked Sendable { // `@unchecked` promises manual safety — keep this type small.
    /// Optional task handle — `URLSession` owns the real object; we only need `cancel()` for cancellation wiring.
    private var task: URLSessionDataTask? // Mutable — not automatically `Sendable` for a class, hence `@unchecked`.
    /// Starts a data task and calls completion exactly once — mirrors vendor SDKs that expose `start`/`cancel`.
    func start(url: URL, completion: @escaping @Sendable (Result<Data, Error>) -> Void) { // Callback API boundary.
        task = URLSession.shared.dataTask(with: url) { data, _, error in // Create system networking task lazily.
            if let error { // Prefer explicit error path — `URLError` / transport errors land here commonly.
                completion(.failure(error)) // Single completion on failure — don’t also call success with empty bytes.
                return // Early return keeps the success path obvious for code review (“one resume” discipline).
            } // End failure branch.
            completion(.success(data ?? Data())) // Treat missing body as empty `Data` — fine for demo, not for prod.
        } // End task completion handler — runs on URLSession’s delegate queue unless configured otherwise.
        task?.resume() // Actually start bytes in flight — without `resume`, continuation would never complete.
    } // End `start` — production would propagate metrics, certificate pinning, retry policies, etc.

    /// Cancels underlying URLSession work — **Rule:** Swift task cancellation doesn’t auto-cancel URLSession (Appendix 3).
    func cancel() { // Synchronous cancel call — safe to invoke from `onCancel` handler in structured cancellation helper.
        task?.cancel() // Marks task cancelled — in-flight completion may still arrive with a cancellation-shaped error.
    } // End `cancel` — pair this with `withTaskCancellationHandler` to unify Swift cancellation with legacy SDK cancel.
} // End `LegacyDownloadSession` — don’t generalize `@unchecked Sendable` beyond tightly controlled demos.

/// Wraps a legacy download with `withTaskCancellationHandler` — Appendix 3 (Swift cancel vs legacy cancel).
func fetchCancellableData(url: URL) async throws -> Data { // `async throws` mirrors `URLSession` failure modes.
    let session = LegacyDownloadSession() // Create per-call session object — avoids cross-task shared mutable state.
    return try await withTaskCancellationHandler { // Registers `onCancel` alongside the awaited async work unit.
        try await withCheckedThrowingContinuation { continuation in // Bridge callback completion to async world again.
            session.start(url: url) { result in // Kick off legacy request — completion must resume continuation once.
                continuation.resume(with: result) // Single resume — if legacy SDK double-completes, you still must guard.
            } // End `start` callback — **Rule:** `Task.cancel()` alone won’t call `URLSessionDataTask.cancel()` for you.
        } // End continuation — if cancelled before start completes, `onCancel` still runs and tears down the task.
    } onCancel: { // Swift concurrency calls this when the structured task hierarchy becomes cancelled.
        session.cancel() // Forward cancellation into URLSession — closes the gap the article calls out explicitly.
    } // End cancellation handler — keep `onCancel` fast — heavy teardown should still avoid blocking unrelated work.
} // End `fetchCancellableData` — production: also consider cooperative timeouts and retry budgets per endpoint.

/// Actor holding ids — Appendix 4 “fix” side: mutate shared state only on the actor after async work completes.
actor IDStore { // Serialized mutable `ids` — prevents races without locks held across `await` (deadlock footgun).
    /// Private backing store — cannot be read/written outside actor methods — compiler-enforced isolation boundary.
    private var ids: [Int] = [] // `Int` elements are `Sendable` — entire array is safe behind the actor executor.
    /// Appends new ids — synchronous actor method — no suspension between reads/writes of `ids` here.
    func append(contentsOf more: [Int]) { // `contentsOf` label matches `Array.append` API style — familiar to readers.
        ids.append(contentsOf: more) // Single mutation — safe against interleaved mutations from other actor calls.
    } // End `append`.

    /// Returns a copy of ids — snapshot escapes as a value — callers can iterate without holding actor across `await`.
    func allIDs() -> [Int] { // Pure read — still requires `await` at call site because it crosses into actor isolation.
        ids // Implicit return — copy of array — value semantics means caller doesn’t share mutable storage with actor.
    } // End `allIDs`.
} // End `IDStore` — **Wrong pattern (described only in comments):** `NSLock` + `await` inside locked section deadlocks.

/// Fake API returning ids — nonisolated service shape — Appendix 4 shows awaiting API first, then actor mutation.
struct IDsAPI: Sendable { // Stateless service — `Sendable` struct fits “call from anywhere, no hidden shared state.”
    /// Pretend network call — returns deterministic ints — no actual sockets required for teaching builds.
    func fetchIDs() async throws -> [Int] { // `async` because real network would suspend; `throws` for parity with life.
        try await Task.sleep(for: .milliseconds(15)) // Tiny delay — makes ordering visible if you log timestamps.
        return [10, 11, 12] // Deterministic “server” ids — easy to assert in tests of `refreshIDsCorrectly` pattern.
    } // End `fetchIDs`.
} // End `IDsAPI` — combine with `IDStore` in UI demos to show “await first, then mutate actor” discipline.

/// Coordinates refresh — Appendix 4’s “fix” snippet: **await** `fetchIDs`, then **await** actor mutation afterward.
func refreshIDsCorrectly(store: IDStore, api: IDsAPI) async throws { // `throws` because `fetchIDs` can fail the flow.
    let more = try await api.fetchIDs() // Suspension happens **before** touching shared mutable store — avoids locks.
    await store.append(contentsOf: more) // Actor hop after async work completes — no lock held across suspension.
} // End `refreshIDsCorrectly` — compare to the article’s `LockedStore` wrong snippet mentally — don’t copy that shape.

/// Tiny DTO for best-effort demo — Appendix 5 uses `ItemDTO` naming; we keep it minimal and `Sendable`.
struct ItemDTO: Sendable, Identifiable { // `Identifiable` optional for SwiftUI grids — included for future reuse.
    let id: Int // Integer identifier — stable across retries in this toy model.
    let title: String // Human-readable label — returned inside `Result.success` for each id in best-effort loads.
} // End `ItemDTO`.

/// Fake API that fails sometimes — makes `Result` per child meaningful in a **non-throwing** task group (Appendix 5).
struct DemoItemsAPI: Sendable { // `Sendable` service — methods are safe to call from concurrent task group children.
    /// Fetches one item — injects synthetic failures so the UI can show both successes and failures in one run.
    func fetchItem(id: Int) async throws -> ItemDTO { // `throws` here, but outer `bestEffortLoad` catches per child.
        try await Task.sleep(for: .milliseconds(8)) // Small per-id delay — enough to interleave under parallelism.
        if id % 5 == 0 { // Deterministic failure pattern — every fifth id “fails” without randomness in CI/screenshots.
            throw URLError(.cannotFindHost) // Stand-in failure — distinguishes per-item errors vs whole-group throw.
        } // End failure injection — keep business logic obvious for readers scanning the file quickly.
        return ItemDTO(id: id, title: "Item \(id)") // Success path — returns a `Sendable` DTO suitable for aggregation.
    } // End `fetchItem`.
} // End `DemoItemsAPI` — **Rule:** throwing task group cancels siblings on first throw — `Result` avoids that (Appendix 5).

/// Loads many ids, returning per-id `Result` — Appendix 5: keep successes even if some children fail.
func bestEffortLoad(ids: [Int], api: DemoItemsAPI) async -> [Result<ItemDTO, Error>] { // Non-throwing outer function.
    await withTaskGroup(of: Result<ItemDTO, Error>.self) { group in // **Non-throwing** group — errors become values.
        for id in ids { // Dynamic N — `TaskGroup` supports runtime-driven fan-out unlike fixed `async let` grids.
            group.addTask { // Each child returns `Result` — internal `try` becomes `.failure`, not a group-thrown error.
                do { // Local `do/catch` keeps each child independent — key difference vs `withThrowingTaskGroup` policy.
                    return .success(try await api.fetchItem(id: id)) // `return` lifts `ItemDTO` into `.success` case.
                } catch { // Catch *per child* — does not cancel siblings — matches “grid thumbnails” guidance in article.
                    return .failure(error) // Wrap failure — consumer can count failures vs successes explicitly.
                } // End `catch`.
            } // End `addTask` closure — must be `@Sendable` — only captures `id` + `api` (`Sendable`) here.
        } // End `for` — all child tasks are queued — scheduler runs them with concurrency, not strict call order.

        var results: [Result<ItemDTO, Error>] = [] // Accumulate end results — order may not match input order here.
        for await r in group { // Drain group until all children complete — `for await` ends when group finishes.
            results.append(r) // Append each finished `Result` — no `try` because `r` itself isn’t throwing.
        } // End drain loop — if you need original ordering, zip with ids or sort by `ItemDTO.id` afterward.
        return results // Full array of successes/failures — UI can render partial grids without losing information.
    } // End `withTaskGroup` — structured scope still waits for children — good cancellation behavior vs unstructured fan-out.
} // End `bestEffortLoad` — pair with UI that renders `.failure` rows differently (not shown — keep demo compact).

/// Timeout helper — Appendix 7: race real work vs sleep; cancel loser to stop background work promptly.
func withTimeout<T: Sendable>( // Generic over `T` — requires `Sendable` so results can cross task boundaries safely.
    seconds: Double, // Fractional seconds — `Task.sleep` uses nanoseconds internally — cast carefully for huge values.
    operation: @Sendable @escaping () async throws -> T // `@Sendable` closure because it becomes a child task body.
) async throws -> T { // `throws` because timeout path throws `CancellationError` in this demo’s chosen policy.
    try await withThrowingTaskGroup(of: T.self) { group in // Child tasks each produce a `T` or throw to end the race.
        group.addTask { try await operation() } // Real workload child — cancellation should propagate if cooperative.
        group.addTask { // Timer child — wins if operation is too slow — uses sleep as a relative time delay primitive.
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) // Convert seconds → ns — overflow risk if huge.
            throw CancellationError() // Treat “timer fired” as cancellation-shaped failure — article’s snippet choice.
        } // End timer child — when cancelled early, sleep wakes with cancellation — good citizen in structured tasks.

        let value = try await group.next()! // Wait for first completed child — force-unwrap OK because group non-empty.
        group.cancelAll() // Cancel remaining children — stops sleep or work — key part of the timeout recipe (Appendix 7).
        return value // Return winner’s value — if timeout won, this is a thrown error propagated out of `withTimeout`.
    } // End group — `cancelAll` ensures no leaked child tasks keep burning CPU/network after decision is made.
} // End `withTimeout` — production might use `Task.sleep(while:)` / dedicated clock types / cooperative deadlines instead.

/// Demonstrates `.bufferingNewest(1)` — Appendix 6: avoid unbounded backlog when producer outpaces consumer.
func latestOnlyStreamDemo() -> AsyncStream<Int> { // Returns a stream — consumer controls how fast values are read.
    AsyncStream(Int.self, bufferingPolicy: .bufferingNewest(1)) { continuation in // Bounded buffer keeps memory stable.
        for i in 0..<200 { // Producer loop — intentionally many values — would backlog without newest(1) policy.
            continuation.yield(i) // If consumer is slow, policy drops older values — only latest survives in buffer.
        } // End `for` — after producer completes, finish the stream so `for await` terminates cleanly.
        continuation.finish() // Mark end-of-stream — pairs with consumer stopping — don’t forget in real producers.
    } // End builder — **Rule:** default buffering can grow without bound — pick policy explicitly for hot producers.
} // End `latestOnlyStreamDemo` — typical use: latest location tick, latest download percent, not full history logs.

/// Namespace for tiny “button demo” entry points used by `AdvancedPatternsView` — keeps SwiftUI file thinner.
enum AdvancedConcurrencyShowcase { // `enum` with no cases — common pattern for grouping `static` helpers cleanly.
    /// Runs continuation bridge — returns UTF-8 bytes from `LegacyAPIClient` through `async` boundary.
    static func continuationBridgeDemo() async throws -> Data { // `throws` because bridging uses throwing continuation.
        try await fetchThingBridged(client: LegacyAPIClient()) // Fresh client each tap — no shared mutable callback state.
    } // End `continuationBridgeDemo`.

    /// Posts one ping and reads one event — proves `onTermination` cleanup path runs when loop ends.
    static func notificationPingDemo() async -> String { // Non-throwing — stream yields strings or ends quietly.
        let stream = demoNotificationsStream() // Create cold stream — installs observer lazily when iterated.
        let poster = Task { // Separate unstructured task — still structured under parent unless detached (it isn’t).
            try? await Task.sleep(for: .milliseconds(30)) // Small delay — gives consumer time to enter `for await`.
            NotificationCenter.default.post(name: .demoPing, object: nil) // Fire demo notification — wakes observer.
        } // End poster task — not awaited here explicitly — `for await` draining stream still bounds overall work.
        var first: String = "no events" // Default string — overwritten if stream yields before finish/cancel.
        for await value in stream { // Consumer loop — terminates when stream finishes or task scope cancels iteration.
            first = value // Capture first yielded string — then break to stop consuming (triggers termination cleanup).
            break // End early — `onTermination` should run — observer removal is the whole point of this demo.
        } // End `for await` — breaking out ends iteration — triggers stream termination handler in many implementations.
        await poster.value // Await poster completion — avoids structured-concurrency “task not awaited” warnings in strict modes.
        return first // Return captured value — UI can show `"ping"` when everything wired correctly.
    } // End `notificationPingDemo`.

    /// Attempts a tiny download with cancellation forwarded into `URLSession` — uses a known-good URL host.
    static func cancellableDownloadDemo() async throws -> Int { // Returns byte count — easy to print in UI logs.
        let url = URL(string: "https://example.com")! // Extremely stable host — good for simple connectivity demos.
        let data = try await fetchCancellableData(url: url) // If caller cancels while in flight, task cancels URLSession too.
        return data.count // Scalar summary — avoids dumping binary into SwiftUI `Text` views unnecessarily.
    } // End `cancellableDownloadDemo` — requires network permission/capability as configured by the app target.

    /// Demonstrates `bestEffortLoad` — returns counts of successes vs failures for quick UI display strings.
    static func bestEffortDemo() async -> (ok: Int, bad: Int) { // Tuple return — no new `struct` type needed for UI.
        let ids = Array(1...12) // 1...12 includes a multiple of 5 → guarantees some `.failure` results in toy API.
        let results = await bestEffortLoad(ids: ids, api: DemoItemsAPI()) // Await group — gathers per-id `Result`s.
        let ok = results.reduce(0) { count, result in // Manual counting — `Result` doesn’t expose `.success` as a `KeyPath` target.
            if case .success = result { return count + 1 } // Increment when child returned `.success(...)` payload wrapper.
            return count // Failures contribute zero to the success tally — keep running total stable across iterations.
        } // End `reduce` — deterministic pass over the array — order doesn’t matter because we only count totals.
        let bad = results.count - ok // Complement counting — every element is either success or failure in this demo API.
        return (ok, bad) // Return tuple — SwiftUI can interpolate `ok`/`bad` without custom formatting types.
    } // End `bestEffortDemo`.

    /// Runs timeout helper where operation finishes quickly — demonstrates “operation wins” branch of race.
    static func timeoutDemo() async throws -> String { // `throws` because `withTimeout` uses throwing group semantics.
        let value = try await withTimeout(seconds: 2) { // Two-second budget — generous for a trivial fast closure.
            "finished" // `String` result — `Sendable` — satisfies generic constraint on `withTimeout` return type.
        } // End operation closure — no sleep here — should beat the timer child easily in normal conditions.
        return "Timeout race winner: \(value)" // Human-readable proof — UI can show string verbatim in `Text`.
    } // End `timeoutDemo`.

    /// Drains the newest-only stream fully — returns last seen int — proves policy doesn’t grow unbounded memory.
    static func latestOnlyDemo() async -> Int { // Async because `for await` consumes asynchronously even if CPU-light.
        let stream = latestOnlyStreamDemo() // Build stream — buffering policy configured at construction time.
        var last = -1 // Sentinel — overwritten at least once because stream yields 0..<200 unless cancelled early.
        for await i in stream { // Consume until finish — with newest(1), internal queue stays small during fast producer.
            last = i // Continuously overwrite — after loop, `last` should be `199` if everything ran to completion.
        } // End `for await` — demonstrates consumer draining — producer already finished inside builder closure earlier.
        return last // Expected `199` in demo — UI can assert/show to validate understanding of buffering policy.
    } // End `latestOnlyDemo`.

    /// Demonstrates `IDStore` refresh — returns joined description string for UI without importing `UIKit`.
    static func idStoreRefreshDemo() async throws -> String { // `throws` because `refreshIDsCorrectly` propagates errors.
        let store = IDStore() // Fresh actor instance — isolated mutable ids without locks held across `await`.
        try await refreshIDsCorrectly(store: store, api: IDsAPI()) // Await refresh — should append `[10,11,12]`.
        let all = await store.allIDs() // Read back snapshot — crosses actor boundary — returns a copy of `[Int]`.
        return all.map(String.init).joined(separator: ",") // Serialize ints for `Text` — simple teaching output format.
    } // End `idStoreRefreshDemo`.
} // End `AdvancedConcurrencyShowcase` — keep adding demos as separate `static` functions to preserve line-by-line clarity.
