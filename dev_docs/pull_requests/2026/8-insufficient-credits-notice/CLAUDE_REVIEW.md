# Claude Review — PR #8

- **Reviewer:** Claude Sonnet 5.5
- **PR title:** Chat notice for an AI account with no credit left (insufficient_credits) in all locales
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-10-23
- **Merge commit:** `11c280f` (merged into `main`; its catalogue conflicts with #7 were resolved
  in that merge: both sides kept, `mix gettext.extract --merge`)
- **Range reviewed:** `11c280f^1...11c280f` — `Runner.model_error_text/2`, `Texts.notice/1`,
  catalogues, three tests

## Overall Assessment

**Verdict: APPROVE. Risk: LOW.** The PR is right for the code it names; the same defect was
still there for eight other codes (F1, fixed).

## Findings

### F1 — IMPROVEMENT, MEDIUM — eight model errors still showed "Try again" in English (fixed)

`Runner` keeps `invalid_api_key`, `api_key_forbidden`, `endpoint_not_found`,
`endpoint_disabled`, `endpoint_no_model`, `integration_not_configured`, `integration_deleted`
and `not_configured` as their own `messages.error` code, but `Texts.notice/1` had no clause
for them and `model_error_text/2` stored "The model did not answer. Try again.". That is the
defect #8 fixed for `insufficient_credits`: English in every locale, and a retry cannot help,
because only an administrator can end each of them. (`rg` on the two lists found it: the codes
of `@model_errors` against the `notice/1` clauses.)

**Fix:** one text for the group, "The AI endpoint behind the assistant cannot be used right
now. An administrator has to check its settings." — `Texts.notice/1` (a `when code in`
clause), `Runner.model_error_text/2` (`@endpoint_unusable`), and a translation in de, en, et,
fr, ru, uk. It names no provider, no key and no endpoint. **Left alone on purpose:**
`request_timeout`, `invalid_json_response`, `invalid_response_format`, `no_choices_in_response`,
`api_error`, `connection_error`, `model_error` — a retry can help there, so "Try again" is true.

**Tests:** `translations_test` (all six locales, no "try again", English differs from the
others), `dock_test` (the panel shows it in en and ru), `turns_test` (a 401 is stored as
`invalid_api_key` with the new text).

### F2 — NITPICK — the 429 `insufficient_quota` case depends on `phoenix_kit_ai`

The PR text says a 429 that means "out of credit" will also reach `:insufficient_credits`
"soon". Nothing here tests or depends on that; once the pin carries it, no change is needed in
this module. Recorded so nobody looks for a missing clause.

## What was verified and holds

- `unsend/2` removes pictures only for 400/413/415/422, so a 402 does not take files off the
  message (the test asserts the lock is released and the notice has the new code).
- `stop_text` needs no clause: a model error never reaches `stopped/2`.

## Gate (one run on the final tree, with the fixes of this round for #3, #6 and #8)

`mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer): passed.
`mix test`: **809 tests, 0 failures, 7 excluded** (`@tag :poppler` / `:imagemagick`, excluded
where the program is missing). `mix gettext.extract --check-up-to-date`: clean.

Also changed in this round: `test/test_helper.exs` raises `assert_receive_timeout` to 2 s.
`render_async/2` waits for that timeout (100 ms by default), and a different `DockTest` test
failed on it in each of several runs under load; it is a test-timing flake, not a product bug.
