//
//  DashboardService.swift
//  DashboardConcurrencyDemo/Services
//
//  Implements Part 1 (cooperative cancellation), Part 6 (`async let` fan-out), and Part 7
//  (`TaskGroup`, bounded chunking) from `medium-swift6-concurrency.md`.
//

import Foundation // Networking (`URLSession`), `URL`, errors, and `Task` APIs.

/// Non-`@MainActor` service — network-shaped work should not pin the UI lane (article Part 2 / Part 8).
struct DashboardService: Sendable { // `Sendable` struct with only `Sendable` state — safe to share across tasks.
    /// Placeholder session — using `.shared` keeps the demo small; production apps often inject a configured session.
    private let session: URLSession // Stored so you could swap in an ephemeral configuration for tests later.

    /// Primary initializer — default argument uses the shared session for convenience in previews and demos.
    init(session: URLSession = .shared) { // `= .shared` means call sites can omit the parameter most of the time.
        self.session = session // Assign into immutable storage — `URLSession` is `Sendable` in modern SDKs.
    } // End `init` — keep services easy to construct on any executor.

    /// Article Part 1 — sequential downloads with explicit cancellation checks between iterations.
    func downloadMany(urls: [URL]) async throws -> [Data] { // Kept on the service so it doesn’t pin `MainActor` (Part 2).
        var result: [Data] = [] // Local accumulator — safe because this function runs outside UI isolation by default.
        for url in urls { // Sequential pattern — cancellation responsive without unbounded parallelism risks.
            try Task.checkCancellation() // Poll cancellation flag between network calls — cheap vs waiting on I/O.
            let (data, _) = try await session.data(from: url) // Uses the injected session — same policy as thumbnails.
            result.append(data) // Append each successful payload — `Data` is a `Sendable` value suitable for crossing.
        } // End `for` — contrast with `TaskGroup` when latency should drop via parallel fetches (Part 7).
        return result // Caller receives an independent array — no shared mutable buffer behind the scenes.
    } // End `downloadMany` — mirrors the article’s `downloadMany(urls:)` snippet almost verbatim.

    /// Loads the dashboard snapshot using **structured** parallel fetches (`async let`) — article Part 6.
    func loadSnapshot() async throws -> DashboardSnapshot { // `throws` aggregates child errors from parallel work.
        try Task.checkCancellation() // Cooperative cancellation *before* starting four child operations (Part 1).

        async let profile = fetchProfile() // Child task 1 — begins immediately, runs concurrently with siblings.
        async let settings = fetchSettings() // Child task 2 — same parent task hierarchy as the others.
        async let flags = fetchFlags() // Child task 3 — still tied to the caller’s cancellation scope.
        async let recs = fetchRecommendations() // Child task 4 — completes independently unless it throws.

        return try await DashboardSnapshot( // `try await` waits for *all* children — first thrown error cancels rest.
            profile: profile, // Each binding name refers to the child task’s future result — not a plain value yet.
            settings: settings, // `await` on the initializer arguments is implicit via `try await` on the whole call.
            flags: flags, // If any child throws, this initializer expression fails fast (typical dashboard semantics).
            recommendations: recs // Recommendations array becomes part of the immutable snapshot for the UI.
        ) // End `DashboardSnapshot` construction — all fields are `Sendable` value types crossing back to UI VM.
    } // End `loadSnapshot` — remember: starting `async let` without awaiting is a compiler error in well-formed code.

