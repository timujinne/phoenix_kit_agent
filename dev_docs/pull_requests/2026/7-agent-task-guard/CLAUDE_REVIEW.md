# Claude Review — PR #7

- **Reviewer:** Claude Sonnet 5.5
- **PR title:** Use phoenix_kit_ai's task guard: declared tasks, a turn admitted once, guard refusals with their own texts, off-purpose self-flag, chat blocks on the Users page
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-10-23
- **Merge commit:** `a2bbbdf` (merged into `main`)
- **Range reviewed:** `a2bbbdf^1...a2bbbdf` — 40 files, about 4.5k lines added / 2.4k removed
  (tests about 2k, catalogues about 1.1k)

## Overall Assessment

**Verdict: APPROVE. Risk: LOW–MEDIUM.** No defect found that needed a fix; two notes.

## How it was reviewed

**Read in full (diffs):** `Turns` (admission), `Turns.Runner` (call options, error codes, the
off-purpose cut), `Limits`, `Models`, `Config`, `UserConfig`, `Prompt`, `PhoenixKitAgent.ai_tasks/0`,
`Attachments.Processor`, `Spend`, `Web.UsersLive`, `Web.SettingsLive`.

**Not read line by line:** the texts, the catalogues and the tests (guard_test is 545 lines).

## Findings

### F1 — IMPROVEMENT, LOW — one block lookup per row of the Users page (not fixed)

`UsersLive.block_of/2` calls `GuardBlocks.active/3` for each user of the page, so a page costs
N queries. Fixing it needs a batch reader in `phoenix_kit_ai` (`active_for(users)`); the page is
paginated and the call is a primary-key-style lookup. Left as is; worth a batch call when the
AI module has one.

### F2 — NITPICK — the off-purpose pattern scans whitespace twice

`~r/\s*⟦off_purpose:\s*([^⟧]*)⟧\s*\z/u` is unanchored on the left, so on an answer with a very
long run of whitespace the engine retries the leading `\s*` at each position. The answer is
bounded by the model's output limit and PCRE has its own match limit, so it costs time, not
safety. Not changed.

## What was verified and holds

- **Admission once:** `admit/2` runs under the locks, after `Limits.check/3`; the rounds pass
  `guard_admission:`; a refusal writes one notice per chat and period and releases the locks
  (`started/4`); an answer in a shape the module does not know starts no turn and logs one line
  without the answer.
- **Offsets:** `Regex.run(..., return: :index)` with `/u` gives byte offsets, and the code uses
  `binary_part/3` — consistent. The marker is cut only at the very end; a marker elsewhere is
  left and flags nothing; the guard's answer never changes what is stored.
- **A new model must fit its task** only when it is a new choice (`Config`, `UserConfig`,
  `SettingsLive`, `UsersLive`): the one already set is not checked again; the check inside
  `admin_update`'s transaction reads capabilities from the cache, never the network.
- **Money:** `Models.summaries/1` selects the fields `PhoenixKitAI.CallCost.reports_cost?/1`
  reads (provider, model, base URL, `provider_settings`), so a summary and the full endpoint
  give the same answer; `Spend.users_this_month/1` leaves out calls the guard refused.
- **Removed code is gone everywhere:** no reference to `Limits.ai_budget_reached`,
  `Models.Cache`, `clear_cache` or `budget_text` remains in `lib`, `test` or the docs.
- **Lifting a block:** `agent.manage` is re-checked, the block is the one the server finds for
  the user (never named by the browser), and the guard decides own and Owner blocks.

## Gate (one run on the final tree, with the fixes of this round for #3, #6 and #8)

`mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer): passed.
`mix test`: **809 tests, 0 failures, 7 excluded** (`@tag :poppler` / `:imagemagick`, excluded
where the program is missing). `mix gettext.extract --check-up-to-date`: clean.

Also changed in this round: `test/test_helper.exs` raises `assert_receive_timeout` to 2 s.
`render_async/2` waits for that timeout (100 ms by default), and a different `DockTest` test
failed on it in each of several runs under load; it is a test-timing flake, not a product bug.
