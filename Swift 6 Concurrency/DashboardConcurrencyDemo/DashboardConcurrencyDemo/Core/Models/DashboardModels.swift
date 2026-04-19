//
//  DashboardModels.swift
//  DashboardConcurrencyDemo/Core/Models
//
//  Implements Part 5 (`Sendable` DTO boundaries) and Part 6’s `DashboardSnapshot` from
//  `medium-swift6-concurrency.md`. Values here are intentionally plain structs so they can
//  cross concurrency domains without shared mutable references.
//

import Foundation // `URL`, `Data`, `Decodable`, and other value-type machinery live here.

/// Snapshot type returned after the parallel `async let` fan-out in `DashboardService.loadSnapshot()`.
/// `Sendable` promises the compiler: “this value is safe to pass across arbitrary isolation boundaries.”
struct DashboardSnapshot: Sendable { // `Sendable` is a marker protocol enforced under Swift 6 strict concurrency.
    let profile: ProfileDTO // Immutable `let` — no concurrent writer can mutate this field after construction.
    let settings: SettingsDTO // Same pattern: read-only surface area for UI rendering.
    let flags: FlagsDTO // Remote-config style flags — still a value, not a live service handle.
    let recommendations: [RecommendationDTO] // Array of structs — each element is independent and shareable.
} // End `DashboardSnapshot` — keep it small: push networking objects *out* of this type.

/// User-visible profile fields decoded from JSON (or mocked) and handed to the UI layer.
struct ProfileDTO: Decodable, Sendable { // `Decodable` for JSON; `Sendable` for crossing tasks/actors freely.
    let id: String // Stable identifier — `String` is `Sendable` in modern Swift.
    let displayName: String // Human-readable label — again a value type suitable for message passing.
} // End `ProfileDTO`.

/// Accessibility / motion preferences — mirrors the article’s `SettingsDTO` example shape.
struct SettingsDTO: Decodable, Sendable { // Immutable settings snapshot, not a live `UserDefaults` binding.
    let prefersReducedMotion: Bool // `Bool` is trivially `Sendable`.
} // End `SettingsDTO`.

/// Feature flags — mirrors the article’s `FlagsDTO` example shape.
struct FlagsDTO: Decodable, Sendable { // Treat as “message from server,” not as shared toggle state.
    let enableNewDashboard: Bool // UI can branch on this once per load without touching global mutable state.
} // End `FlagsDTO`.

/// One row in the recommendations list — extended with an optional avatar URL for Part 4 / Part 7 demos.
struct RecommendationDTO: Decodable, Sendable, Identifiable { // `Identifiable` helps SwiftUI `List`/`ForEach`.
    let id: String // Primary key string — matches `Identifiable.id` requirement.
    let title: String // Row title text for the dashboard list UI.
    let avatarURL: URL? // Optional remote image — `URL` is `Sendable`; `Optional` preserves that property.

    /// Coding keys — keeps decoding explicit when JSON omits optional fields like `avatarURL`.
    enum CodingKeys: String, CodingKey { // `String` raw values default to property names unless customized.
        case id // Mirrors JSON key `"id"` for the recommendation identifier string.
        case title // Mirrors JSON key `"title"` for the human-readable row title.
        case avatarURL // Optional key — older payloads without this field still decode cleanly.
    } // End `CodingKeys`.

    /// Custom decode so missing `avatarURL` becomes `nil` instead of failing the whole dashboard decode.
    init(from decoder: Decoder) throws { // `throws` because keyed container lookups can fail on type mismatch.
        let container = try decoder.container(keyedBy: CodingKeys.self) // Typed keyed container for safe access.
        id = try container.decode(String.self, forKey: .id) // Required field — propagate error if wrong type.
        title = try container.decode(String.self, forKey: .title) // Required field — same strictness as `id`.
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL) // Optional — absent means `nil`.
    } // End `init(from:)` — memberwise `init` is not synthesized once this custom initializer exists.
} // End `RecommendationDTO`.

extension RecommendationDTO { // Convenience initializer for mocked in-memory rows (no JSON involved).
    /// Memberwise initializer used by `DashboardService` mocks — supplies `avatarURL` when helpful.
    init(id: String, title: String, avatarURL: URL? = nil) { // Default `nil` keeps call sites short in tests/mocks.
        self.id = id // Copy parameter into stored property — value semantics, no shared references.
        self.title = title // Copy parameter into stored property.
        self.avatarURL = avatarURL // Copy optional URL into stored property.
    } // End convenience `init`.
} // End extension — keeps the synthesized `Decodable` path separate from local construction.

/// Result of an avatar fetch — mirrors the article’s `AvatarResult` (Part 4).
struct AvatarResult: Sendable { // Returned from `AvatarRepository` so callers outside the actor get a copy.
    let url: URL // Which remote resource this data belongs to (handy for SwiftUI `AsyncImage` keys).
    let data: Data // Raw bytes — `Data` is `Sendable`; treat as immutable for the demo’s purposes.
} // End `AvatarResult`.
