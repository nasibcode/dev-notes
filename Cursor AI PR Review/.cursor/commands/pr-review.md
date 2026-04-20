# PR review

You are running a **deep PR / MR review** for this repository. Follow every phase in order. Do not skip phases. Do not post comments to the forge until the user explicitly selects finding IDs in the triage step.

---

## Phase 0 — Confirm SCM host (every run)

Before calling `gh`, `glab`, or listing PRs/MRs:

1. If the user **already stated** the host in this chat turn (e.g. “GitHub”, “GitLab”, “git only”), use that and skip the question.
2. Otherwise **ask once**: “Where are pull/merge requests hosted for this repo? **GitHub** / **GitLab** / **Other** / **Git only** (no forge MR list).”
3. Optionally run `git remote -v`, infer a hint from URLs (`github.com`, `gitlab.com`, `dev.azure.com`, `bitbucket.org`, etc.), show the hint, and **still require explicit confirmation**—never assume silently.

**Route:**

| User choice | Listing / checkout | Comments (later triage) |
|-------------|-------------------|-------------------------|
| **GitHub** | `gh` | `gh pr comment` (appendix) |
| **GitLab** | `glab` | `glab mr note` (appendix) |
| **Other** or **Git only** | No API list. Ask for **MR/PR URL** or **remote + head branch**; `git fetch` + checkout that head. | User posts manually or use forge’s UI; do not invent CLI |

---

## Phase A — Preconditions

**All hosts**

- Confirm you are in a **git repo** (`git rev-parse --is-inside-work-tree`).
- `git fetch` for the remote in use (default **`origin`** unless the user names another).
- Record **base branch for listing** = output of `git branch --show-current` unless the user overrides (e.g. server uses `develop` but local branch is `development`—if list is empty, ask for the **exact server-side base branch name**).

**GitHub**

- Run `gh auth status`. If not authenticated, stop and give fix steps (`gh auth login`).

**GitLab**

- Run `glab auth status` (or `glab auth git-credential-check` if that’s what the installed version supports). If not authenticated, stop and give fix steps (`glab auth login`).

**Other / Git only**

- If you will `git checkout` another ref, prefer a **clean working tree**; if dirty, warn and ask to proceed or stash.

---

## Phase B — List open PRs/MRs into the current base branch (or manual ref)

Explain: **Clicking a link in the table does not tell you which item was chosen.** The user must **reply with the PR number (GitHub), MR IID (GitLab), or branch/ref (git-only)**.

**GitHub**

- List open PRs targeting the base branch:

  `gh pr list --base "$(git branch --show-current)" --state open --json number,title,author,headRefName,updatedAt,url --limit 200`

- Sort **newest first** (by `updatedAt` descending).
- Render a **markdown table**: `#`, title, author, head branch, updated, URL.
- **Stop** and ask: “Reply with the **PR number** to review (e.g. `142`).”

**GitLab**

- List open MRs whose **target branch** matches the current branch (adjust flags if `glab` version differs):

  `glab mr list --target-branch "$(git branch --show-current)" --state opened`

- Prefer JSON if supported (e.g. `-o json` or `-F json` per local `glab mr list --help`); otherwise capture text output and build a table with **IID**, title, author, source branch, URL from `glab mr view <iid> --web` pattern or web URLs you can construct from remote.
- **Stop** and ask: “Reply with the **MR IID** to review.”

**Other / Git only**

- Ask for **merge request URL** or **`remote` + `head` branch name** and confirm **base** branch for merge-base logic.
- No table unless the user pastes links.

---

## Phase C — Checkout the selected change

**GitHub** (`<n>` = PR number from user)

- `gh pr view <n> --json baseRefName,headRefName,title,url,commits`
- **Sanity:** `baseRefName` should match the intended base (or explain mismatch / stale list).
- `gh pr checkout <n>` so `HEAD` is the PR head.

**GitLab** (`<iid>` = MR IID)

- `glab mr view <iid>` (capture target branch, source branch, title, web URL).
- **Sanity:** target branch matches intended base.
- `glab mr checkout <iid>` (or documented equivalent for this `glab` version).

**Git only / Other**

- `git fetch <remote> <head-branch>` then `git checkout` the fetched ref (or a local branch tracking it). Ensure **`HEAD`** is the proposed merge **head**.

Tell the user: checkout **leaves** the base branch; to list PRs again, `git checkout <base>`.

---

## Phase D — Full review on current `HEAD` (cumulative, not last push only)

Treat the PR/MR as the full change set from the merge base to `HEAD`. **Do not** review only unstaged or last-commit hunks.

