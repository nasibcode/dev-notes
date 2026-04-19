# Swift 6 Concurrency on iOS: From async/await to Strict Isolation (A Practical Guide)

*MainActor, custom global actors, actors, `Sendable`, and structured concurrency—explained from beginner to advanced, with real app-shaped examples.*

> **Who this is for**
>
> - You write iOS apps (SwiftUI or UIKit) and you’re using Swift concurrency day-to-day.
> - You’re adopting **Swift 6 strict concurrency checking**, or you’re already seeing `Sendable` / actor-isolation warnings.
> - You want a clear beginner → advanced path, plus practical patterns you can apply immediately.

> **Tested with**
>
> - Swift **6.x** with **Swift 6 language mode** (or stricter), and a **recent Xcode + iOS SDK**—Apple continues to tighten UIKit/SwiftUI concurrency annotations across SDK releases, so treat dates as approximate and verify in your toolchain.
> - UIKit: Apple’s API reference declares [`UIViewController`](https://developer.apple.com/documentation/uikit/uiviewcontroller) as **`@MainActor`**, so typical lifecycle overrides run on the main actor unless you opt out with something like `nonisolated`.
> - Always cross-check with [Swift.org Concurrency docs](https://www.swift.org/documentation/concurrency/), Apple’s *The Swift Programming Language* (Concurrency chapter), and the UIKit symbol docs for the SDK you ship against.

---

## Overview

Swift 6 strict concurrency targets **data races**: unsynchronized access to the same mutable state from more than one concurrent context. The model gives you **isolation** (actors, global actors, MainActor) and **`Sendable` boundaries** so values moved across tasks stay safe.

This article uses one continuous **Dashboard** story: loading profile, settings, feature flags, recommendations, and avatar thumbnails with caching. Each part adds one layer; later sections assume earlier ideas.

**Quick reference**

| Topic | Rule of thumb |
|--------|----------------|
| `@MainActor` | UI and UI-bound state only; keep decode, CPU work, and disk I/O off the main actor. |
| `actor` | One serial executor per instance; keep mutable state inside; don’t leak live mutable references. |
| `@globalActor` | One shared lane for a subsystem—powerful, but a choke point; don’t park unrelated work there. |
| `Sendable` | Prefer immutable value types at boundaries; `@unchecked Sendable` only with a real safety story. |
| Structured concurrency | `async let` for a fixed set of parallel calls; `TaskGroup` when *N* is dynamic; `Task {}` to bridge from sync; avoid `Task.detached` unless you intend to drop parent cancellation and actor context. |
| Cancellation | Cooperative—use cancel-aware APIs, `Task.checkCancellation()` in loops, and cancel work when the screen goes away. |

**How to read the examples:** Code is shown in a particular shape so the **compiler can check** actor isolation and `Sendable` rules, and so **runtime behavior** (cancellation, main-thread UI updates) stays predictable. Throughout the parts below, short notes explain **why** that pattern is used and **what advantage** it buys you in a real app—so you can adapt the ideas without copying blindly.

---

### Part 0 — Mental model (and why Swift 6 is strict)

- A **data race** is unsynchronized access to the same mutable state from multiple concurrent contexts (at least one write). These bugs can be rare and flaky.
- A **thread** is an OS execution concept; an **actor** is a language-level isolation domain with a serial executor. Code often “hops” executors at `await`—that’s normal.

**Red flags everywhere in concurrent code:** heavy work on MainActor, unbounded `TaskGroup` fan-out, locks held across `await`, `@unchecked Sendable` without justification, and actor methods that suspend halfway through an invariant.

We’ll build: **Dashboard** loading profile, settings, flags, a list of recommended items, and cached avatar thumbnails.

**Summary:** Strict checking is not pedantry—it turns “maybe racy” code into **compile-time errors** so you fix boundaries before users hit flaky crashes. The Dashboard thread ties every later section to the same mental model: *who owns state, and which task is allowed to touch it?*

---

### Part 1 — Foundations: tasks, suspension, cancellation

**Structured vs unstructured tasks**

- Prefer **structured** concurrency: child tasks live and die with the parent.
- Use unstructured `Task {}` when bridging from sync (buttons, delegates).
- Use `Task.detached` rarely—it severs parent/child relationships, including cancellation and priority, and easily breaks MainActor context.

**Why it matters:** When child tasks are tied to a parent, **cancellation and errors propagate in one direction**—if the user leaves the screen, you cancel once and the whole subtree stops. `Task.detached` opts out of that tree, so you lose those guarantees unless you rebuild them by hand. **Advantage of staying structured:** less orphaned work, fewer “UI updated after dealloc” bugs, and priority/cancellation behavior that matches user expectations.

**Wrong pattern:** using `Task.detached` for routine UI-driven work.

```swift
@MainActor
func refresh(api: API) {
    Task.detached {
        let data = try await api.fetchDashboard()
        self.render(data) // UI update from a detached task — wrong
    }
}
```

**Why the detached version is wrong:** `Task.detached` runs in a fresh context, so it is **not** guaranteed to inherit the caller’s actor isolation. Updating `self` from there fights the MainActor rules and makes it easy to touch UI off the main thread. **Better approach:** use `Task { }` (inherits context from the creation site) or call async APIs from an already-`@MainActor` method so UI updates stay on the main actor.

**Cancellable screen load**

In SwiftUI, start work in `.task`—it’s cancelled when the view disappears.

**Why `.task`:** It binds the async work’s lifetime to the **view’s lifetime**. When the view leaves the hierarchy, SwiftUI cancels the task—no extra plumbing. **Advantage:** you get automatic teardown for navigation and tab switches, which is exactly when you want to stop network and decoding work.

```swift
import SwiftUI
import Observation

struct DashboardView: View {
    @State private var vm = DashboardViewModel()

    var body: some View {
        content
            .task { await vm.load() }
    }
}
```

**SwiftUI + Observation:** With an `@Observable` class, use **`@State`** to hold the view model; SwiftUI tracks changes to its properties without `ObservableObject` or `@StateObject`.

In UIKit, own a `Task` and cancel when the view controller’s content should stop loading (usually when the screen is going away).

**UIKit + MainActor (current docs):** [`UIViewController`](https://developer.apple.com/documentation/uikit/uiviewcontroller) is annotated **`@MainActor`**. A `Task { … }` created from `viewDidLoad`, `viewIsAppearing`, or other main-actor lifecycle methods **inherits that main actor context**, so `await` does not move UI updates off the main actor the way `Task.detached` would.

```swift
final class DashboardViewController: UIViewController {
    private var loadTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        loadTask = Task { [weak self] in
            await self?.loadDashboard()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func loadDashboard() async {
        // Same async load you would trigger from a view model / coordinator.
    }
}
```

If your load depends on **accurate view geometry or trait collections**, Apple recommends doing that work from [`viewIsAppearing(_:)`](https://developer.apple.com/documentation/uikit/uiviewcontroller/viewisappearing(_:)) rather than `viewWillAppear`; the **`Task` + cancel** pattern stays the same—only the callback you start from changes.

**Why UIKit stores a `Task`:** There is no SwiftUI-style `.task` modifier, so you **own** the handle and cancellation policy. Cancelling from a **disappear** callback mirrors SwiftUI’s “work tied to visibility” idea: **advantage**—in-flight loads stop when the user navigates away, so you waste less work and avoid applying results after teardown.

**Lifecycle nuance (worth reading once):** `viewWillDisappear` also runs when another screen **covers** yours (for example a full-screen modal). If that incorrectly cancels background prefetch, gate cancellation with flags or checks such as `isMovingFromParent`, `isBeingDismissed`, or your navigation stack state—or cancel from a coordinator that knows the real “user left this feature” moment. Apple’s overview discusses pairing work started in `will` callbacks with the matching `did` / opposite `will` transitions; see [`viewIsAppearing(_:)`](https://developer.apple.com/documentation/uikit/uiviewcontroller/viewisappearing(_:)) and related lifecycle topics in the same `UIViewController` documentation.

**About `deinit`:** Calling `loadTask?.cancel()` there is synchronous and sometimes used as a backstop, but **`deinit` can run later than you think**, so prefer explicit lifecycle cancellation for predictable behavior under Swift 6’s stricter isolation story.

**Cancellation is cooperative**—it doesn’t stop your code by itself. Use cancel-aware APIs and/or `try Task.checkCancellation()` / `Task.isCancelled` in loops.

**Why cooperative cancellation:** `cancel()` only sets a flag; your code must **observe** it between steps. **Advantage:** you can stop *before* the next expensive call (or exit a long loop) instead of relying on force-kill semantics that don’t exist in Swift tasks. Checking in a `for` loop is the standard way to keep downloads and batch work responsive to navigation.

```swift
func downloadMany(urls: [URL]) async throws -> [Data] {
    var result: [Data] = []
    for url in urls {
        try Task.checkCancellation()
        let (data, _) = try await URLSession.shared.data(from: url)
        result.append(data)
    }
    return result
}
```

```swift
loadTask?.cancel()

try Task.checkCancellation()

do {
    let snapshot = try await service.loadSnapshot()
    // use snapshot
} catch is CancellationError {
    // expected when user navigates away
} catch {
    // show error / retry
}
```

**Summary (Part 1):** Prefer APIs that participate in the **task tree** (`.task`, stored `Task`, structured `async` entry points). Cancel when the screen goes away, and **poll cancellation** in long work. You gain predictable teardown and fewer stray updates after the user has already moved on.

---

### Part 2 — MainActor: UI as a serial domain

If it touches UIKit/SwiftUI or UI-bound state, it belongs on the **main actor**.

**Why `@MainActor` on the view model:** UI frameworks expect mutations on the **main thread**. Marking the type `@MainActor` makes that contract **explicit to the compiler**: any method on `DashboardViewModel` runs on the main executor unless you opt out. With **`@Observable`**, plain stored properties (here `state`) drive SwiftUI updates—no `ObservableObject` / `@Published` boilerplate. **Advantage:** UI reads and mutations stay on the main actor and stay in sync with rendering—no manual `DispatchQueue.main.async` scatter.

```swift
import Observation

@MainActor
@Observable
final class DashboardViewModel {
    enum State {
        case idle
        case loading
        case loaded(DashboardSnapshot)
        case failed(String)
    }

    private(set) var state: State = .idle

    private let service = DashboardService()

    func load() async {
        state = .loading
        do {
            let snapshot = try await service.loadSnapshot()
            state = .loaded(snapshot)
        } catch {
            state = .failed(String(describing: error))
        }
    }
}
```

`load()` is `async` so it can **await** the service without blocking the thread—but the view model itself stays on MainActor, so assigning `state` after the await remains a safe UI update.

**Don’t do heavy work on MainActor:** large JSON decode, image resize, disk I/O. Do that work in a nonisolated service or actor, return a **`Sendable` snapshot**, then assign UI state on MainActor.

**Why move work off MainActor:** The main executor also drives **layout and animations**. CPU-heavy or I/O-heavy work there competes with frames and causes hitches. **Advantage of a service + snapshot:** decoding and networking run where they can’t starve scrolling; you only hop to MainActor to **commit** a small, ready-to-render model.

```swift
struct DashboardSnapshot: Sendable {
    let profile: ProfileDTO
    let settings: SettingsDTO
    let flags: FlagsDTO
    let recommendations: [RecommendationDTO]
}
```

`DashboardSnapshot` is a **value type** marked `Sendable` so it can cross from background/async work into the MainActor-bound view model **without** the compiler complaining about shared mutable state.

**Practical split:** isolate the view model with `@MainActor`; from elsewhere, `await MainActor.run { }` for UI writes.

```swift
import Observation

@MainActor
@Observable
final class MyViewModel {
    private(set) var title = ""

    func setTitle(_ t: String) {
        title = t
    }
}
```

**Summary (Part 2):** MainActor is your **single-writer lane for UI**. Keep it for **state and UI calls**, not for bulk work. You gain smoother scrolling and simpler reasoning: “if it’s in the view model, it’s main-thread safe.”

---

### Part 3 — Global actors: subsystem-wide serial access

An `actor` isolates per-instance state. A **global actor** isolates a whole subsystem behind one shared executor. Use it when you have a shared resource (preferences, a cache directory, DB access) and want **one** serialized lane app-wide.

**Why not a plain class with `DispatchQueue`:** A global actor gives you the **same await-based isolation** as other Swift concurrency features—the compiler enforces crossings. **Advantage:** call sites show `await` when changing subsystems, which documents contention and prevents “forgot to dispatch to the queue” mistakes.

```swift
@globalActor
enum PreferencesActor {
    actor ActorType {}
    static let shared = ActorType()
}

@PreferencesActor
final class PreferencesStore {
    private let defaults: UserDefaults = .standard

    func setLastSeenDashboardVersion(_ v: Int) {
        defaults.set(v, forKey: "lastSeenDashboardVersion")
    }

    func lastSeenDashboardVersion() -> Int {
        defaults.integer(forKey: "lastSeenDashboardVersion")
    }
}
```

Callers must `await` when crossing isolation; you can reason “preferences code runs on `PreferencesActor`.”

**Trade-off:** One global lane means **everything** on that actor serializes together—good for safety around a shared resource, bad if you pile unrelated slow work onto it. **Avoid** marking unrelated types with the same global actor just to serialize random work—that creates an artificial bottleneck. If you only need per-instance serialization, use an instance `actor` instead.

**Summary (Part 3):** Use a global actor when the **subsystem** truly shares one resource and one ordering story. You gain enforced boundaries and clear mental ownership; you pay **throughput** if you misuse the lane for unrelated tasks.

---

### Part 4 — Actors: shared mutable state (and reentrancy)

Actors serialize access to mutable state.

**Why an `actor` for a cache:** Multiple screens or tasks might request avatars at once. A class plus manual locking works, but an actor makes **exclusive access** the default and pushes callers through `await`, which surfaces contention in the type system. **Advantage:** fewer forgotten lock paths, and cache mutations stay in one place the compiler can reason about.

```swift
actor AvatarCache {
    private var inMemory: [URL: Data] = [:]

    func cachedAvatar(for url: URL) -> Data? {
        inMemory[url]
    }

    func insert(_ data: Data, for url: URL) {
        inMemory[url] = data
    }
}
```

**Reentrancy:** if an actor method hits `await`, it can suspend and other work can run on that actor before it resumes—serialized, but your *logical* invariants might still break if you assumed “nothing else runs until I return.”

**Why this surprises people:** Actor isolation prevents two functions from mutating stored properties **at the same time**, but it does **not** mean your multi-step *algorithm* runs atomically across an `await`. **Advantage of knowing this:** you design “decide and mutate” steps without suspension in the middle, and push networking/analytics to **after** the critical section.

**Wrong pattern:** updating state, then `await`, then assuming nothing changed.

```swift
actor BankAccount {
    private var balance: Int = 0

    func withdraw(_ amount: Int) async throws {
        guard amount > 0 else { return }
        guard balance >= amount else { throw NSError(domain: "InsufficientFunds", code: 1) }
        balance -= amount
        try await Task.sleep(nanoseconds: 10_000_000) // other withdrawals can interleave here
    }
}
```

**Better:** keep invariant updates in non-suspending actor methods; do async side effects after.

```swift
actor BankAccount {
    private var balance: Int = 0

    func deposit(_ amount: Int) {
        guard amount > 0 else { return }
        balance += amount
    }

    func withdraw(_ amount: Int) throws {
        guard amount > 0 else { return }
        guard balance >= amount else { throw NSError(domain: "InsufficientFunds", code: 1) }
        balance -= amount
    }
}

func withdrawAndNotify(account: BankAccount, amount: Int) async {
    do {
        try account.withdraw(amount)
        // await analytics, network, etc. after the atomic mutation
    } catch { }
}
```

The synchronous `withdraw` completes the balance change **before** any suspension, so no other actor call can observe a half-finished withdrawal.

**Avatar fetch (safe shape):** network outside cache mutations so you don’t hold invariants across unrelated `await`s.

```swift
struct AvatarResult: Sendable {
    let url: URL
    let data: Data
}

actor AvatarRepository {
    private let cache = AvatarCache()

    func avatar(for url: URL) async throws -> AvatarResult {
        if let cached = await cache.cachedAvatar(for: url) {
            return AvatarResult(url: url, data: cached)
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        await cache.insert(data, for: url)
        return AvatarResult(url: url, data: data)
    }
}
```

**Why this order:** Fetch from the network **before** `await cache.insert`—the slow `URLSession` await is not sandwiched inside a half-updated cache invariant. **Advantage:** simpler reasoning and fewer reentrancy footguns in real caches that also touch disk or eviction logic.

**Don’t leak mutable internals** from an actor (e.g. returning a shared mutable box). Expose async methods or value snapshots only.

**Summary (Part 4):** Actors give **serial access** to mutable state; reentrancy means you still design **short critical sections**. For shared caches, keep mutations in the actor and pass **`Sendable` results** outward.

---

### Part 5 — `Sendable`: safe boundaries (Swift 6 strict checking)

Pass **immutable value types** across concurrency boundaries when you can.

**Why `Sendable` on DTOs:** Under Swift 6, values that cross tasks/actors must be provably safe to share. Immutable structs with `Sendable` **document** that contract and satisfy the checker. **Advantage:** the compiler catches accidental use of a non-Sendable reference type across boundaries, which is where data races often start.

```swift
struct ProfileDTO: Decodable, Sendable {
    let id: String
    let displayName: String
}

struct SettingsDTO: Decodable, Sendable {
    let prefersReducedMotion: Bool
}

struct FlagsDTO: Decodable, Sendable {
    let enableNewDashboard: Bool
}

struct RecommendationDTO: Decodable, Sendable {
    let id: String
    let title: String
}
```

`@unchecked Sendable` is a manual promise—require a real synchronization story in review.

If you depend on legacy modules without concurrency annotations, `@preconcurrency import` can be a migration bridge, not a permanent excuse to ignore boundaries.

**Summary (Part 5):** Treat boundaries like **message passing**: send **copies** (`struct` DTOs), not shared mutable objects. You gain compile-time checking today and safer refactors tomorrow.

---

### Part 6 — `async let`: fixed parallel work (dashboard fan-out)

Use `async let` when the number of parallel operations is fixed and independent.

**Why `async let` here:** Profile, settings, flags, and recommendations are **independent** requests. Starting them with `async let` runs them **concurrently** up to the await that combines them. **Advantage:** lower wall-clock time than four sequential `await`s, without the boilerplate of a task group for a fixed, known count.

```swift
struct DashboardService {
    func loadSnapshot() async throws -> DashboardSnapshot {
        async let profile = fetchProfile()
        async let settings = fetchSettings()
        async let flags = fetchFlags()
        async let recs = fetchRecommendations()

        return try await DashboardSnapshot(
            profile: profile,
            settings: settings,
            flags: flags,
            recommendations: recs
        )
    }

    func fetchProfile() async throws -> ProfileDTO { ProfileDTO(id: "1", displayName: "Taylor") }
    func fetchSettings() async throws -> SettingsDTO { SettingsDTO(prefersReducedMotion: false) }
    func fetchFlags() async throws -> FlagsDTO { FlagsDTO(enableNewDashboard: true) }
    func fetchRecommendations() async throws -> [RecommendationDTO] {
        [
            RecommendationDTO(id: "r1", title: "Structured concurrency patterns"),
            RecommendationDTO(id: "r2", title: "Actor isolation pitfalls"),
        ]
    }
}
```

If you start an `async let`, you should **await** it. Decide what happens when one of the parallel operations fails (`try await` on the combined tuple typically fails fast on the first error—which is often what you want for a single “load dashboard” operation).

**Summary (Part 6):** Use `async let` for **fixed fan-out** of independent async calls. You gain parallelism with **structured** child tasks tied to the same parent scope.

---

### Part 7 — `TaskGroup`: dynamic parallel work (N items)

Use `TaskGroup` when task count depends on runtime data.

**Why not `async let` in a loop:** You cannot write `async let` dynamically for *N* items without knowing *N* at compile time in a fixed form. `withThrowingTaskGroup` (or `withTaskGroup`) exists so you can **add tasks in a loop** and collect results. **Advantage:** one pattern for “one child task per id/url/item” with clear parent/child structure.

```swift
func fetchRecommendationsDetails(ids: [String]) async throws -> [RecommendationDTO] {
    try await withThrowingTaskGroup(of: RecommendationDTO.self) { group in
        for id in ids {
            group.addTask {
                try await fetchRecommendation(id: id)
            }
        }

        var items: [RecommendationDTO] = []
        for try await item in group {
            items.append(item)
        }
        return items
    }
}
```

> `fetchRecommendation(id:)` stands in for your real `async throws` API returning a `Sendable` DTO.

**Bounded parallelism:** for large `ids`, don’t launch unbounded concurrent work—chunk IDs and run each chunk in a group, with `Task.checkCancellation()` between chunks.

```swift
func chunks<T>(_ items: [T], size: Int) -> [[T]] {
    guard size > 0 else { return [items] }
    return stride(from: 0, to: items.count, by: size).map {
        Array(items[$0..<min($0 + size, items.count)])
    }
}

func fetchAllThumbnailsBounded(ids: [String], maxConcurrent: Int = 4) async throws -> [Data] {
    var all: [Data] = []
    for batch in chunks(ids, size: maxConcurrent) {
        try Task.checkCancellation()
        let batchResult = try await withThrowingTaskGroup(of: Data.self) { group in
            for id in batch {
                group.addTask { try await fetchThumbnail(id: id) }
            }
            var partial: [Data] = []
            for try await data in group { partial.append(data) }
            return partial
        }
        all.append(contentsOf: batchResult)
    }
    return all
}
```

Unbounded fan-out can overload the network, hit rate limits, spike memory, and hurt cancellation—same policy applies to any dynamic list (recommendations, thumbnails, assets). Extract `chunks` once and reuse.

**Summary (Part 7):** Use `TaskGroup` for **dynamic N**; add **chunking** when N can be large. You gain controlled resource use, better behavior on cellular networks, and cancellation that stops future batches instead of already-queued storms.

---

### Part 8 — Putting it together (architecture)

This is the **layering** the previous parts were building toward:

- `@MainActor` **DashboardViewModel** owns UI state—one `@Observable` type for screen fields and logic on the main actor (SwiftUI holds it with `@State`).
- Nonisolated **DashboardService** loads snapshots with `async let` / `TaskGroup`—networking and decoding stay off the UI lane but still run inside structured tasks you can cancel.
- Shared mutable caches sit behind **actors**—a single serial writer for cache state.
- Subsystem-wide serialized access uses **global actors** when justified—for example one app-wide preferences lane.
- Data crossing boundaries is **`Sendable` DTOs**—messages between layers are **values**, not shared mutable objects.

**Why this split matters:** Each layer has **one job** and explicit **crossing points** (`await`, `Sendable` types). **Advantage:** Swift 6 checking stays tractable, you can test services and actors without the full UI stack, and you can swap storage implementations without rewriting the view model.

---

## Advanced edge cases (production patterns)

These sections cover patterns that show up in real codebases but need a **sharp rule**: bridging legacy callbacks, cleaning up subscriptions, and avoiding deadlocks when mixing locks with `await`.

### Bridging callbacks: continuations

`withCheckedThrowingContinuation` adapts callback APIs to `async`/`await`. You must **resume exactly once** (twice is a bug; zero times hangs).

**Why:** Legacy code invokes you on an arbitrary queue; the continuation **bridges** that into structured `async`/`await`. **Advantage:** you compose the same as first-class async APIs. The single-resume rule matches a well-formed callback: exactly one success or failure path.

```swift
func fetchThing(_ api: LegacyAPI) async throws -> Thing {
    try await withCheckedThrowingContinuation { cont in
        api.fetch { result in cont.resume(with: result) }
        // cont.resume(throwing: ...) here as well — wrong: double resume
    }
}
```

### `AsyncStream` and cleanup

`AsyncStream` turns push-style events into `for await`. Use `onTermination` to unsubscribe and avoid leaks.

**Why:** NotificationCenter, KVO, and many SDKs are **callback-driven**; `AsyncStream` gives you a **pull** interface that composes with `for await` and task cancellation. **Advantage:** `onTermination` ties stream lifetime to consumer lifetime—you remove observers when the task stops listening, avoiding leaks and duplicate callbacks.

```swift
func notifications() -> AsyncStream<String> {
    AsyncStream { continuation in
        let token = NotificationCenter.default.addObserver(
            forName: .init("Ping"), object: nil, queue: nil
        ) { _ in
            continuation.yield("ping")
        }

        continuation.onTermination = { _ in
            NotificationCenter.default.removeObserver(token)
            continuation.finish()
        }
    }
}
```

### Cancellation propagation + cleanup (`withTaskCancellationHandler`)

When a Swift task cancels but legacy code keeps running, cancel the legacy work in `onCancel`.

**Why:** `Task.cancel()` does not automatically call `URLSessionTask.cancel()` or your vendor SDK’s cancel—you wire that up. **Advantage:** when the user navigates away, **both** Swift’s cooperative cancellation and the legacy request stop, so you don’t waste bandwidth or resume continuations after nobody cares.

```swift
func fetchCancellable(_ api: LegacyAPI) async throws -> Data {
    let request = api.makeRequest()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
            request.start { result in
                cont.resume(with: result)
            }
        }
    } onCancel: {
        request.cancel()
    }
}
```

### Never hold locks across `await`

Never `await` while holding `NSLock`, `DispatchQueue.sync`, or semaphores—use actors, or copy data out under the lock then `await`.

**Why:** While you `await`, other code can run—including code that wants the **same** lock → classic deadlock. Swift’s model prefers **actors** for async-safe mutual exclusion. **Advantage:** the compiler models isolation; you don’t hold OS locks across suspension points.

```swift
final class LockedStore {
    private let lock = NSLock()
    private var ids: [Int] = []

    func refresh(api: API) async throws {
        lock.lock()
        defer { lock.unlock() }
        let more = try await api.fetchIDs() // WRONG
        ids.append(contentsOf: more)
    }
}
```

```swift
actor IDStore {
    private var ids: [Int] = []
    func append(contentsOf more: [Int]) { ids.append(contentsOf: more) }
}

func refresh(store: IDStore, api: API) async throws {
    let more = try await api.fetchIDs()
    await store.append(contentsOf: more)
}
```

### Best-effort task groups (partial results)

`withThrowingTaskGroup` fails fast. To collect successes and failures, have children return `Result`.

**Why:** Sometimes you want **all** outcomes (e.g. refresh a grid where some tiles fail). **Advantage:** one group pass yields a full `Result` array; callers decide whether to show partial data, retry failures, or surface errors per item.

```swift
func bestEffortLoad(ids: [Int], api: API) async -> [Result<ItemDTO, Error>] {
    await withTaskGroup(of: Result<ItemDTO, Error>.self) { group in
        for id in ids {
            group.addTask {
                do { return .success(try await api.fetchItem(id: id)) }
                catch { return .failure(error) }
            }
        }
        var results: [Result<ItemDTO, Error>] = []
        for await r in group { results.append(r) }
        return results
    }
}
```

### Async sequence buffering

**Why `bufferingNewest(1)`:** Fast producers and slow consumers can otherwise grow an **unbounded** buffer and spike memory. Keeping only the latest value fits “current state” streams (location, progress). **Advantage:** bounded memory and UI that reflects the newest value, not a backlog.

```swift
func latestOnlyStream() -> AsyncStream<Int> {
    AsyncStream(Int.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
        for i in 0..<10_000 { continuation.yield(i) }
        continuation.finish()
    }
}
```

### Timeout (race work vs sleep)

**Why a task group:** You race the real operation against a sleep that throws `CancellationError` (or a custom timeout error), then **cancel the rest** when one finishes first. **Advantage:** callers get a single `async throws` API with a time bound—useful for flaky networks when paired with sensible UX.

```swift
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
```

---

## Resources

- Swift.org — Concurrency: https://www.swift.org/documentation/concurrency/
- Apple — *The Swift Programming Language*: Concurrency chapter
- Apple — [`UIViewController`](https://developer.apple.com/documentation/uikit/uiviewcontroller) (UIKit API reference; includes `@MainActor` declaration)
- Apple — [Adopting Swift concurrency](https://developer.apple.com/tutorials/app-dev-training/adopting-swift-concurrency) (UIKit / app lifecycle–oriented tutorial)
- WWDC: https://developer.apple.com/videos/ (search “Swift Concurrency”, “Swift 6”, “UIKit”)

---

*Tags for Medium (paste in the story settings):* Swift 6, iOS concurrency, MainActor, actors, global actor, Sendable, async await, TaskGroup, structured concurrency, SwiftUI, UIKit, cancellation
