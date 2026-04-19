//
//  BankAccountReentrancyDemo.swift
//  DashboardConcurrencyDemo/Features/AdvancedLab
//
//  Implements Part 4’s “better shape” bank account — synchronous mutation inside the actor so invariants
//  cannot be interleaved across `await` points. The wrong pattern from the article is described in
//  comments (we do not compile the incorrect `async`/`sleep` version on purpose).
//

import Foundation // `URLError` provides a lightweight thrown error without inventing custom error enums here.

/// Tiny finance actor — teaches **reentrancy**: actor isolation is not the same as atomic multi-step algorithms.
actor BankAccount { // `actor` guarantees `balance` is not mutated concurrently by two callers at once.
    /// Private balance — must only change through `deposit` / `withdraw` to keep invariants centralized.
    private var balance: Int = 0 // `Int` is trivially `Sendable` — stored property is actor-isolated by default.

    /// Adds funds — synchronous actor method: no suspension point inside, so no interleaving mid-mutation.
    func deposit(_ amount: Int) { // `async` is intentionally omitted — deposit completes as one critical section.
        guard amount > 0 else { return } // Reject non-positive deposits — business rule, not a concurrency rule.
        balance += amount // Single assignment — no `await` between check and write (article’s “better” pattern).
    } // End `deposit` — safe against reentrancy surprises because there is no suspension inside the method body.

    /// Deducts funds — **throws** instead of `async throws` so balance updates finish before any outer `await`.
    func withdraw(_ amount: Int) throws { // `throws` keeps error propagation without introducing actor reentrancy.
        guard amount > 0 else { return } // Ignore non-positive withdrawals — same rationale as `deposit` guard.
        guard balance >= amount else { // Invariant check — still synchronous within the actor’s exclusive access.
            throw URLError(.dataNotAllowed) // Stand-in for “insufficient funds” — compact for teaching builds.
        } // End `guard` — if we passed, subtraction below cannot run concurrently with another mutating call.
        balance -= amount // Invariant-preserving mutation — no `await` after this in *this* method (key idea).
    } // End `withdraw` — compare mentally to the article’s **wrong** version that slept after mutating balance.

    /// Read-only query — useful for assertions in tests / previews; still serialized through the actor.
    func currentBalance() -> Int { // Not `async` — pure read of actor-isolated state still requires `await` outside.
        balance // Return the latest committed balance — callers `await` the read across isolation.
    } // End `currentBalance`.
} // End `BankAccount` — **Wrong pattern (not compiled here):** `async` `withdraw` that `await`s between steps.

/// Coordinates “mutate then notify” — async side effects belong **after** the synchronous actor withdrawal.
func withdrawAndNotify(account: BankAccount, amount: Int) async { // Free function — not tied to UI frameworks.
    do { // Scope errors from `withdraw` separately from hypothetical notification failures (not shown here).
        try await account.withdraw(amount) // Crossing into the actor to call a throwing function uses `try await`.
        // After this line, the balance mutation is complete — safe to `await` analytics/network “side effects.”
    } catch { // If insufficient funds, swallow for demo — real apps would surface errors to UI models.
        _ = error // Silence unused variable warning — in a lab you might `dump(error)` instead.
    } // End `catch`.
} // End `withdrawAndNotify` — article’s teaching point: keep “decide + mutate” steps non-suspending inside actors.
