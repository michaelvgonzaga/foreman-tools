# foreman-tools API Schema

Canonical output contract for all subcommands. Every field listed here is locked — changing a field name, type, or enum value requires an explicit version bump and migration note in spec.md and CLAUDE.md.

**Global contract:** JSON to stdout on success. Errors to stderr + exit 1. Output is always valid JSON when exit 0.

---

## doctor

`foreman-tools doctor`

```json
{
  "claude": true,
  "git": true,
  "gh": false,
  "version": "1.0.0"
}
```

| Field | Type | Notes |
|---|---|---|
| `claude` | bool | `claude` binary in PATH |
| `git` | bool | `git` binary in PATH |
| `gh` | bool | `gh` binary in PATH |
| `version` | string | output of `claude --version` or `""` if unavailable |

---

## status

`foreman-tools status <workspace-path>`

```json
{
  "upToDate": true,
  "behindBy": 0,
  "firstRun": false,
  "projectsFileExists": true
}
```

| Field | Type | Notes |
|---|---|---|
| `upToDate` | bool | local HEAD == origin/main |
| `behindBy` | int | commits origin/main is ahead of HEAD |
| `firstRun` | bool | `.first-run` file exists in workspace root |
| `projectsFileExists` | bool | `_projects.md` exists in workspace root |

**Errors:** `NotAGitRepo` → `error: not a git repository: <path>`

---

## commits

`foreman-tools commits <repo-path> [since-tag]`

```json
[
  {"hash": "a1b2c3d", "category": "new", "message": "add scan subcommand"}
]
```

| Field | Type | Notes |
|---|---|---|
| `hash` | string | short git hash |
| `category` | enum | `"new"` `"improvement"` `"fix"` `"docs"` `"other"` |
| `message` | string | first line of commit message |

**Errors:** `GitFailed` → `error: git log failed (bad path or tag?): <path>`

---

## gh-user

`foreman-tools gh-user`

```json
{
  "authenticated": true,
  "login": "michaelvgonzaga"
}
```

| Field | Type | Notes |
|---|---|---|
| `authenticated` | bool | `gh auth status` succeeded |
| `login` | string | GitHub username, or `""` if not authenticated |

**Note:** Always exits 0. Returns `authenticated: false, login: ""` when `gh` is absent or not logged in.

---

## release-info

`foreman-tools release-info <repo-path>`

```json
{
  "latestTag": "v1.5.0",
  "suggestedNext": "v1.6.0",
  "commitsSince": 3,
  "isDirty": false
}
```

| Field | Type | Notes |
|---|---|---|
| `latestTag` | string \| null | most recent semver tag, or `null` if no tags |
| `suggestedNext` | string | bumps patch component of `latestTag`; `"v0.1.0"` if no tags |
| `commitsSince` | int | commits since `latestTag` (or total commits if no tags) |
| `isDirty` | bool | working tree has uncommitted changes |

**Errors:** `NotAGitRepo` → `error: not a git repository: <path>`

---

## repo-info

`foreman-tools repo-info <repo-path>`

```json
{
  "owner": "michaelvgonzaga",
  "repo": "foreman",
  "url": "https://github.com/michaelvgonzaga/foreman.git"
}
```

**Errors:** `NoRemote` → no `origin` remote. `UnparsableRemote` → URL not parseable as `owner/repo`.

---

## tag-exists

`foreman-tools tag-exists <repo-path> <tag>`

```json
{
  "exists": true
}
```

**Errors:** exit 1 if `<repo-path>` is not a git repository.

---

## changes-preview

`foreman-tools changes-preview <repo-path>`

```json
{
  "commits": [
    {"hash": "a1b2c3d", "category": "fix", "message": "fix typo"}
  ],
  "filesChanged": 2
}
```

`commits` entries share the same shape as the `commits` subcommand. `filesChanged` is the number of files changed in the last commit.

---

## scan

`foreman-tools scan <path>`

