# Data and architecture

## Boundaries

`StorageSupport` handles bounded JSONL streaming, read-only SQLite queries, and the limited provider/storage configuration reader. `CodexStore` owns compatibility checks and the only mutation path. `AnalyticsStore` ingests data without writes. `QuotaEngine` reconstructs observed allowance windows. `InputAnalysis` cleans human input and segments vocabulary with Apple's local NaturalLanguage framework. Sendable value models pass background results to the main-actor `AppModel`; SwiftUI views only render those results.

The report and input text live in memory. Refresh rereads history; date/project/quota filters rebuild a slice off the main actor. There is no persistent content cache or service dependency.

## Token records

Preferred event:

```json
{
  "timestamp": "2026-10-20T12:00:00.000Z",
  "ordinal": 19,
  "type": "token_usage_record",
  "payload": {
    "thread_id": "thread-id",
    "turn_id": "turn-id",
    "session_id": "session-id",
    "root_turn_id": "root-turn-id",
    "response_id": "response-id",
    "usage": {
      "input_tokens": 100,
      "cached_input_tokens": 80,
      "cache_write_input_tokens": 0,
      "output_tokens": 20,
      "reasoning_output_tokens": 5,
      "total_tokens": 120
    },
    "turn_token_usage": {},
    "thread_token_usage": {}
  }
}
```

The two cumulative objects have the same six token keys in actual logs. They are not summed. Per-request `usage` is the source of totals; response IDs deduplicate replay/copies. Model/effort come from the matching `turn_context`. A fork's inherited response retains its original request identity.

`event_msg` / `token_count` contains `info.last_token_usage`, `info.total_token_usage`, `info.model_context_window`, and `rate_limits`. The two usage objects repeat the six token keys. These are mirrors of modern requests or a fallback for older logs. For legacy cumulative streams, positive cumulative differences prevent flat snapshots from counting the same request repeatedly. Counter resets fall back to the last request. The first legacy snapshot uses last-request usage rather than claiming unseen prior cumulative usage. Fallback records remain estimates.

Cumulative counters and current context occupancy are different quantities. Repeated context is processed on multiple requests; summing inputs can legitimately exceed the model's context-window capacity. Neither the current context capacity nor `threads.tokens_used` is used as a billing total.

## Quota records

Each non-null `primary` or `secondary` window provides `used_percent`, `window_minutes`, and `resets_at` (Unix seconds). Window duration, not its primary/secondary position, identifies weekly versus shorter limits. Scope is separated by limit ID, plan label, and duration. Account identifiers are not available in these snapshots, so an account change within identical labels cannot be reconstructed reliably.

A forward reset-time change exceeding 120 seconds starts a new observed window. Earlier-window late arrivals are discarded. Within a window, a high-water mark prevents rounding/stale-response oscillations from inflating usage. Consumption in the selected period is each window's observed peak minus its preceding baseline, summed across windows. No baseline means the first observed value is excluded unless a reset was observed. The first sample after a reset bounds the reset time; it is not the exact action time. Sampling gaps and integer rounding prevent exact billing reconciliation.

Quota attribution links a positive observed increment only if the interval contains requests from exactly one local chat/turn. It remains an estimate: other devices and unlogged activity are invisible. The global quota total is never multiplied by a chat's token share to fabricate precise allocation. A project filter does not filter the account-wide quota ledger.

`credits`, `individual_limit`, and restriction flags are present in raw events but are not converted into costs. Null means unavailable, not zero. This app does not redeem resets or change subscriptions.

## Human input

Modern `response_item` user messages expose `internal_chat_message_metadata_passthrough.turn_id`, `create_time`, and `content_item_kinds`. Human `user.*` content is kept; environment and additional-content records are excluded. Legacy `event_msg.user_message` and response-item copies are paired within a log, preserving the stable response-item ID when available. Unpaired inputs from either format remain included. Stable message IDs (or timestamp/content hashes) deduplicate copied records. Known wrapper-only context is removed, without stripping arbitrary human-authored XML. Agent-origin prompts are excluded.

Characters include spaces and punctuation. Word counts use local language-aware segmentation. Word-cloud frequencies lowercase terms and omit common Chinese/English stopwords, pure numeric terms, and very long tokens. Document frequency counts distinct input records containing the term. Original input text is available only in the local UI; CSV exports contain request usage, not prompts or chat titles.

## Known limits

Partial live JSONL tails and malformed records are skipped and counted. Unreadable files and indexed sessions without logs are reported. Backup discovery is optional and restricted to session log subdirectories. Old schemas can lack IDs, timestamps, or usage; the app does not invent missing history. Legacy copied logs without stable identifiers can remain ambiguous.

The underlying local storage is undocumented and can change. Schema checks protect migrations, but do not validate provider reachability or guarantee that a target supports historical model names.

## References

- [Official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Official prompt caching semantics](https://developers.openai.com/api/docs/guides/prompt-caching)
- [Official reasoning token semantics](https://developers.openai.com/api/docs/guides/reasoning)
- [Official Codex limits and credit pricing](https://learn.chatgpt.com/docs/pricing)