    /// Demonstrates `withThrowingTaskGroup` for **dynamic N** — article Part 7 (first snippet).
    func fetchRecommendationsDetails(ids: [String]) async throws -> [RecommendationDTO] { // Order may differ!
        try await withThrowingTaskGroup(of: RecommendationDTO.self) { group in // Child type is each row DTO.
            for id in ids { // Loop adds one child task per id — count is only known at runtime.
                group.addTask { // Each child inherits cancellation/priority from the parent task hierarchy.
                    try await Self.fetchRecommendation(id: id) // `static` helper below — keeps closure `@Sendable`-friendly.
                } // End `addTask` closure — runs concurrently with siblings until `await` drains the group.
            } // End `for` — group now has N pending child tasks (unless `ids` is empty).

            var items: [RecommendationDTO] = [] // Accumulator — rebuilt locally; not shared across tasks unsafely.
            for try await item in group { // As children finish, their results arrive here (order not guaranteed).
                items.append(item) // Append each successful DTO — if any child throws, this loop throws and ends.
            } // End `for try await` — draining the group waits for all children unless an error short-circuits.
            return items // Return the collected successes — may be empty if `ids` was empty.
        } // End `withThrowingTaskGroup` — structured scope ensures child tasks are torn down on scope exit.
    } // End `fetchRecommendationsDetails` — contrast with `bestEffortLoad` in `AdvancedPatterns.swift`.

    /// Bounded parallel thumbnail fetch — article Part 7 “don’t launch unbounded concurrent work” guidance.
    func fetchAllThumbnailsBounded(ids: [String], maxConcurrent: Int = 4) async throws -> [Data] { // Returns bytes only.
        var all: [Data] = [] // Master accumulator across sequential batches — bounds peak concurrency via batching.
        for batch in Self.chunks(ids, size: maxConcurrent) { // Outer loop runs batches serially — inner group parallel.
            try Task.checkCancellation() // Check between batches so navigation away stops future network storms (Part 1).

            let batchResult = try await withThrowingTaskGroup(of: Data.self) { group in // Inner group per batch.
                for id in batch { // At most `maxConcurrent` ids per batch by construction of `chunks`.
                    group.addTask { // Each task downloads one thumbnail — parallelism capped by batch size.
                        try await self.fetchThumbnail(id: id) // Uses injected `session` — keeps networking configurable.
                    } // End `addTask`.
                } // End inner `for`.

                var partial: [Data] = [] // Collect bytes for this batch — order may not match input order.
                for try await data in group { // Drain the batch — waits until all tasks in this batch complete/throw.
                    partial.append(data) // Append each `Data` blob — `Data` is `Sendable`.
                } // End inner drain loop.
                return partial // Return this batch’s results upward to be concatenated into `all`.
            } // End inner `withThrowingTaskGroup`.

            all.append(contentsOf: batchResult) // Concatenate stable batches — memory still bounded by batch size.
        } // End outer `for` — each batch completes before the next begins — controls resource usage on cellular.
        return all // Full flattened sequence of bytes — UI would normally pair ids back via zip in real apps.
    } // End `fetchAllThumbnailsBounded`.

    /// Splits an array into equally sized chunks except possibly the last chunk — article’s `chunks` helper.
    static func chunks<T>(_ items: [T], size: Int) -> [[T]] { // `T` is generic — reusable for ids, URLs, etc.
        guard size > 0 else { return [items] } // Defensive guard — invalid chunk size would otherwise infinite-loop.
        return stride(from: 0, to: items.count, by: size).map { start in // `stride` yields chunk start indices.
            Array(items[start..<min(start + size, items.count)]) // Slice each chunk — copy into a new `Array` instance.
        } // End `map` — result is `[[T]]` — each inner array has at most `size` elements.
    } // End `chunks`.

    // MARK: - Mock “network” methods (deterministic, fast, cancellation-friendly)

    /// Mock profile fetch — replaces a real `/profile` endpoint for teaching builds.
    func fetchProfile() async throws -> ProfileDTO { // `async throws` matches real URL loading shape.
        try await Task.sleep(for: .milliseconds(120)) // Artificial latency — lets you watch parallel fan-out in UI.
        try Task.checkCancellation() // Explicit cancellation check after suspension point (Part 1 deep dive).
        return ProfileDTO(id: "1", displayName: "Taylor") // Same sample values as the Medium article’s snippet.
    } // End `fetchProfile`.

    /// Mock settings fetch — mirrors the article’s `SettingsDTO` example payload.
    func fetchSettings() async throws -> SettingsDTO { // Still `throws` for uniform error handling in `loadSnapshot`.
        try await Task.sleep(for: .milliseconds(90)) // Slightly different delay — proves tasks truly overlap in time.
        try Task.checkCancellation() // Poll cancellation again — cheap compared to a giant JSON decode.
        return SettingsDTO(prefersReducedMotion: false) // Static mock — real app would decode server JSON here.
    } // End `fetchSettings`.

