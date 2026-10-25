# Claude Review — PR #6

- **Reviewer:** Claude Sonnet 5.5
- **PR title:** Writes the user confirms in the chat
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-10-23
- **Merge commit:** `3dcff9d` (merged into `main`)
- **Range reviewed:** `3dcff9d^1...3dcff9d` — 41 files, about 7.7k lines added, of which about
  3.3k are tests and 1.4k catalogues

## Overall Assessment

**Verdict: APPROVE. Risk: MEDIUM (it lets a model reach writes), well contained.** One low
finding fixed; the rest are recorded.

## How it was reviewed

**Read in full:** `Confirmations` (all of it), and the diffs of `Turns.Runner`, `Turns.Locks`,
`Turns.History`, `Turns.Tools`, `Turns`, `Conversations`, `Migrations` (V2), `Schemas.Message`,
`Prompt`, `Web.Dock`, `Web.Dock.Components`, `Web.Dock.Panel`.

**Not read line by line:** `Web.ToolAvailability` (a read-only card), the texts, the
catalogue churn, and the tests beyond the lock/keep one.

## Findings

### F1 — BUG, LOW — a keeper that fails to start leaked the user's lock for 30 s (fixed)

`Confirmations.locked/2` took the lock, then ran `{:ok, keeper} = Task.Supervisor.start_child(...)`
**outside** the `try … after`. If that start failed (the supervisor not running), the `MatchError`
or exit skipped `Locks.release_user/2`, and the user could not start a turn or click for the
30 s hold. **Fix:** the start moved inside the outer `try`, so the release always runs. No test:
the only way to fail the start is a missing supervisor, which the test environment does not
let a single test remove safely.

### F2 — NITPICK (accepted) — the module's own "no write tool" layer is gone

`Tools.for_model/1` used to drop every `write_tool?` tool whatever list it got ("a regression
in core cannot show a write tool to the model"). The PR removes it on purpose: the list is
core's (`visible_for/3`, `allow: :all`), the writes of a module show only where core's
`api_session_write_modules` allows, and a write is held by core for a click. What stands
between a model and a write is therefore core alone, as `AGENTS.md` says. Not changed; the
docs state it.

### F3 — NITPICK — a person can type the system's confirmation phrase

`History` gives the model `[confirmation] done: <tool>` as a `user` message, and the prompt
tells the model to believe it. A user can type the same text themselves. It changes only what
the model *says*: a write runs from a click on a card core holds, never from the model's
claim, and the person is the one who would be misled. Not changed.

### F4 — RELEASE NOTE — the pins are fork branches

`phoenix_kit` is pinned to `timujinne/phoenix_kit` (`feat/session-confirm`), and
`phoenix_kit_ai` to the fork's integration branch. A package with git deps cannot go to Hex;
`AGENTS.md` already says so. Nothing to do here until the core PR merges.

## What was verified and holds

- **A click:** owner-only (`Conversations.owned_conversation/3`, impersonation refused first),
  the card is read again under the user's lock, the arguments come from the assistant message
  of *this chat* by the card's own `assistant_message_uuid` and call id (never found by the
  call id across the chat), and core re-checks everything and spends the row atomically.
- **Lock:** one atomic statement; a click is dated back so a turn can take a never-released
  click lock `hold_s` after its last keep; `holder/1` tells a click from a turn by the ref
  prefix, and retries once if the lock was released between the take and the read.
- **Runner:** at most one write waits per round; later writes, reads after a waiting write, a
  shared call id and a write already waiting in the chat are `denied`; a round with a waiting
  write ends the turn with no further model call, so no answer can claim the change was made.
- **Notices:** `settle_lapsed/3` recomputes under the lock, so two tabs cannot write two
  notices; a notice the chat refuses is `{:error, :not_stored}`; the notice and the new card of
  `changed` / "Ask again" are one transaction.
- **Migration V2:** every statement guards itself; `down` clears the three new outcomes before
  restoring the old check.
- **Logging:** the only `Logger` calls carry field names, validation codes or an exception
  class.
- **Dock:** every click goes through `Confirmations`; the arguments are escaped text in a `<pre>`;
  the click runs in a task not linked to the panel, so a closed tab does not stop it half-way.

## Gate (one run on the final tree, with the fixes of this round for #3, #6 and #8)

`mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer): passed.
`mix test`: **809 tests, 0 failures, 7 excluded** (`@tag :poppler` / `:imagemagick`, excluded
where the program is missing). `mix gettext.extract --check-up-to-date`: clean.

Also changed in this round: `test/test_helper.exs` raises `assert_receive_timeout` to 2 s.
`render_async/2` waits for that timeout (100 ms by default), and a different `DockTest` test
failed on it in each of several runs under load; it is a test-timing flake, not a product bug.