### D1 — Context and scope

- Resolve **base ref** for diff: from `gh`/`glab` view, or user-stated base for git-only.
- Default remote base: `origin/<baseRefName>` if it exists; else ask.
- Compute merge base: `git merge-base HEAD origin/<base>` or `git merge-base HEAD <base-ref>` as appropriate. Record `BASE_SHA`.
- Scope for analysis: **`BASE_SHA..HEAD`** (full PR range). Run `git log --oneline BASE_SHA..HEAD` and `git diff --stat BASE_SHA..HEAD`.

### D2 — Repo-wide gates (discover; do not hardcode one stack)

Discover and run the project’s **standard** checks (full repo / CI parity), not only touched files:

1. Inspect **`package.json`** `scripts` (`test`, `lint`, `typecheck`, `build`, `ci`, etc.).
2. Inspect **`Makefile`**, **`Taskfile.yml`**, **`justfile`**, **`Cargo.toml`**, **`go.mod`**, **`pyproject.toml`**, **`build.gradle`**, **`mvnw`**, etc., for common targets.
3. Inspect **`.github/workflows/`**, **`.gitlab-ci.yml`**, **`azure-pipelines.yml`**, etc., for commands the pipeline runs; prefer **matching CI** when reasonable.
4. Run what exists; if a category has no script (e.g. no typecheck), state **skipped (not configured)**—do not invent tools.
5. If full suite is too slow, say so, run the **closest CI-equivalent subset**, and document **exact commands** and **what was not run**.

### D3 — Blast radius

For symbols, types, public APIs, routes, env vars, config keys, and migrations touched in `BASE_SHA..HEAD`:

- Search **call sites**, imports, feature flags, and consumers outside the diff.
- Flag **breaking changes**, rollout/rollback risk, and data/migration hazards.

### D4 — Cumulative PR review and “back and forth”

- Summarize themes of the **entire** `BASE_SHA..HEAD` diff (risky files, missing tests, security-sensitive areas).
- Scan commit messages and order for: reverts, fixups, WIP, merge commits, conflict markers in messages.
- Note **contradictions**: e.g. tests added then removed, API changed then partially reverted, behavior flip-flop across commits.
- If history was rewritten (force-push), rely on **current tree + `BASE_SHA..HEAD`** only.

### D5 — Major checks checklist (consider each; evidence or N/A)

1. Build / compile (whole project or monorepo root + affected packages per repo convention).
2. Types (project-wide if applicable).
3. Lint / format (repo-wide as configured).
4. Tests (full or CI parity; note gaps).
5. Dependencies / supply chain (only tools the repo already uses).
6. Migrations and data compatibility.
7. Security (authz, secrets, injection, deserialization, paths) at changed boundaries.
8. Concurrency / ordering if relevant.
9. API and contract (versioning, consumers).
10. Observability and ops (logging, metrics, flags, rollback).
11. Docs and user-visible copy vs behavior.
12. Alignment between what you ran locally and CI (call out gaps).

### D6 — Findings (structured)

Emit findings as a **numbered list** with stable IDs: `F1`, `F2`, …

Each finding must include:

- **ID** (e.g. `F3`)
- **Severity**: `blocker` | `major` | `minor` | `nit`
- **Location**: `path:line` or best-effort area
- **Summary** (what is wrong or risky)
- **Recommendation** (what to change or verify)
- **Suggested PR/MR comment** (short, paste-ready: 1–3 sentences; optional minimal code fence)

Findings must be **actionable**, not vague praise.

### D7 — Triage stop (no posting until user chooses)

**Stop** and ask:

“Reply with the **finding IDs** you want turned into PR/MR comments (e.g. `F2 F5`), or **`none`**.”

Until the user replies, **do not** run `gh pr comment`, `glab mr note`, or post anything.

After the user lists IDs, you may draft a **single combined comment** or per-finding snippets. Posting to the forge is optional and only if the user explicitly asks you to run a command or paste into the UI.

---

## Appendix A — Optional: post selected snippets (after triage)

**GitHub** (current repo PR checked out; replace `<n>`):

```bash
gh pr comment <n> --body-file comment.md
```

**GitLab**:

```bash
glab mr note <iid> --message "…"
```

Use the **same SCM host** confirmed in Phase 0. If unsure, output markdown for manual paste only.

---

## Appendix B — Optional: review without leaving base branch (advanced)

To avoid switching the main worktree, use a second worktree:

```bash
git worktree add ../repo-pr-<n> <head-ref>
```

Open that path in the editor if needed, then run the same review logic with `HEAD` pointing at the PR head.