    /// Mock flags fetch — mirrors the article’s `FlagsDTO` example payload.
    func fetchFlags() async throws -> FlagsDTO { // Remote config style — still mocked for offline-friendly demos.
        try await Task.sleep(for: .milliseconds(70)) // Short sleep — cancellation should still be testable quickly.
        try Task.checkCancellation() // If cancelled, `loadSnapshot` fails and the view model maps to `.failed` or idle.
        return FlagsDTO(enableNewDashboard: true) // Feature on — lets UI show a “new dashboard” banner if desired.
    } // End `fetchFlags`.

    /// Mock recommendations list — includes stable `picsum.photos` URLs so `AvatarRepository` has real HTTP to do.
    func fetchRecommendations() async throws -> [RecommendationDTO] { // Returns an array — dynamic count story.
        try await Task.sleep(for: .milliseconds(100)) // Small delay — competes concurrently with other `async let`s.
        try Task.checkCancellation() // Cooperative cancellation — mirrors long-loop guidance from the article.
        return [ // Static list — in production this would decode JSON into `[RecommendationDTO]`.
            RecommendationDTO( // Row 1 — initializer from `DashboardModels.swift` extension supplies avatar URL.
                id: "r1", // Identifier used later by Part 7 demos (`fetchRecommendationsDetails`, thumbnails).
                title: "Structured concurrency patterns", // Title copied from the article’s sample recommendations.
                avatarURL: URL(string: "https://picsum.photos/seed/r1/128/128") // Deterministic image for the id.
            ), // End element 1.
            RecommendationDTO( // Row 2 — second recommendation from the article’s sample list.
                id: "r2", // Second id — useful when demonstrating bounded thumbnail fan-out with two URLs.
                title: "Actor isolation pitfalls", // Second title — matches the article’s teaching narrative.
                avatarURL: URL(string: "https://picsum.photos/seed/r2/128/128") // Distinct seed → distinct image bytes.
            ), // End element 2.
        ] // End array literal — `avatarURL` is optional; these rows choose to always include a URL for demos.
    } // End `fetchRecommendations`.

    /// Mock per-id recommendation detail — stands in for “hydrate this id from the network” APIs (article note).
    static func fetchRecommendation(id: String) async throws -> RecommendationDTO { // `static` avoids capturing `self`.
        try await Task.sleep(for: .milliseconds(40)) // Tiny per-item latency — shows group parallelism when N grows.
        try Task.checkCancellation() // Per-child cancellation awareness — important when N is large.
        return RecommendationDTO( // Synthesize a row — real apps might decode nested JSON fields per id.
            id: id, // Echo the requested id — stabilizes UI identity when merging hydrated rows into a list.
            title: "Details for \(id)", // Fake title — demonstrates per-task computation based on runtime input.
            avatarURL: URL(string: "https://picsum.photos/seed/\(id)/128/128") // Stable image per id for avatar demos.
        ) // End DTO construction.
    } // End `fetchRecommendation`.

    /// Mock thumbnail download — uses the service’s `session` so tests can inject an `URLProtocol` mock later.
    func fetchThumbnail(id: String) async throws -> Data { // Instance method — reads `session` without global singletons.
        guard let url = URL(string: "https://picsum.photos/seed/\(id)/64/64") else { // Build a small deterministic URL.
            throw URLError(.badURL) // If `URL` construction fails, surface a `URLError` — keeps `throws` honest.
        } // End `guard` — string templates with ids should always succeed here, but `URL` initializer is failable.

        let (data, _) = try await session.data(from: url) // Real HTTP — requires network in simulator/device for bytes.
        return data // On success, return bytes — caller may decode into `UIImage` off the main actor if desired.
    } // End `fetchThumbnail` — bounded fan-out wrapper above ensures you don’t spawn thousands of these at once.
} // End `DashboardService`.
