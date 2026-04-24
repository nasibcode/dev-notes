# SPM modularization: `Package.swift` + `Package.resolved` (zero → expert)

This doc focuses on the **two files** you must understand to become “master-level” with Swift Package Manager (SPM):

- **`Package.swift`**: the *declarative build manifest* (what your package *is*).
- **`Package.resolved`**: the *lockfile* (what your dependency graph *resolved to*).

It also explains **how dependency resolution works internally** (conceptually), what is pinned, and what you should commit.

---

## What is `Package.swift`?

`Package.swift` is a Swift file (a Swift manifest) that defines:

- **Package metadata**: name, supported platforms
- **Products**: what your package exports to other packages/apps
- **Targets**: the compilation units (modules) you build and test
- **Dependencies**: external packages you depend on (URLs/paths + version requirements)
- **Build settings** (per-target): Swift defines, linker flags, resources, plugins, etc.

SPM reads `Package.swift` to build a **package graph** and then builds targets in dependency order.

### Why it’s a Swift file (not JSON/YAML)

SPM chose Swift manifests so that manifests can:

- Use **basic control flow** for conditional configuration (e.g., platform gates).
- Compute arrays or reuse constants (within reason).

But manifests are intentionally constrained: they’re meant to be **declarative**. If you make manifests “too dynamic,” you make builds harder to reason about.

---

## The most important line: `// swift-tools-version: X.Y`

At the very top of `Package.swift` you’ll see something like:

```swift
// swift-tools-version: 5.10
```

This is not a comment “for humans”; it is a **directive** SPM uses to decide:

- Which **manifest API version** to use (`PackageDescription` capabilities).
- Which **language features** are permitted in the manifest.

### Worked example: why teammates sometimes can’t even open the package

If your manifest says:

```swift
// swift-tools-version: 5.10
```

Then a teammate/CI machine using an older toolchain (for example, an SPM/Xcode that only supports manifest APIs up to 5.9) can fail *before dependency resolution* with errors like “tools version not supported” or “cannot parse manifest,” even though your Swift sources might otherwise compile fine.

Practical implications:

- If you raise the tools version, you’re implicitly raising the **minimum SPM** required to evaluate the manifest.
- If you need to support older toolchains, keep the tools version lower **unless** you rely on newer manifest features.

### Why it exists

The manifest API evolves. The tools version prevents older toolchains from mis-parsing newer manifests, and lets SPM keep compatibility rules crisp.

---

## Manifest structure (keywords + why)

A typical manifest:

```swift
import PackageDescription

let package = Package(
  name: "MyPackage",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "MyLibrary", targets: ["MyLibrary"])
  ],
  dependencies: [
    .package(url: "https://github.com/...", from: "1.2.0")
  ],
  targets: [
    .target(
      name: "MyLibrary",
      dependencies: [
        .product(name: "SomeProduct", package: "some-package")
      ],
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "MyLibraryTests",
      dependencies: ["MyLibrary"]
    )
  ]
)
```

Below is what each major keyword means and why it exists.

### `import PackageDescription`

Imports the SPM manifest API. This is how you get access to `Package`, `Target`, `Product`, and the various requirement types.

### `name`

Human-readable package name. Useful for display, but **package identity** for dependency resolution is more subtle (see identity notes under `Package.resolved`).

### `platforms`

Declares minimum supported OS versions.

- **Why**: SPM and Xcode need to know availability constraints to compile and link correctly, and to validate dependency compatibility.

### `products`

Defines what other packages (or an app) can depend on.

- **Why**: A target can exist without being exposed publicly. Products are the “export surface” of a package.

Common product types:

- `.library(name:type:targets:)`
  - **`type`** can be `.static`, `.dynamic`, or omitted (`.automatic` behavior).
  - **Why**: controls linking behavior and how code is embedded into final artifacts.

#### Worked example: “targets are internal modules, products are what others can depend on”

Imagine you have two targets:

- `Networking` (internal helper module)
- `UserFeature` (feature module)

If you only declare a product for `UserFeature`:

- other packages/apps can depend on **the `UserFeature` product**
- they *cannot* depend on your internal `Networking` target unless you also expose it as a product

This is one of the main ways SPM helps you keep modular boundaries: you can keep some targets purely internal.

### `dependencies`

Defines *external package* dependencies (not your internal targets).

Each dependency includes a **location** and a **requirement**:

- `.package(url: ..., from: "1.2.3")` (semantic version range)
- `.package(url: ..., .upToNextMajor(from: ...))`
- `.package(url: ..., .upToNextMinor(from: ...))`
- `.package(url: ..., exact: "1.2.3")` (pin a version)
- `.package(url: ..., branch: "main")` (floating; avoid for reproducible builds)
- `.package(url: ..., revision: "...")` (pin a commit SHA)
- `.package(path: "../LocalPackage")` (local path; great for monorepos)

