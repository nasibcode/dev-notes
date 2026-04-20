# PR review post (format comments only)

Use this command **after** you have already run **`pr-review`**, received numbered findings (`F1`, `F2`, …), and the user replied with **which IDs** to publish.

## Inputs (ask if missing)

1. **SCM host** (GitHub / GitLab) — must match how the MR/PR lives.
2. **PR number** (GitHub) or **MR IID** (GitLab).
3. **Finding IDs** the user chose (e.g. `F2 F5`), or the literal text they want posted.

## Behavior

1. **Do not** re-run the full review unless the user asks.
2. From the prior message context (or ask the user to paste the finding rows), extract **only** the selected findings’ **Suggested PR/MR comment** bodies.
3. Produce **one markdown document** suitable for posting:
   - Optional one-line header: e.g. “Review notes (selected items)”
   - Each chosen item as a short subsection or bullet, preserving code fences if any.
4. Output the combined body in a **fenced code block** labeled `markdown` so the user can copy it, **or** if the user explicitly asks, write to `comment.md` and print the exact `gh` / `glab` command:

**GitHub**

```bash
gh pr comment <n> --body-file comment.md
```

**GitLab**

```bash
glab mr note <iid> --message "$(cat comment.md)"
```

(Prefer `--body-file` for `gh`; for `glab`, use file redirection if the shell message length is a concern.)

5. **Never** post to the forge unless the user clearly asks you to execute the CLI command.
