# Codex Review — PR #3

- Reviewer: Codex
- Reviewed: 2026-10-23
- PR: Chat list: the time of a chat in the user's language
- Author: Tymofii Shapovalov (`timujinne`)
- Merge: `c8faa17`; rechecked with Claude's follow-up `54abd09`.

## Findings

No additional defect found. The cached site-time-zone read in `54abd09` is appropriate; core falls back to the database when its cache is unavailable. The test harness does not start that cache, which explains its warnings during tests.

Reviewed the component and panel changes, core's time-zone conversion and settings-cache reader, the plural translations, and the chat-time integration test. Absolute tooltips retain the site time zone, relative labels use this module's Gettext backend, future timestamps read as “just now”, and missing timestamps stay a dash. Relative labels are snapshots of the server render; no browser hook replaces them in English.

## Validation

The final validation results are recorded in the accompanying PR #6 Codex review. No product changes were needed for this PR.
