# Future product ideas

Recorded 2026-10-14; updated 2026-10-15. These ideas are for later discussion, not instructions to
implement them or change the current roadmap.

## Tags as inline hashtags

The user likes Obsidian's approach: tags appear directly in the Markdown source
as hashtags, for example:

```md
Notes from today's reading. #research #swift
```

Prefer exploring this portable, visible representation when implementing tags.
SQLite could index tags found in Markdown while the hashtags remain in the note
itself. Durable manual tags must remain recoverable from portable files under
the accepted disposable-database policy; do not introduce irreplaceable SQLite-only tags.

Questions for that work: hashtag syntax, nested tags, distinguishing tags from
headings and code, and how suggested tags become user-approved note content.
Model processing must preserve user-authored tags.

## Deferred tag features

Deferred by the user on 2026-10-15. These are preserved requirements for later,
not active prerequisites for filename generation, summaries, or search. Original
roadmap identifiers are retained below for traceability; assign new execution
positions when the user requests tags. Hashtag syntax and UI remain undecided.

### Former 2.4 Manual tags and metadata protection

1. Define manual tag representation with the disposable-database policy. The user prefers inline Markdown hashtags; exact syntax and editing behavior remain to be designed.
2. Keep durable manual tags in the portable files if adopting hashtags, and rebuild their SQLite index from those files. A database backup/restore system is not a prerequisite. Do not silently introduce irreplaceable SQLite-only user data.
3. Add normalized tags and note-tag relationships, with manual/model provenance, constraints, and transactional updates.
4. Add minimal optional tag editing/filtering; writing never requires tags. Restore must preserve manual associations and report unresolved files.

**Acceptance:** users can add/remove/filter tags under the chosen representation, and database loss follows the accepted disposable-index policy. Test normalization, duplicates, file/index consistency, migrations, and rebuilding. No AI tag generation yet.

### Former 3.3 Suggested tags

- Generate suggested tags through the existing processing pipeline; extend schema/provenance only as needed.
- Integrate suggestions with the tag UI while keeping manual tags distinguishable and protected from model refreshes.

**Acceptance:** retries do not duplicate tags and reprocessing never removes manual choices; test both behaviors.

When tags return, implement manual representation/indexing before generated tags.
Revisit the integrated tag migration/rebuild/reconciliation checks that belonged
to the original Phase-2 exit, including protection of manual associations. Keep
generated suggestions separate from user-authored portable tag content.

## Separate saving from recomputing derived data

Original proposed keyboard commands (superseded on 2026-10-17):

| Shortcut | Proposed action |
| --- | --- |
| ⌘S | Save the Markdown note. |
| ⌘⇧S | Recompute the current note's summary, suggested tags, and embeddings. |

The intent is to let the user save writing independently and explicitly request
fresh derived data when desired. Recomputing should run in the background and
preserve the note and manual tags if processing fails.

Confirmed latest policy on 2026-10-17: **⌘S with edits to an existing file only saves text;
clean ⌘S accepts a ready preview, or silently does nothing without one. First save of a new draft requests a filename preview.
⌘⇧S explicitly regenerates without applying; Apply accepts the preview.**
The previous proposal above is retained for history, not active shortcut behavior.
Future embeddings must run after every successful changed save, including ordinary
and automatic saves, independently of naming. Clean regeneration/acceptance must
not trigger embeddings. Embeddings remain unimplemented. Triggers for other
future outputs (summaries/tags) remain to be designed when requested.