**Why**: Separates “where to fetch” from “what versions are acceptable.”

#### Worked example: what `from:` / `exact:` / `branch:` actually mean for “picking”

Suppose the remote package has tags: `1.2.0`, `1.2.1`, `1.3.0`, `2.0.0`.

- `.package(url: ..., from: "1.2.0")`
  - means: allow \(>= 1.2.0\) and \(< 2.0.0\)
  - SPM will typically pick the **highest available** in that range → `1.3.0`
- `.package(url: ..., exact: "1.2.1")`
  - means: allow **only** `1.2.1`
  - if `1.2.1` doesn’t exist (or is incompatible), resolution fails
- `.package(url: ..., branch: "main")`
  - means: allow “whatever commit `main` points to right now”
  - SPM picks the latest revision on that branch at resolve time, which is why it’s not reproducible
- `.package(url: ..., revision: "<sha>")`
  - means: allow exactly that commit
  - reproducible, but you’re pinning a commit instead of a semver tag

### `targets`

Defines compilation units (modules). This is where modularization actually lives.

Important target types:

- `.target`: production code module
- `.testTarget`: test module
- `.executableTarget`: CLI module
- `.binaryTarget`: prebuilt XCFramework module
- (advanced) plugin/macro targets depending on toolchain

Each target supports key fields:

- **`dependencies`**: other targets/products imported by this module
  - **Why**: forms the internal target graph and enforces boundaries.
- **`resources`**: `.process` / `.copy`
  - **Why**: tells SPM what to bundle; access via `Bundle.module`.
- **`path` / `exclude` / `sources`**:
  - **Why**: custom layout control (prefer default layout when possible).
- **`swiftSettings` / `linkerSettings` / `cSettings` / `cxxSettings`**:
  - **Why**: per-target build configuration, flags, and defines.

#### Worked example: why `Bundle.module` sometimes “mysteriously” crashes or is empty

If you reference a resource at runtime but forget to declare it under the target’s `resources:`, SPM will not bundle it, and `Bundle.module` won’t contain it. The fix is not in Xcode build phases; it’s in the target declaration:

- add `.process("Resources")` (or `.copy(...)`) to the target that owns the resource
- ensure the resources live under that target’s directory (unless you set a custom `path`)

---

## How SPM evaluates `Package.swift` (internals, conceptually)

SPM does not treat the manifest as “arbitrary Swift code that can do anything.” Internally it:

- Launches a **manifest evaluation** step that compiles/runs the manifest in a controlled environment.
- Produces an in-memory model of `Package`, `Target`, `Product`, etc.
- Builds a **package graph** (packages + their products + targets + interconnections).

Key point: manifest evaluation happens **before** dependency resolution completes, because the manifest itself declares dependencies and targets.

---

## What is `Package.resolved`?

`Package.resolved` is SPM’s **lockfile**: it records the *exact* resolved versions (or revisions) of your dependencies at a point in time.

It exists so that:

- Builds are **reproducible** across machines and CI
- “Works on my machine” becomes “works everywhere” (same dependency commits)
- You can upgrade dependencies **intentionally** instead of accidentally

### Where it lives (common locations)

Depending on how you’re using SPM:

- **Swift package repo**: typically `Package.resolved` at the repo root (or within `.swiftpm/` depending on tooling).
- **Xcode project/workspace**: often stored under the workspace’s shared data (Xcode-managed). Many teams keep Xcode’s generated lockfile in version control for app repos.

The exact path varies by Xcode/SPM integration, but the role is the same: **pin the graph**.

---

## What exactly gets pinned?

For each resolved dependency, SPM records:

- **Identity**: a normalized identifier for the package (derived from URL/path)
- **Location**: the original URL/path
- **State**: what it resolved to, such as:
  - **version** (e.g., `1.2.3`) + revision hash
  - **branch** + revision hash
  - **revision** hash directly

Even when you resolve to a semantic version, SPM typically also records the **exact commit** corresponding to that tag, to guarantee reproducibility.

### Worked example: why a “version” still has a commit hash

When you resolve to `1.2.3`, SPM commonly records:

- the **version** (`1.2.3`)
- the **revision** (a git commit SHA that the `1.2.3` tag points to)

That way, if a tag is ever moved (it shouldn’t be, but it happens), your lockfile still points to a specific commit and your build stays reproducible.

---

## How dependency resolution works (internals, conceptually)

SPM performs dependency resolution in these phases:

### 1) Build the constraint set

From all manifests involved (your root package plus every dependency manifest), SPM gathers constraints like:

- Package A requires B `>= 2.0.0 < 3.0.0`
- Package C requires B `>= 2.1.0 < 2.2.0`
- Your root requires B `exact 2.1.3`

