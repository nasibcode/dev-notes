# Dashboard Concurrency Demo

Companion Xcode project for `medium-swift6-concurrency.md`: Swift **6.0**, **complete** strict concurrency, iOS **18** deployment target.

## Module layout (`DashboardConcurrencyDemo/`)

| Folder | Role |
|--------|------|
| `App/` | `@main` entry + root `TabView` shell |
| `Features/Dashboard/` | SwiftUI dashboard screen + view model |
| `Features/UIKitDemo/` | UIKit lifecycle demo + `UIViewControllerRepresentable` bridge |
| `Features/AdvancedLab/` | Appendix demos (patterns UI, showcase helpers, bank actor sample) |
| `Core/Models/` | `Sendable` DTOs and snapshot types shared across layers |
| `Services/` | `DashboardService` — networking-shaped work off the main actor |
| `Infrastructure/Preferences/` | `@globalActor` preferences lane |
| `Infrastructure/Avatars/` | Avatar cache + repository actors |

All of the above is still **one app target**; folders enforce boundaries for readers and for future extraction into Swift packages if you outgrow a single target.

## Open and run

1. Open `DashboardConcurrencyDemo.xcodeproj` in Xcode.
2. Select an iOS Simulator (or device).
3. Set **Signing**: target **DashboardConcurrencyDemo** → *Signing & Capabilities* → choose your **Team** (bundle id `com.example.DashboardConcurrencyDemo` is a placeholder).
4. Run (**⌘R**).

## Tabs

- **Dashboard** — SwiftUI `.task`, `@MainActor` `@Observable` view model, `async let` snapshot load, `PreferencesActor`, `AvatarRepository`, cancellation notes.
- **UIKit** — stored `Task` + cancel in `viewWillDisappear` / `deinit`.
- **Advanced** — appendix patterns (continuations, `AsyncStream` cleanup, legacy cancel bridge, best-effort task groups, buffering policy, timeout helper).

Teaching notes are **inline in the Swift sources** (line-by-line comments mapping to article sections).