```json
{
  "framework": "zig",
  "keyFiles": ["build.zig", "src/main.zig"],
  "depCount": 2,
  "dirMap": ["src/", "zig-out/"],
  "entryPoint": "src/main.zig",
  "fileCount": 12,
  "files": [
    {"path": "src/root.zig", "bytes": 45000, "kind": "source"}
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `framework` | string | detected language/framework (e.g. `"zig"`, `"node"`, `"python"`) |
| `keyFiles` | string[] | project root files of interest |
| `depCount` | int | dependency count from manifest |
| `dirMap` | string[] | top-level directories |
| `entryPoint` | string \| null | detected main entry file |
| `fileCount` | int | total files before cap |
| `files` | object[] | flat inventory, capped at 500, sorted largest-first |
| `files[].kind` | enum | `"source"` `"test"` `"config"` `"docs"` `"other"` |

**Constraints:** `files` capped at 500. `fileCount` reflects true total before cap.

---

## diff-dirs

`foreman-tools diff-dirs <path1> <path2>`

```json
{
  "onlyInA": ["README.md"],
  "onlyInB": [],
  "inBoth": [
    {"path": "src/main.zig", "bytesA": 1200, "bytesB": 1300, "same": false}
  ]
}
```

All paths are relative. `same` is derived from equal byte counts (not a content hash).

**Errors:** `PathANotFound`, `PathBNotFound`

---

## grep

`foreman-tools grep <root-path> <pattern> [ext-filter]`

```json
{
  "pattern": "computeDoctor",
  "matchCount": 3,
  "capped": false,
  "matches": [
    {"file": "src/main.zig", "line": 49, "col": 20, "text": "const result = try root.computeDoctor(gpa, io);"}
  ]
}
```

**Constraints:** Literal string search only (no regex). Capped at 500 matches. Files >5 MB skipped. `capped: true` when limit hit.

**Errors:** `RootNotFound`

---

## parse-stack

`foreman-tools parse-stack` (reads stdin)

```json
[
  {"file": "src/root.zig", "line": 42, "col": 3, "fn": "computeDoctor"}
]
```

**Constraints:** Reads up to 512 KB from stdin. Returns empty array `[]` if no parseable frames found.

---

## find-files

`foreman-tools find-files <root-path> <glob>`

```json
{
  "pattern": "*.zig",
  "count": 4,
  "capped": false,
  "files": ["src/main.zig", "src/root.zig"]
}
```

**Glob patterns:** `*.ext` (extension match), `prefix*`, `*contains*`, exact name, `*` (all files).

**Constraints:** Capped at 2000 results. `capped: true` when limit hit.

**Errors:** `RootNotFound`

---

## json-query

`foreman-tools json-query <file-path> <dot-path>`

Found:
```json
{"path": "hooks.Stop.0.command", "found": true, "type": "string", "value": "echo hello"}
```

Not found:
```json
{"path": "hooks.Stop.99", "found": false, "type": null, "value": null}
```

| Field | Type | Notes |
|---|---|---|
| `type` | enum | `"string"` `"number"` `"bool"` `"null"` `"object"` `"array"` |
| `value` | raw JSON | raw fragment, not re-encoded (e.g. `42`, not `"42"`) |

**Dot path syntax:** `.` separates keys. Numeric segments index arrays (`items.1`).

**Errors:** `FileNotFound`, `InvalidJson`

---

## git-diff

`foreman-tools git-diff <repo-path> [ref]`

```json
{
  "ref": "HEAD",
  "totalAdditions": 12,
  "totalDeletions": 3,
  "fileCount": 2,
  "files": [
    {"path": "src/main.zig", "additions": 10, "deletions": 2, "status": "modified"}
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `ref` | string | ref used; `""` for working tree vs HEAD |
| `files[].status` | enum | `"added"` `"modified"` `"deleted"` `"renamed"` |

**Errors:** `GitFailed`

---

## list-dir

`foreman-tools list-dir <path>`

```json
{
  "path": "/Users/me/foreman",
  "count": 3,
  "entries": [
    {"name": "src", "kind": "dir"},
    {"name": "main.zig", "kind": "file", "bytes": 4200}
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `entries[].kind` | enum | `"dir"` `"file"` |
| `entries[].bytes` | int | present on `file` entries only; omitted on `dir` entries |

**Constraints:** Sorted dirs-first, then files, both groups alphabetically.

**Errors:** `PathNotFound`

---

## file-stats

`foreman-tools file-stats <file-path>`

```json
{
  "path": "/Users/me/foreman/src/main.zig",
  "lines": 840,
  "bytes": 28500
}
```

**Errors:** exit 1 if file not found.

---

## env-scan

`foreman-tools env-scan <root-path>`

```json
{
  "root": "/Users/me/project",
  "fileCount": 2,
  "files": [
    {"file": ".env", "keyCount": 3, "keys": ["DATABASE_URL", "SECRET_KEY", "PORT"]}
  ]
}
```

**Constraints:** Returns keys only, never values.

**Errors:** `RootNotFound`

---

## toml-query

`foreman-tools toml-query <file-path> <dot-path>`

Same shape as `json-query`. `type` and `value` use the same enums and raw JSON encoding.

**Constraints:** Line-by-line parser. Supports `[[array-of-tables]]` section headers (skipped, not indexed). Covers `[table]` and `key = value` forms used in Cargo.toml, pyproject.toml.

**Errors:** `FileNotFound`

---

## list-projects

`foreman-tools list-projects <foreman-root>`

```json
[
  {"name": "cse-cli", "url": "https://github.com/michaelvgonzaga/cse-cli", "isForeman": true, "isLocal": true}
]
```

| Field | Type | Notes |
|---|---|---|
| `isForeman` | bool | repo contains a `CLAUDE.md` |
| `isLocal` | bool | repo is cloned locally inside `<foreman-root>` |

---

## tarball-sha

`foreman-tools tarball-sha <owner> <repo> <tag>`

```json
{
  "sha256": "7cbe00c307c16d7b43a5f4826e08233d7d2401b50f3823083b1b57893a3f0090",
  "url": "https://github.com/michaelvgonzaga/foreman-tools/archive/refs/tags/v0.19.0.tar.gz"
}
```

**Constraints:** Retries once after 10s if GitHub returns the empty-file hash (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`).

**Errors:** `FetchFailed` → tarball not available after retry.

---

## formula-info

`foreman-tools formula-info <tap-path> <formula-name>`

```json
{
  "formulaPath": "/opt/homebrew/.../Formula/foreman-tools.rb",
  "url": "https://github.com/michaelvgonzaga/foreman-tools/archive/refs/tags/v0.19.0.tar.gz",
  "sha256": "7cbe00c307c16d7b43a5f4826e08233d7d2401b50f3823083b1b57893a3f0090",
  "version": "0.19.0"
}
```

**Errors:** `FormulaNotFound` → `.rb` file not found. `MissingField` → `url`, `sha256`, or `version` not parseable.

---

## validate-hooks

`foreman-tools validate-hooks`

```json
{
  "memorySync": true,
  "autoPush": true
}
```

| Field | Type | Notes |
|---|---|---|
| `memorySync` | bool | Stop hook with `statusMessage: "Syncing memory…"` exists |
| `autoPush` | bool | Stop hook with `statusMessage: "Pushing project commits…"` exists |

**Note:** Returns `false` on missing or malformed `~/.claude/settings.json` (does not error).

**Errors:** `NoHome` → `HOME` env var not set.

---

## gh-release

`foreman-tools gh-release <owner> <repo> <tag> <title> <notes-file>`

```json
{
  "url": "https://github.com/michaelvgonzaga/foreman/releases/tag/v1.15.0"
}
```

**Constraints:** `<notes-file>` must be an absolute path to a readable file. Shells out to `gh release create --notes-file <notes-file>`.

**Errors:** `NotesFileNotFound` → notes file not readable. `GhFailed` → `gh release create` exited non-zero.

---

## cache-store

`foreman-tools cache-store <file-path> <sub-key>` (reads JSON value from stdin)

```json
{
  "path": "/Users/me/foreman/CLAUDE.md",
  "subKey": "guardrails",
  "stored": true
}
```

Hashes the file, writes `<sha256>\n<value>` to the cache store. `stored: false` means the write failed (result is still correct — failure is silently ignored).

**Usage:** `echo '{"rules":[...]}' | foreman-tools cache-store /abs/path sub-key`

**Constraints:** Value capped at 512 KB from stdin.

**Errors:** exit 1 if file not found or `HOME` not set.

---

## cache-fetch

`foreman-tools cache-fetch <file-path> <sub-key>`

Hit:
```json
{"path": "/abs/path", "subKey": "guardrails", "hit": true, "value": {"rules": [...]}}
```

Miss:
```json
{"path": "/abs/path", "subKey": "guardrails", "hit": false, "value": null}
```

| Field | Type | Notes |
|---|---|---|
| `hit` | bool | `true` = file unchanged + value cached → skip the read, use `value` |
| `value` | raw JSON \| null | present only when `hit: true`; raw fragment, not re-encoded |

**Cache semantics:** `hit: false` means either the file changed since the last `cache-store`, or no entry exists for this `file-path:sub-key` pair. Either way: re-read the file and call `cache-store` when done.

**Errors:** exit 1 if file not found or `HOME` not set.

---

## cache-check

`foreman-tools cache-check <file-path>`

```json
{
  "path": "/Users/me/foreman/CLAUDE.md",
  "sha256": "9bc861eaf516f9406374d3672ea83e2f6f53f3dfabeedca5d2c635398d769ea4",
  "changed": false,
  "cached": true
}
```

| Field | Type | Notes |
|---|---|---|
| `path` | string | absolute path as passed |
| `sha256` | string | current file content SHA256 (lowercase hex) |
| `changed` | bool | `true` if hash differs from last recorded value, or no prior record |
| `cached` | bool | `true` if a prior hash was found in the cache store |

**Cache store:** `~/.cache/foreman-tools/<sha256-of-path>` — one file per tracked path. Created automatically. Write failures are silently ignored; the result is still correct, just not persisted.

**Typical use:** Call before re-reading a file. If `changed: false`, skip the read — file is identical to last check. If `changed: true`, read the file.

**Errors:** exit 1 if file not found, unreadable, or `HOME` is not set.

---

## file-hash

`foreman-tools file-hash <file-path>`

```json
{
  "path": "/Users/me/foreman/CLAUDE.md",
  "sha256": "9bc861eaf516f9406374d3672ea83e2f6f53f3dfabeedca5d2c635398d769ea4",
  "bytes": 10538
}
```

| Field | Type | Notes |
|---|---|---|
| `path` | string | absolute path as passed |
| `sha256` | string | lowercase hex SHA256 of file contents |
| `bytes` | int | file size in bytes |

**Constraints:** `<file-path>` must be an absolute path. Cap: 500 MB (files larger than 500 MB return an error).

**Errors:** exit 1 if file not found or unreadable.

---

## context-scan

`foreman-tools context-scan <path>`

```json
{
  "framework": "Zig",
  "entryPoint": "src/main.zig",
  "fileCount": 9,
  "summary": {"source": 4, "test": 0, "config": 2, "docs": 3, "other": 0},
  "topFiles": [
    {"path": "src/root.zig", "bytes": 102091},
    {"path": "src/main.zig", "bytes": 43293}
  ],
  "keyFiles": ["build.zig.zon", "build.zig"],
  "dirs": ["knowledge", "src"]
}
```

| Field | Type | Notes |
|---|---|---|
| `framework` | string | detected language/framework (same as `scan`) |
| `entryPoint` | string \| null | detected main file (same detection as `scan`) |
| `fileCount` | int | total file count in the project |
| `summary` | object | counts by kind: `source`, `test`, `config`, `docs`, `other` |
| `topFiles` | array | top 10 files by byte size, each `{"path": string, "bytes": N}` |
| `keyFiles` | array | key config/entry files (same as `scan.keyFiles`) |
| `dirs` | array | unique subdirectories (same as `scan.dirMap`) |

**Purpose:** Compact alternative to `scan` for context-loading — returns structure summary without the full file inventory.

**Constraints:** `<path>` must be an absolute path. Internally calls `scan` and distills the result.

**Errors:** exit 1 if `<path>` is not found or not a directory.

---

## Schema change policy

Any modification to an existing subcommand's output shape (field rename, type change, enum value addition/removal, field removal) requires:

1. Version bump in `build.zig.zon`
2. New milestone row in `spec.md`
3. Decision log entry in `CLAUDE.md`
4. Update callers in `foreman/CLAUDE.md` subcommand table

Additive changes (new optional fields) are non-breaking if existing callers ignore unknown fields — still document in spec.md but no version bump required.