#### How SPM “picks” a version from that

SPM solves this by finding versions of **B** that satisfy **all constraints at once** (think: set intersection).

Using the example:

- Start with A’s allowed range for B: \([2.0.0, 3.0.0)\)
- Intersect with C’s allowed range: \([2.1.0, 2.2.0)\)
  - Result so far: B must be in \([2.1.0, 2.2.0)\)
- Apply the root constraint: **exactly** `2.1.3`
  - Check if `2.1.3` is inside \([2.1.0, 2.2.0)\) → yes
  - So SPM can pick **B = 2.1.3**

If the root did *not* pin an exact version, SPM typically chooses the **highest available** version that fits the final allowed range (here: the highest tag `< 2.2.0` and `>= 2.1.0`).

If the intersection is empty (or the pinned exact version is outside it), resolution fails because there is **no single version** that satisfies every requirement.

These constraints come from:

- Your `dependencies` section
- Each dependency package’s own `dependencies`
- Any explicit pins (if you used `.exact`, `.revision`, etc.)

### 2) Fetch package metadata (tags, commits, manifests)

SPM needs:

- Available versions/tags for each URL
- The manifests at candidate versions

It fetches what it needs, then evaluates those manifests to learn transitive constraints.

#### Worked example: why resolution can be slow the first time

SPM may need to fetch:

- tag lists to know what versions are available
- specific manifests for candidate versions (to discover transitive dependencies)

This is why “the first resolve” on a clean machine is often slower than subsequent builds (which can reuse cached checkouts/metadata).

### 3) Solve the version assignment problem

Resolution is essentially a constraint-solving problem:

- Pick a specific version/revision for each dependency
- Such that all constraints are satisfied

If constraints conflict, SPM fails with a resolution error that indicates incompatible requirements.

#### Worked example: a conflict that fails

If you had:

- Package A requires B `>= 2.0.0 < 3.0.0`
- Package C requires B `>= 2.1.0 < 2.2.0`
- Your root requires B `exact 2.2.1`

The allowed intersection from A and C is \([2.1.0, 2.2.0)\), but `2.2.1` is **outside** it, so SPM reports a resolution failure: there is no single B version that satisfies everyone.

### 4) Write the lockfile (`Package.resolved`)

Once a solution is found, SPM writes out the selected versions/revisions so future builds can reuse them without re-solving (unless something changed).

---

## When and why `Package.resolved` changes

It changes when:

- You add/remove a dependency
- You change a requirement range (e.g., `from:` to `exact:`)
- You run an “update” action (or Xcode updates packages)
- A dependency graph changes due to switching branches / editing manifests

It can also change format between SPM/Xcode versions (the file is tooling-owned).

---

## Should you commit `Package.resolved`?

### For apps (Xcode projects)

**Usually yes**. App repos generally want deterministic CI builds and predictable dependency upgrades.

### For libraries intended to be depended on by others

Often **no** (or at least it’s debated). A library package typically expresses version ranges and lets the *downstream app* lock the graph.

### Practical rule

- **Application repo**: commit the lockfile for reproducibility.
- **Reusable library package**: commit only if your team explicitly wants locked dependency builds for that library’s CI; otherwise let consumers resolve.

---

## How this ties back to modularization

Modularization in SPM is mostly about **targets and products**:

- You split code into **targets** (modules) with explicit `dependencies`.
- You expose only what you want via **products**.

`Package.resolved` is the *other half of the stability story*:

- It stabilizes the **external dependency graph** so your internal modules don’t “randomly” break due to upstream changes.

---

## Debugging and “expert signals” when SPM behaves oddly

High-signal places to look when resolution/builds surprise you:

- **Conflicting version requirements** across transitive dependencies
- **Identity mismatches** (same repo referenced by different URLs → treated as different packages)
- **Branch-based dependencies** (floating; can change without manifest edits)
- **Binary targets** and platform slices (missing architectures)
- **Resources** not included because they weren’t declared in target `resources`

### Worked example: identity mismatch (same repo, “different” package)

If one manifest references:

- `https://github.com/owner/repo`

and another references:

- `git@github.com:owner/repo.git`

SPM may treat these as different identities in some situations, which can lead to confusing outcomes (duplicate checkouts, “two packages with the same name,” or unexpected resolution behavior). Team best practice: standardize on one URL form (typically HTTPS) across all packages.

## Troubleshooting guide (high-signal checks)

### If SPM resolution fails

- Look for **conflicting constraints** in the error output (two ranges that can’t both be satisfied).
- Check for **identity mismatch** (same dependency referenced twice with different URLs).
- If the lockfile is stale/corrupt, re-resolve cleanly (script below).

### If Xcode says “package product not found” / “missing module”

Common causes:

