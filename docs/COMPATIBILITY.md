# Provider migration compatibility audit

Audited 2026-10-20 against local storage emitted by Codex runtimes `0.162.0-alpha.*` and `0.163.0-alpha.10.2`, with desktop catalog storage used by app `26.1013.40934`. This is a storage compatibility audit, not a claim to support every future runtime or an end-to-end provider connection test.

## Findings in v1.0.1

| Finding | Effect | Change |
| --- | --- | --- |
| Catalog keyed by host + thread, but writes matched thread only | A matching remote/cloud entry could be modified | Update and verify `host_id = 'local'` only |
| Exact compact JSON string replacement | Valid spaced JSON could be missed; arbitrary structured payloads with matching keys could be touched | Parse records and update only known execution metadata locations |
| Fixed `state_5.sqlite` and fixed optional columns | Custom/new storage layouts could fail or be missed | Discover highest state version and configured runtime directory; inspect schema |
| Read-only opening of closed WAL stores can fail on macOS SQLite | A closed store could become unscannable | Retry an immutable read only with an empty/absent WAL and unchanged main file |
| Database restore copied only the main SQLite file | Remaining WAL pages could replay old changes | SQLite-native `.backup` and `.restore` |
| Restore errors were swallowed | The UI could hide an unsuccessful recovery | Report restore failure and backup location |
| Selection was not revalidated | A stale provider/path selection could be applied | Re-read current state before backup; validate local log paths and IDs |
| Catalog provider values not verified | Database integrity alone could pass a logical mismatch | Verify provider state in both stores |
| Process detection checked desktop names only | A running CLI/app-server could race the migration | Include CLI/app-server executables; repeat checks before writes |
| Configuration copied into every backup | Unnecessary configuration/possible secrets duplication | Back up only databases, selected logs, and manifest |

## Scope of writes

Only known `session_meta`/`turn_context` provider metadata and `thread_settings_applied.thread_settings` provider metadata are rewritten. Message content, tool results, usage records, models, and timestamps retain their values. Changed metadata lines may be reserialized with different spacing/key order. Unchanged lines retain their text. The SQLite transactions change provider/catalog-observation metadata only.

The app must be closed before migration. If it starts mid-operation, automatic restore is withheld rather than writing over active state. Backups are recovery material, not a power-loss-proof distributed transaction: JSONL and multiple SQLite files cannot commit as a single filesystem transaction. Do not delete a backup before reopening the selected sessions.

## Validation

The built-in fixture suites cover metadata isolation/escaping, local versus cloud catalog rows, transactional failure and WAL restore, stale selections, unsupported schemas, custom/versioned storage, modern and legacy token deduplication, input-context removal, Chinese/English segmentation, quota jitter, stale windows, reset detection, and missing-baseline handling. Fixtures are temporary directories; self-tests never migrate the real Codex home.

`--audit` performs read-only discovery and analysis on a selected home. Analytics remain available when migration schemas are unsupported. A successful audit does not mean every indexed chat has a surviving log, nor that the provider endpoint was contacted.
