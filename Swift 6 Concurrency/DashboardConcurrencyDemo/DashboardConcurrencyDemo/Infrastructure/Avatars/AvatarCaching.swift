//
//  AvatarCaching.swift
//  DashboardConcurrencyDemo/Infrastructure/Avatars
//
//  Implements Part 4: `actor AvatarCache`, `actor AvatarRepository`, and the “safe ordering”
//  pattern (network first, then cache insert) to avoid reentrancy pitfalls across `await`.
//

import Foundation // `URL`, `Data`, and `URLSession` live here.

/// In-memory avatar bytes keyed by remote URL — one serial writer (`actor`) for the dictionary.
actor AvatarCache { // `actor` keyword gives per-instance serialization of all mutating operations.
    /// Mutable dictionary — safe because the actor executor never runs two methods concurrently.
    private var inMemory: [URL: Data] = [:] // `URL` is `Hashable`; `Data` is a byte buffer value type.

    /// Returns cached bytes if present — synchronous *within* the actor; callers still `await` entry.
    func cachedAvatar(for url: URL) -> Data? { // Read-only from isolation POV, but still requires `await` outside.
        inMemory[url] // `Dictionary` subscript returns optional — `nil` means “not cached yet.”
    } // End `cachedAvatar` — fast path: no network, no disk in this minimal teaching cache.

    /// Inserts or replaces bytes for a URL — must complete before another actor call observes the map.
    func insert(_ data: Data, for url: URL) { // Keep inserts synchronous to avoid “half updated” states mid-await.
        inMemory[url] = data // Overwrites prior entry — a real app might track cost / eviction policy here.
    } // End `insert` — called only after bytes are fully downloaded in `AvatarRepository`.
} // End `AvatarCache` — do not return references that escape mutability without copying (article warning).

/// Coordinates network download + cache insertion — demonstrates safe `await` placement vs invariants.
actor AvatarRepository { // Another actor: repository owns the cache actor as a component.
    /// Dedicated cache instance — private so external code cannot bypass repository invariants.
    private let cache = AvatarCache() // `actor` reference is `Sendable`; crossing is always via `await` methods.

    /// Loads bytes for `url`, consulting cache first — `throws` because `URLSession` can fail.
    func avatar(for url: URL) async throws -> AvatarResult { // `async` because networking and actor hops suspend.
        if let cached = await cache.cachedAvatar(for: url) { // `await` enters `AvatarCache`’s executor briefly.
            return AvatarResult(url: url, data: cached) // Return a `Sendable` snapshot, not the actor itself.
        } // End fast path — no network if memory already holds the bytes.

        let (data, _) = try await URLSession.shared.data(from: url) // Slow work happens *outside* cache mutation.
        await cache.insert(data, for: url) // After download completes, commit to cache in one actor call.
        return AvatarResult(url: url, data: data) // Echo bytes to caller — `data` matches what was cached.
    } // End `avatar` — ordering matches the article: don’t sandwich unrelated `await` inside half-baked invariants.
} // End `AvatarRepository` — in production you might add disk tier, deduplication, metrics, etc.

extension AvatarRepository { // Shared accessor pattern mirrors `PreferencesStore.shared` style in this demo.
    /// App-wide repository — dependency injection would be preferable in larger teams.
    static let shared = AvatarRepository() // Lazy one-time init under actor isolation rules.
} // End extension.