- Target depends on `.product(...)` but the dependency package doesn’t actually vend that product name.
- Product name changed upstream; your lockfile pins an older version.
- You’re opening `.xcodeproj` when you should open `.xcworkspace` (or vice versa), and resolution is happening in the “other” context.

### If builds are fine locally but fail on CI

- Make sure CI uses a deterministic graph (commit the correct lockfile for app repos).
- Ensure CI machine has compatible Xcode/Swift version for your tools-version.

---

## Script: fix common package-level issues (copy/paste runnable)

This script is designed to be run from **your project path** (the directory that contains `Package.swift`, or an Xcode project/workspace that uses Swift packages).

It will:

- detect a Swift package root
- run a “safe” reset/resolve using SPM
- optionally do a more aggressive cleanup (caches, derived data)
- try to resolve packages for Xcode workspaces/projects if found

### How to use it

1) Copy the script below into a file named `fix-swiftpm.sh` (you can keep it anywhere: in your repo under `scripts/`, in your dotfiles, etc).

2) From your **project directory** (the folder you want to fix), run it:

```bash
bash "/absolute/path/to/fix-swiftpm.sh"
```

Aggressive mode:

```bash
bash "/absolute/path/to/fix-swiftpm.sh" --aggressive
```

Optional: make it directly executable once, then you can run it without `bash`:

```bash
chmod +x "/absolute/path/to/fix-swiftpm.sh"
```

Then:

```bash
"/absolute/path/to/fix-swiftpm.sh"
```

```bash
set -euo pipefail

AGGRESSIVE=0
if [[ "${1-}" == "--aggressive" ]]; then
  AGGRESSIVE=1
fi

say() { printf "\n==> %s\n" "$*"; }
warn() { printf "\n[warn] %s\n" "$*" >&2; }

ROOT="$(pwd)"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have swift; then
  warn "swift is not on PATH. Install Xcode command line tools or Swift toolchain."
  exit 1
fi

say "Swift version"
swift --version || true

PKG_ROOT=""
if [[ -f "$ROOT/Package.swift" ]]; then
  PKG_ROOT="$ROOT"
else
  # Basic heuristic: first ancestor containing Package.swift (current dir only)
  warn "No Package.swift in current directory."
fi

if [[ -n "$PKG_ROOT" ]]; then
  say "SPM: found Package.swift at $PKG_ROOT"
  cd "$PKG_ROOT"

  if [[ -f "Package.resolved" ]]; then
    say "Backing up Package.resolved"
    cp -f "Package.resolved" "Package.resolved.bak.$(date +%Y%m%d-%H%M%S)" || true
  fi

  say "SPM: reset (clears build + checkouts for this package)"
  swift package reset

  say "SPM: resolve (recompute pins without upgrading ranges)"
  swift package resolve

  say "SPM: show dependencies"
  swift package show-dependencies || true
else
  warn "Skipping swift package commands (no Package.swift here)."
fi

# Xcode resolution (works if xcodebuild exists and a workspace/project is present)
if have xcodebuild; then
  # Prefer workspace if present
  WORKSPACE="$(ls -1 *.xcworkspace 2>/dev/null | head -n 1 || true)"
  PROJECT="$(ls -1 *.xcodeproj 2>/dev/null | head -n 1 || true)"

  if [[ -n "$WORKSPACE" ]]; then
    say "Xcode: resolving Swift packages for workspace: $WORKSPACE"
    xcodebuild -resolvePackageDependencies -workspace "$WORKSPACE" >/dev/null
  elif [[ -n "$PROJECT" ]]; then
    say "Xcode: resolving Swift packages for project: $PROJECT"
    xcodebuild -resolvePackageDependencies -project "$PROJECT" >/dev/null
  else
    warn "No .xcworkspace or .xcodeproj in current directory (skipping xcodebuild resolve)."
  fi
else
  warn "xcodebuild not found (skipping Xcode package resolution)."
fi

if [[ "$AGGRESSIVE" -eq 1 ]]; then
  say "Aggressive cleanup enabled"

  # Remove local SPM working directory (package-local cache)
  if [[ -d ".swiftpm" ]]; then
    say "Removing .swiftpm (package-local state)"
    rm -rf ".swiftpm"
  fi

  # DerivedData cleanup (Xcode)
  DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
  if [[ -d "$DERIVED" ]]; then
    say "Cleaning Xcode DerivedData (may take time)"
    rm -rf "$DERIVED"/*
  fi

  # Global SPM caches are intentionally not wiped by default because it can be slow
  # and impacts other projects. Uncomment if you *really* need it:
  #
  # say "Wiping global SPM caches"
  # rm -rf "$HOME/Library/Caches/org.swift.swiftpm" || true
fi

say "Done. If you still see resolution errors, check for version constraint conflicts or URL identity mismatches."
```

