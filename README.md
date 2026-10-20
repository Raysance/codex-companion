# Codex Companion

A native macOS companion for local Codex history: token usage, quota timelines, input vocabulary, and provider migration. A single app and Swift package; provider migration is an integrated tool.

## Activity

- **Overview** — daily activity, cache reuse, input volume, and active chats.
- **Token usage** — chat and model summaries; inspect user turns and individual model requests, including input, cache, output, reasoning, and effort. Export the filtered requests to CSV.
- **Quota** — select the actual recorded window, inspect observed consumption, allowance equivalents, inferred resets, and window history. Separate plans/limit categories remain separate.
- **Your inputs** — language-aware Chinese/English word cloud, occurrence and document frequencies, character volume, and searchable local input history.
- **Storage** — coverage, missing logs, runtime versions, compatibility checks, and optional migration-backup discovery.

Choose Today, 7 days, 30 days, All history, or a custom date range. Project filters apply to token/input activity; quota snapshots remain account-wide.

Analysis reads local files and databases without changing Codex data. Input text stays in memory and is not included in request CSV exports. No credentials are read, no API is called, and there is no background upload.

## Provider migration

1. Choose **Storage → Choose folder** if your Codex home differs from `~/.codex` (`CODEX_HOME` is honored).
2. Open **Provider migration** and choose source/target providers.
3. Search/filter and select sessions with available local logs.
4. Quit Codex, including CLI/app-server processes, then **Check again**.
5. Review and confirm **Back up and migrate**.

The app updates known provider metadata in the selected JSONL files, the runtime `threads` table, and **only `host_id = 'local'`** entries in the desktop catalog. Cloud catalog entries, messages, token records, model names, authentication, and configuration are preserved. The target provider must support the sessions' existing model names.

Storage is schema-checked before migration. The highest `state_N.sqlite` in the configured runtime directory is discovered; `sqlite_home` and `CODEX_SQLITE_HOME` are supported. Unknown required schemas block migration rather than guessing. The provider declaration reader supports standard bare, single-quoted, and double-quoted `[model_providers.<id>]` table names; it is intentionally not a complete TOML implementation.

Backups are written beneath `CODEX_HOME/backup/provider-migrator-<timestamp>-<id>/`. They include consistent SQLite snapshots, original selected logs, and a manifest with original database paths. Configuration and credential files are not copied. Failure restores databases through SQLite, avoiding stale WAL replay. Keep the backup until the sessions have reopened successfully. If Codex starts during a migration, automatic restore is withheld to avoid overwriting active writes; quit Codex before using the backup.

## Requirements and build

- macOS 14+
- Swift 6.1+ / a compatible Xcode or Command Line Tools SDK
- System SQLite, SwiftUI, Charts, NaturalLanguage, CryptoKit; no third-party packages

```bash
swift run CodexCompanion --self-test
./scripts/build-app.sh
```

The signed-for-local-use app and ZIP are written to `dist/`. The build uses the current machine's architecture; it is not a universal binary. Ad-hoc signing does not provide Apple notarization.

Read-only audit, suitable for scripts:

```bash
swift run CodexCompanion --audit
swift run CodexCompanion --audit --home /path/to/codex-home --include-backups
```

The audit emits aggregate JSON without input text. Exit codes: `0` supported migration schema, `2` migration unsupported (analytics may still be available), `1` read/argument failure.

Synthetic interface preview:

```bash
swift run CodexCompanion --demo
```

Demo mode never reads the real Codex home and cannot migrate.

## Reading the numbers

- Cached input is **part of input**; reasoning is **part of output**. Total is input + output.
- Request records are deduplicated by `response_id`, including copied/forked logs. Modern records take precedence over their `token_count` mirrors. Legacy-only records are marked as estimates.
- One user message can trigger many model requests. Turn-level grouping is distinct from visible assistant messages.
- Input volume means characters/segmented words, **not** the exact tokens of the human text alone. Known app context wrappers and non-user content kinds are excluded. Subagent prompts are excluded from input analysis, while their model usage remains included.
- Quota percentages come from recorded snapshots, not a token-to-allowance conversion. Small reset timestamp jitter and late responses from old windows are ignored. Missing initial baselines exclude unobserved usage.
- Chat/turn quota figures are estimates only when an observed increment has activity from one local chat/turn. Concurrent, other-device, and otherwise ambiguous consumption stays unassigned. Logs do not establish whether a reset was manually redeemed. Identical plan labels cannot identify account changes.
- The log index is not a replacement for deleted rollouts. Coverage and legacy estimates are shown explicitly; “All history” means all discovered records.

See [data and architecture](docs/DATA.md) and the [compatibility audit](docs/COMPATIBILITY.md).

## License

MIT
