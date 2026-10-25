# Codex Review — PR #6

- Reviewer: Codex
- Reviewed: 2026-10-23
- PR: Writes the user confirms in the chat
- Author: Tymofii Shapovalov (`timujinne`)
- Merge: `3dcff9d`; rechecked with Claude's follow-up `54abd09`.

## BUG — MEDIUM — “Ask again” bypassed the pending-write duplicate check (fixed)

Reproduction: a card expires; a later model turn proposes the same tool and arguments in a different assistant message; the user asks again on the old card. `superseded?/2` only recognized another card of the *same assistant message*. `repeat/5` therefore returned `{:ok, :repeated}` and created another independently redeemable confirmation for an operation already waiting. The runner's duplicate check did not protect this click path. This matters for non-idempotent write handlers.

`repeat/5` now checks the existing pending-write rule under the user's click lock, after resolving the old card's arguments and before calling core. It returns `:already_waiting`, with a notice translated into all six locales. Expired cards hide “Ask again” while an equivalent proposal waits. Cancellation of that proposal allows the expired card to be asked for again.

The regression failed against the previous implementation (`{:ok, :repeated}` instead of the refusal). It covers expired cards both with and without their settlement notice, hiding the button through `repeatable?`, no extra preview/card, lock release on refusal, and retry after cancellation.

## Other checks

Reviewed `Confirmations` with the runner, history, locks, message storage, card components and panel callbacks, and the corresponding pinned core executor/confirmation paths. Session/ownership checks, confirmation binding, raw-argument lookup within the assistant message, current permissions at redemption, one waiting write per round, no model call after a waiting write, atomic replacement notice/card, stale-confirmation settlement, and the keeper-start cleanup remain intact. Existing integration tests exercise core-backed execution, changed previews, revoked permissions, lock keeping and detached clicks.

The dependency's write policy is intentional and matches AGENTS.md. User-written confirmation phrases do not authorize execution. No version or changelog changes, open-PR merges, or releases are included.

## Validation

- Before changes: `mix test` — 809 tests, 0 failures, 7 excluded.
- Updated focused suites: 179 tests, 0 failures.
- `mix precommit` — passed, including warnings-as-errors compilation, Gettext extraction, dependency checks/audit, formatting, strict Credo and Dialyzer.
- Final full suite: `mix test` — **814 tests, 0 failures, 7 excluded** (392 seconds).

The exclusions are reported by the test harness for unavailable external-tool coverage. No database tests were skipped through `PK_AGENT_SKIP_DB`.
