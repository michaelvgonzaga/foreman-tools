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

## yaml-query

`foreman-tools yaml-query <file-path> <dot-path>`

Same shape as `json-query` and `toml-query`.

**Constraints:** Indentation-based block-style parser. Handles: nested mappings, sequences (numeric index), inline sequence items (`- key: value`). Does NOT handle: anchors/aliases, multi-line block scalars (`|` / `>`), flow-style collections (`{a: 1}`). Covers GitHub Actions (`.yml`), docker-compose, k8s manifests, Rails config, and similar block-style YAML. File cap: 10 MB.

**Booleans:** `true`/`yes`/`on` → `true`; `false`/`no`/`off` → `false`. `null`/`~`/empty → `null`.

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

## context-rank

`foreman-tools context-rank <root-path> <query>`

```json
{
  "root": "/abs/path",
  "query": "cache invalidation",
  "fileCount": 70,
  "ranked": [
    {"path": "src/cache.zig", "score": 321, "hits": 4, "nameMatch": true, "kind": "source", "bytes": 8192},
    {"path": "CHANGELOG.md", "score": 21, "hits": 4, "nameMatch": false, "kind": "docs", "bytes": 6655}
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `fileCount` | int | total files scanned (before top-15 cap) |
| `ranked` | array | top 15 files by score, descending |
| `ranked[].score` | int | composite: `hits×5 + nameMatch×300 + kind_bonus(1–2)` |
| `ranked[].hits` | int | total occurrences of all query terms (case-insensitive) in first 8 KB of file |
| `ranked[].nameMatch` | bool | any query term appears in the file path |
| `ranked[].kind` | enum | `"source"` `"test"` `"config"` `"docs"` `"other"` |

**Query:** split on spaces; each word is searched independently; up to 8 terms. Case-insensitive literal match.

**Constraints:** `<root-path>` must be absolute. File content read capped at 8 KB per file (content past 8 KB is not scored). `.DS_Store`, binary files, and build artifacts are excluded.

**Errors:** exit 1 if `<root-path>` is not found or not a directory.

---

## context-changed

`foreman-tools context-changed <repo-path> [ref]`

```json
{
  "ref": "HEAD",
  "totalFiles": 2,
  "totalAdditions": 46,
  "totalDeletions": 0,
  "truncated": false,
  "files": [
    {
      "path": "src/main.zig",
      "status": "modified",
      "additions": 46,
      "deletions": 0,
      "diff": "diff --git a/src/main.zig b/src/main.zig\n..."
    }
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `ref` | string | ref used; default `"HEAD"` |
| `totalFiles` | int | total changed files (before truncation) |
| `truncated` | bool | `true` if more than 8 files were changed — only the first 8 are included |
| `files[].status` | enum | `"added"` `"modified"` `"deleted"` `"renamed"` |
| `files[].diff` | string | unified diff capped at 100 lines; JSON-escaped; starts with `diff --git …` header |

**Ref semantics:** `""` = working tree vs index (unstaged only); `"staged"` = index vs HEAD; `"HEAD"` = all uncommitted changes vs HEAD; any other git ref is passed directly.

**Constraints:** First 8 files shown; diff per file capped at 100 lines; not applicable to non-git paths.

**Errors:** exit 1 if git fails (not a git repo, ref not found).

---

## context-evidence

`foreman-tools context-evidence <file-path> <pattern>`

```json
{
  "path": "/abs/path/to/file.zig",
  "pattern": "CacheCheck",
  "fileBytes": 107174,
  "matchCount": 2,
  "chunks": [
    {"startLine": 2074, "endLine": 2104, "content": "pub const CacheCheckResult = struct {\n    ..."}
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `matchCount` | int | total lines containing `pattern` (before chunk cap) |
| `chunks` | array | up to 8 merged context windows; each is `{startLine, endLine, content}` |
| `chunks[].startLine` | int | 1-based first line of this chunk |
| `chunks[].endLine` | int | 1-based last line of this chunk |
| `chunks[].content` | string | lines joined by `\n`; JSON-escaped |

**Search:** case-insensitive literal string match. Each matching line expands to ±10 lines of context; overlapping windows are merged.

**Constraints:** `<file-path>` must be absolute. File capped at 5 MB. Empty pattern returns `matchCount: 0, chunks: []`.

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

## outline

`foreman-tools outline <file-path>`

```json
{
  "path": "/Users/me/project/src/main.py",
  "lang": "python",
  "symbols": [
    {"name": "UserService", "kind": "class",    "line": 1},
    {"name": "__init__",    "kind": "function", "line": 2},
    {"name": "get_user",    "kind": "function", "line": 5},
    {"name": "create_user", "kind": "function", "line": 8},
    {"name": "handle_request", "kind": "function", "line": 11}
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `path` | string | absolute file path (echoed from input) |
| `lang` | string | detected language: `"go"`, `"python"`, `"javascript"`, `"typescript"`, `"rust"`, `"zig"`, `"ruby"`, `"java"`, `"kotlin"`, `"kotlin"`, `"csharp"`, `"swift"`, `"php"`, or `"unknown"` |
| `symbols` | array | extracted symbols, in source order |
| `symbols[].name` | string | symbol identifier |
| `symbols[].kind` | string | one of: `"function"`, `"class"`, `"struct"`, `"enum"`, `"trait"`, `"interface"`, `"type"`, `"module"`, `"impl"` |
| `symbols[].line` | int | 1-based line number |

**Constraints:** Line-by-line pattern matching; no full AST. Top-level and nested definitions both appear (no indentation-based filtering). Capped at 200 symbols. Inline/comment lines skipped. File cap: 10 MB.

**Languages:** Go (`func`), Python (`def`/`class`), JavaScript (`function`/`class`), TypeScript (adds `interface`/`type`/`enum`), Rust (`fn`/`struct`/`enum`/`trait`/`impl`), Zig (`fn`/`const … = struct|enum`), Ruby (`def`/`class`/`module`), Java, Kotlin, C#, Swift, PHP. Returns `"unknown"` lang with empty `symbols` for unsupported extensions.

**Errors:** `FileNotFound`

---

## deps

`foreman-tools deps <root-path>`

```json
{
  "manifest": "package.json",
  "format": "npm",
  "totalCount": 48,
  "deps": [
    {"name": "react",      "version": "^18.2.0", "dev": false},
    {"name": "typescript", "version": "^5.0.0",  "dev": true}
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `manifest` | string | detected manifest filename (relative) |
| `format` | string | `"npm"` \| `"cargo"` \| `"go"` \| `"pip"` |
| `totalCount` | int | total dep count before the 100-item cap |
| `deps[].name` | string | package name |
| `deps[].version` | string | version constraint as written in manifest; `""` if unspecified |
| `deps[].dev` | bool | true for devDependencies (npm) / [dev-dependencies] (cargo); always false for go/pip |

**Detection order:** `package.json` → `Cargo.toml` → `go.mod` → `requirements.txt`. First found wins.

**Constraints:** Capped at 100 deps. `<root-path>` must be an absolute path. File cap: 10 MB.

**Errors:** `NoManifestFound` (exit 1), `InvalidJson` (exit 1 for malformed package.json)

---

## run-tests

`foreman-tools run-tests <path>`

```json
{
  "path": "/abs/path/to/project",
  "framework": "jest",
  "command": "npx jest --ci",
  "success": false,
  "passed": 42,
  "failed": 3,
  "skipped": 1,
  "duration_ms": 4821,
  "failures": [
    {
      "file": "src/user.test.ts",
      "line": 47,
      "test": "should return 404 for unknown user",
      "message": "Expected: 404\nReceived: 200"
    }
  ],
  "truncated": false
}
```

| Field | Type | Notes |
|---|---|---|
| `path` | string | absolute project root as passed |
| `framework` | string | detected: `"jest"` `"pytest"` `"go"` `"cargo"` `"zig"` `"bats"` `"unknown"` |
| `command` | string | exact command executed |
| `success` | bool | `true` if all tests passed (exit 0) |
| `passed` | int | number of passing tests; 0 if framework output doesn't report counts |
| `failed` | int | number of failing tests |
| `skipped` | int | number of skipped/pending tests |
| `duration_ms` | int | wall-clock run time in milliseconds |
| `failures` | array | structured failures; capped at 50 |
| `failures[].file` | string | relative path to the test file |
| `failures[].line` | int | 1-based line number; 0 if not reported |
| `failures[].test` | string | test name / describe block + test name |
| `failures[].message` | string | failure message; multiline, JSON-escaped |
| `truncated` | bool | `true` if more than 50 failures were found — only the first 50 are included |

**Detection order:** `package.json` (jest in deps or scripts.test) → `pytest.ini` / `conftest.py` / `pyproject.toml [tool.pytest]` → `go.mod` → `Cargo.toml` → `build.zig` → `*.bats` in `test/` or `tests/`. First match wins.

**Framework commands:**
- `jest` → `npx jest --ci`
- `pytest` → `python -m pytest -q`
- `go` → `go test ./...`
- `cargo` → `cargo test`
- `zig` → `zig build test`
- `bats` → `bats test/` (or `tests/`)

**Constraints:** `<path>` must be absolute. Timeout: 120s. Framework binary must be in PATH or resolvable from project root.

**Errors:** exit 1 if no recognizable test framework detected (`framework: "unknown"`, message on stderr). exit 1 if the test command itself cannot be launched (not if tests fail — test failures exit 0 with `success: false`).

---

## build

`foreman-tools build <path>`

```json
{
  "path": "/abs/path/to/project",
  "tool": "cargo",
  "command": "cargo build",
  "success": true,
  "errors": [],
  "warnings": [
    {
      "file": "src/main.rs",
      "line": 42,
      "col": 5,
      "message": "unused variable `x`"
    }
  ],
  "duration_ms": 3201,
  "truncated": false
}
```

| Field | Type | Notes |
|---|---|---|
| `path` | string | absolute project root as passed |
| `tool` | string | detected: `"cargo"` `"go"` `"zig"` `"npm"` `"yarn"` `"make"` `"unknown"` |
| `command` | string | exact command executed |
| `success` | bool | `true` if build exited 0 |
| `errors` | array | structured errors; capped at 50 |
| `errors[].file` | string | relative path; `""` if not reported |
| `errors[].line` | int | 1-based line; 0 if not reported |
| `errors[].col` | int | 1-based column; 0 if not reported |
| `errors[].message` | string | error text; multiline, JSON-escaped |
| `errors[].severity` | string | `"error"` or `"warning"` (errors array only contains `"error"`) |
| `warnings` | array | structured warnings; capped at 20 |
| `warnings[].file` | string | relative path; `""` if not reported |
| `warnings[].line` | int | 1-based line; 0 if not reported |
| `warnings[].col` | int | 1-based column; 0 if not reported |
| `warnings[].message` | string | warning text |
| `duration_ms` | int | wall-clock build time in milliseconds |
| `truncated` | bool | `true` if more than 50 errors or 20 warnings were found |

**Detection order:** `Cargo.toml` → `go.mod` → `build.zig` → `package.json` (scripts.build) → `yarn.lock` → `Makefile`. First match wins.

**Build commands:**
- `cargo` → `cargo build`
- `go` → `go build ./...`
- `zig` → `zig build`
- `npm` → `npm run build`
- `yarn` → `yarn build`
- `make` → `make`

**Error parsing per tool:**
- `cargo` / `rust` → `error[E####]: message\n --> file:line:col`
- `go` → `file:line:col: message`
- `zig` → `file:line:col: error: message`
- `npm` / `yarn` / `tsc` → `file(line,col): error TSxxxx: message` or `file:line:col - error`
- `make` → `Makefile:line: *** message`

**Constraints:** `<path>` must be absolute. Timeout: 300s. Build tool must be in PATH.

**Errors:** exit 1 if no recognizable build system detected. Build failure (non-zero build exit code) exits 0 with `success: false` and populated `errors`.

---

## device-scan

`foreman-tools device-scan`

```json
{
  "profile_id": "apple_m3_pro_36gb_macos_arm64",
  "hardware": {
    "cpu": "Apple M3 Pro",
    "cores": 11,
    "ram_gb": 36,
    "os": "darwin",
    "arch": "arm64"
  },
  "tools": {
    "zig":           { "present": true,  "version": "0.16.0", "path": "/opt/homebrew/bin/zig" },
    "git":           { "present": true,  "version": "2.47.1", "path": "/usr/bin/git" },
    "gh":            { "present": true,  "version": "2.62.0", "path": "/opt/homebrew/bin/gh" },
    "brew":          { "present": true,  "version": "4.4.0",  "path": "/opt/homebrew/bin/brew" },
    "node":          { "present": false, "version": null,      "path": null },
    "python3":       { "present": true,  "version": "3.12.0", "path": "/opt/homebrew/bin/python3" },
    "go":            { "present": false, "version": null,      "path": null },
    "cargo":         { "present": false, "version": null,      "path": null },
    "foreman_tools": { "present": true,  "version": "1.26.0", "path": "/opt/homebrew/bin/foreman-tools" }
  },
  "optimal": {
    "zig_build_flags": "-Doptimize=ReleaseSafe -Dcpu=apple_m3",
    "bottleneck": "git_io",
    "git_spawn_ms_estimate": 20
  },
  "shell": "zsh",
  "scanned_at": "2026-06-30T12:00:00Z"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `profile_id` | string | stable slug from cpu+ram+os+arch; used as community profile key |
| `hardware.cpu` | string | from `sysctl machdep.cpu.brand_string` |
| `hardware.cores` | int | from `sysctl hw.physicalcpu` |
| `hardware.ram_gb` | int | from `sysctl hw.memsize` / 1073741824 |
| `hardware.os` | string | `"darwin"` on macOS |
| `hardware.arch` | string | `"arm64"` or `"x86_64"` |
| `tools.*` | object | `present` bool; `version`/`path` null when not present |
| `optimal.zig_build_flags` | string | derived from arch; `apple_m3` on M3, `apple_m4` on M4, generic arm64 otherwise |
| `optimal.bottleneck` | string | always `"git_io"` for macOS foreman-tools; future: `"disk_io"` or `"cpu"` |
| `optimal.git_spawn_ms_estimate` | int | estimated cost per git subprocess in ms |
| `shell` | string | from `$SHELL` |
| `scanned_at` | string | ISO 8601 UTC timestamp |

**Community contribution:** The `profile_id` + `hardware` + `optimal` + `tools[*].{present, version}` fields (no paths) form the public-safe subset. Foreman shows a diff of what will be shared and asks for consent before pushing to the `foreman-env` repo. Paths are never included in the community profile — they often contain usernames.

**Errors:** exit 1 if `sysctl` is unavailable. All tool checks are best-effort — missing tool = `present: false`, no error.

---

---

## `plugin-run <name> [args...]`

Executes a plugin and returns its JSON stdout verbatim.

**Success** — the script's own JSON output (shape is plugin-defined).

**Error cases** (exit 1):
```json
{ "error": "plugin not found" }
{ "error": "invalid manifest: missing field 'entry'" }
{ "error": "worker failed: <stderr from script>" }
```

| Field | Type | Notes |
|-------|------|-------|
| output | any | verbatim JSON stdout from the plugin script |

---

## `plugin-list`

```json
{
  "plugins": [
    { "name": "summarize-pr", "lang": "python", "description": "fetch a PR and return a structured summary", "args": "<pr-url>", "entry": "run.py" }
  ],
  "count": 1,
  "skipped": []
}
```

| Field | Type | Notes |
|-------|------|-------|
| `plugins` | array | one entry per valid plugin in `~/.foreman/plugins/` |
| `plugins[].name` | string | directory name under `~/.foreman/plugins/` |
| `plugins[].lang` | string | any `worker-run` runtime |
| `plugins[].description` | string | from manifest |
| `plugins[].args` | string | hint string for `route`/`capability-check` |
| `plugins[].entry` | string | script filename relative to plugin directory |
| `count` | int | number of valid plugins |
| `skipped` | array | paths of directories with missing or malformed manifests |

**Errors:** exit 1 only if `~/.foreman/plugins/` cannot be opened. Missing/malformed individual manifests are skipped and listed in `skipped`.

---

## Schema change policy

Any modification to an existing subcommand's output shape (field rename, type change, enum value addition/removal, field removal) requires:

1. Version bump in `build.zig.zon`
2. New milestone row in `spec.md`
3. Decision log entry in `CLAUDE.md`
4. Update callers in `foreman/CLAUDE.md` subcommand table

Additive changes (new optional fields) are non-breaking if existing callers ignore unknown fields — still document in spec.md but no version bump required.
