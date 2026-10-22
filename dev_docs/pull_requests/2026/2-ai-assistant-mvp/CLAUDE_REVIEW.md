# Claude Review — PR #2

- **Reviewer:** Claude Sonnet 5.5
- **PR title:** AI assistant MVP: chats, read-only tool calling with the session's rights, settings, limits, attachments, chat panel
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-10-22
- **Merge commit:** `273bcac` (merged into `main`)
- **Range reviewed:** `273bcac^1...273bcac` — about 15k lines, 44 modules under `lib/`

## Overall Assessment

**Verdict: APPROVE. Risk: LOW.**

Baseline before any change: `mix test` — **667 tests, 0 failures, 7 excluded**
(`@tag :poppler` / `:imagemagick`, excluded where the program is missing); `credo --strict`
clean; `compile --warnings-as-errors`, `gettext.extract --check-up-to-date`,
`deps.unlock --check-unused` and `hex.audit` clean. Only `dialyzer` failed (see F1).

## How it was reviewed

This is a large PR, so the review read in full the modules where a mistake costs the most,
and spot-checked the rest with `rg` for the usual hazards (`String.to_atom`,
`binary_to_term`, `raw/1`, `{:safe, _}`, `Logger` calls that interpolate terms).

**Read in full:** `Turns` (start, stop, settle), `Turns.Locks`, `Turns.Monitor`,
`Turns.Runner`, `Turns.Tools`, `Turns.History`, `Conversations`, `Limits`, `Spend`,
`Web.Access`, `Web.Dock` (every callback), `Web.Markdown`, `Attachments` (add, store,
read, url), `Attachments.Cmd`, `.Unzip`, `.Work`, `UserConfig` (admin and personal writes).

**Not read line by line:** `Attachments.Extract`, `.Processor`, `.Detect`, `.Slots`,
`.Jpeg`, `Prompt`, `Models`, `Config`, `UserDeletion`, `Web.SettingsLive`,
`Web.UsersLive`, `Web.SpendingLive`, `Web.Dock.Panel`/`Components`/`Texts`, the schemas and
the migration body. For the three admin LiveViews only the permission re-checks were
confirmed (every `handle_event` that writes goes through `Access.may_manage?/1`, and the
Owner-only ones also through `Access.owner?/1`).

## What was verified and holds

- **Locks:** both locks are one atomic statement each, taken in one transaction; release is
  by `busy_turn_ref`, so a late release cannot free a newer turn; the TTL uses the database
  clock; the running turn re-checks `held?/3` before every round and tool call. Lock TTL
  (deadline + 60 s) exceeds handshake + deadline + stop grace (5 + 30 s) with the defaults.
- **Stop/deadline:** a request first, a kill only after the grace period, so a model call
  under way still writes its journal row and the limits see its cost. A stop for a turn on
  another node goes out over PubSub with the turn ref only. Monitor ordering (the task's
  `:turn_running` precedes its `:DOWN`) makes the `running?` flag reliable.
- **Rights:** every `Conversations` call rebuilds the scope from the live session, refuses
  impersonation first, and answers `:not_found` for another user's chat. A client never reads
  a raw tool result or tool arguments (`for_client/1`). The executor is called with
  `allow: :read` and only names shown in the same round reach it; control fields are
  dropped from both schemas and arguments. Executor results are always JSON maps
  (`Executor.run/1` rejects anything else), so `Tools.fit/2`'s `is_map` guard cannot fail.
- **Money:** counted from the AI journal (`user_uuid` + `metadata.source = "agent"`), every
  row with a cost, soft-deleted chats still count for the turn limit.
- **Markdown:** no `<img>`, no raw HTML, only `http(s)` links with an ASCII host, every text
  escaped, `rel="noopener noreferrer nofollow"`, the domain written next to the link.
- **Attachments:** workbook parts are inflated chunk by chunk against one budget
  (declared sizes never believed); external programs run under `timeout`; scratch
  directories are random, `0700`, created with `File.mkdir/1`, and a pre-planted symlink or
  foreign-owned `pk_agent_att` makes the scratch space unavailable instead of used.
- **Logging:** no chat text reaches `Logger`; every handler that could crash with the draft
  in its arguments is `guarded/2` or `safely/1`, and `format_status/1` redacts the monitor.

## Findings

### F1 — IMPROVEMENT (gate) — `dialyzer` fails on the generated Gettext backend — FIXED

`mix precommit` stopped at `dialyzer` with six `call_without_opaque` warnings, all at
`lib/phoenix_kit_agent/gettext.ex:1` — the one-line `use Gettext.Backend`. This is the known
Gettext 1.0 + Expo 1.1 opaque-type false positive in generated code. Fixed with the same
scoped `.dialyzer_ignore.exs` entry the sibling packages use (see PR #1 review).

### F2 — BUG - LOW — `Monitor.finish/2` broadcast was not guarded — FIXED

`finish/2` wrapped the lock release and the closing notice in `safely/1`, but the final
`PubSub.broadcast({:agent_turn_finished, ...})` was bare. `Phoenix.PubSub.broadcast/3`
raises `ArgumentError` when the PubSub server is not running. `finish/2` has a fallback that
runs it **inside the monitor** when no task can be started, and there an exception would
crash the monitor and, through `:rest_for_one`, every running turn — the very thing
`listen/2` and `broadcast_stop/1` already guard against. Reaching it needs the task
supervisor and PubSub both down, so the practical risk is small; the fix is one `safely/1`.
No new test: the harness starts `PhoenixKit.PubSub.Manager` once, linked to the test
helper, so a test cannot stop it without breaking every other test.

### F3 — IMPROVEMENT - MEDIUM — a turn reads the whole chat to use 24k characters — NOT FIXED

`Turns.history/3` loads every `user`/`assistant` message and every ready, sent attachment
(with its `extracted_text`) of the chat on every turn; `History.build/4` then keeps only the
newest `agent_history_chars` (default 24 000). Work per turn therefore grows with the age of
the chat, not with the window. Not fixed: the window rule ("the first message that does not
fit ends it") and the per-message sharing of the limit between attachments depend on the
whole entry list, so a bounded or paged read has to reproduce them exactly. Do it when a long
chat shows up in a profile — the likely shape is reading newest-first in pages of ~50
messages, joining only those messages' attachments, and stopping at the first page that
ends the window.

### F4 — NITPICK — `unsent_files` cap is soft under concurrency — NOT FIXED

`Attachments.reserve/4` locks one chat (`FOR UPDATE`) and then counts the user's unsent
files across all chats. Two uploads into two different chats can both read the count below
`Bounds.unsent_files` and both insert, so the cap can be exceeded by the number of racing
uploads. It is a resource bound, not a security boundary, and the per-chat cap is exact.

### F5 — NITPICK — a limit notice is lost if its delivery fails — NOT FIXED

`Limits.first?/5` inserts the once-per-period event row before the notification is sent, so
if `Notifications.upsert_inapp/3` or `create_many/2` raises (logged by `safely/1`), the
notice is not retried that period. This is the documented trade-off ("a notice is never worth
a turn"); the user still gets the refusal in the chat itself.

## Tests

No test added for F1 (tooling) and F2 (see above). Final results are in the commit message
and the chat reply.
