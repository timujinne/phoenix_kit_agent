# Claude Review — PR #9

- **Reviewer:** Claude Opus 5.5
- **PR title:** Test that an Anthropic endpoint without a base URL asks no host for its models
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-10-24
- **Merge commit:** `20b54b5`
- **Range reviewed:** `20b54b5^1...20b54b5` — one `describe` block in
  `test/phoenix_kit_agent/models_test.exs`

## Overall Assessment

**Verdict: APPROVE. Risk: NONE** (test only, no change in `lib/`). No findings that need a
change.

## What was verified and holds

- **The stub sees every request it has to.** The module's `setup` puts
  `plug: {Req.Test, @stub}` in `:phoenix_kit_ai, :req_options`, and every HTTP door of
  `phoenix_kit_ai` 0.26 reads that key (`Completion.http_post/3`, `OpenRouterClient`,
  `Providers.HTTP` for both `request/1` and the model list). A model-list request for the
  endpoint would go through one of them, so it cannot leave the test unseen.
- **Shared mode is safe here.** `Req.Test.set_req_test_to_shared` needs the module to run
  `async: false`; it does (`DataCase, async: false`). The stub closes over the test's pid, so a
  request from a task elsewhere still lands in the test's mailbox, and `refute_receive` (not
  `refute_received`) waits for a late one.
- **Recording instead of `flunk/1`** is the right call: the existing `no_network/0` helper of
  the same file flunks inside the stub, and the PR text is right that a raise inside the task
  that asks is turned into `:unknown`, which the "listed nowhere" test expects anyway.
- **Both blanks are real.** `nil` and `""` are written straight with `Ecto.Changeset.change/2`,
  past the endpoint changeset, as an old row would hold them.

## NITPICK — not changed

- The two helpers (`record_requests/0`, `anthropic_without_base_url/3`) are `defp`s inside the
  `describe`. ExUnit allows it and they are module-level all the same; moving them out would
  only churn the diff.

## Gate

Run on the final tree together with the review of #10 (see
`../10-ai-cost-in-dollars/CLAUDE_REVIEW.md`).
