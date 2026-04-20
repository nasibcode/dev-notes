# Cursor PR review commands

This folder contains **Cursor Custom Commands** for a deep pull/merge request review: list open PRs/MRs into your **current base branch**, pick one, run **repo-wide checks** and **cumulative** impact analysis, then **triage** which findings become comments.

## Install

Copy this directory into your **application repository root**:

```text
<your-repo>/.cursor/commands/pr-review.md
<your-repo>/.cursor/commands/pr-review-post.md   (optional)
<your-repo>/.cursor/commands/README.md          (this file)
```

Cursor loads custom commands from **`.cursor/commands/*.md`** at the repo root. If you are republishing from a blog (e.g. Medium), tell readers to copy the **folder structure** above into their own repo.

## Prerequisites

| Host | You need |
|------|-----------|
| **Git** | Always |
| **GitHub** | [GitHub CLI](https://cli.github.com/) (`gh`), authenticated: `gh auth login` |
| **GitLab** | [GitLab CLI](https://gitlab.com/gitlab-org/cli) (`glab`), authenticated: `glab auth login` |
| **Other / git-only** | No forge CLI; you supply **MR/PR URL** or **remote + head branch** when prompted |

Verify:

```bash
gh auth status    # GitHub
glab auth status # GitLab
```

## How to run in Cursor

1. Open the **target repository** in Cursor.
2. Open the **Command Palette** and run **Custom Commands** (or use your Cursor UI path to project commands—names vary by version).
3. Choose **`pr-review`** (from `pr-review.md`).

## Typical workflow

1. **Checkout the base branch** you merge into (e.g. `development` or `develop`). The local name should match the **server-side** target branch used for PRs/MRs, or listing may be empty.
2. Run **`pr-review`**.
3. Answer **Phase 0**: where PRs/MRs are hosted (**GitHub** / **GitLab** / **Other** / **Git only**).
4. When the agent prints the **table**, **reply with the PR number** (GitHub) or **MR IID** (GitLab). **Clicking a URL** in chat does not select a row—you must type the id.
5. Wait for **findings** (`F1`, `F2`, …). Reply with **which IDs** to turn into comments, or **`none`**.
6. Optionally run **`pr-review-post`** to format only the chosen snippets into one paste-ready comment.

## After review

Return to your base branch when finished:

```bash
git checkout development   # or develop, main, etc.
```

`gh pr checkout` / `glab mr checkout` switches away from the base branch by design.

## Troubleshooting

| Issue | What to try |
|--------|-------------|
| Empty PR/MR list | Base branch name on the server may differ from local (`develop` vs `development`). State the correct **server base name** in chat. |
| `gh` / `glab` errors | Re-run auth; ensure the repo remote matches the forge (`git remote -v`). |
| Wrong repo | Custom commands apply to the **open workspace**; open the correct folder. |

## Commands in this folder

| File | Purpose |
|------|--------|
| `pr-review.md` | Full flow: SCM confirm → list → checkout → gates, blast radius, cumulative diff, findings, triage. |
| `pr-review-post.md` | Format **selected** finding snippets into one comment body (optional second step). |
