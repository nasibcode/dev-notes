//
//  PreferencesSubsystem.swift
//  DashboardConcurrencyDemo/Infrastructure/Preferences
//
//  Implements Part 3 — a `@globalActor` that serializes access to a subsystem (here: `UserDefaults`).
//  Callers `await` across the boundary, which makes contention visible at compile time.
//

import Foundation // `UserDefaults` lives here; also brings Darwin-ish types used indirectly by the actor runtime.

/// Declares a **global actor**: one shared serial executor for everything annotated `@PreferencesActor`.
@globalActor // Compiler synthesizes isolation rules: only one `@PreferencesActor` function runs at a time globally.
enum PreferencesActor { // `enum` with no cases cannot be instantiated — common pattern for “namespace + shared actor”.
    /// Nested `actor` type is the actual executor holder Swift uses under the hood for `@PreferencesActor`.
    actor ActorType {} // Empty actor body is fine — isolation is the point, not stored state on this nested type.
    /// Shared singleton instance — all `@PreferencesActor` code hops through this executor.
    static let shared = ActorType() // `static let` is lazily initialized once in a thread-safe manner by the runtime.
} // End `PreferencesActor` — think “one lane for preferences,” not “serialize the whole app.”

/// Example store that must touch `UserDefaults` from exactly one serialized context at a time.
@PreferencesActor // Every method on this class is isolated to `PreferencesActor.shared` unless marked otherwise.
final class PreferencesStore { // `final` prevents subclassing surprises around isolation in larger codebases.
    /// Underlying defaults — not `@MainActor`, but all accesses are serialized by `@PreferencesActor` anyway.
    private let defaults: UserDefaults = .standard // `.standard` is the app-wide suite; fine for demos.

    /// Writes the “last seen dashboard version” key — must be `async` to callers outside this actor.
    func setLastSeenDashboardVersion(_ version: Int) { // Synchronous *inside* the actor — no `await` needed here.
        defaults.set(version, forKey: "lastSeenDashboardVersion") // Persists an `Int` as `NSNumber` internally.
    } // End `setLastSeenDashboardVersion` — still requires `await` at external call sites due to actor hopping.

    /// Reads the stored version — returns `0` if unset, matching `integer(forKey:)` semantics.
    func lastSeenDashboardVersion() -> Int { // Pure read, but still actor-isolated: external callers `await` it.
        defaults.integer(forKey: "lastSeenDashboardVersion") // `0` when missing — predictable for UI defaults.
    } // End `lastSeenDashboardVersion`.
} // End `PreferencesStore` — keep heavy work *off* this lane (article warns against unrelated slow tasks here).

extension PreferencesStore { // Extension keeps the “shared instance” separate from the core API surface.
    /// Shared app-wide instance — in production you might inject this for tests instead.
    static let shared = PreferencesStore() // Constructed lazily on first access under actor isolation rules.
} // End extension — `shared` is a convenience for the demo target; dependency injection would be stricter.
