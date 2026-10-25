# Codex Review — PR #7

- Reviewer: Codex
- Reviewed: 2026-10-23
- PR: Use phoenix_kit_ai's task guard
- Author: Tymofii Shapovalov (`timujinne`)
- Merge: `a2bbbdf`; rechecked with Claude's follow-up `54abd09`.

## BUG — MEDIUM — quadratic marker matching delayed ordinary answers (fixed)

The leading unanchored `\s*` retried a long whitespace run at every position if a following marker was not at the end of the answer. A local reproduction with 100,000 spaces before `⟦off_purpose: private⟧ extra` took about 15 seconds. The integration regression exceeded the turn-completion assertion timeout. This is material work on the turn process, delaying completion and cooperative stopping.

The pattern now starts at the literal marker, captures the reason directly, and trims whitespace from the retained prefix only after a final marker matched. The same local reproduction completed in about 0.1 ms after the change. This is a reproduction measurement, not a timing guarantee.

Regression coverage retains a long nonfinal marker unchanged without a flag and strips a final marker after Unicode text at the correct byte offset. Existing tests still cover marker-only responses, tool results, flags deduplicated over rounds, and disabled self-flagging.

## Correction to the previous review's performance note

`GuardBlocks.active/3` reads the pinned dependency's shared ETS cache of active blocks; its cache load is a single query for all blocks. It does **not** issue one active-block query per row. `may_lift?/2` can still perform role checks for blocked users. The Users page itself is not paginated, contrary to the earlier review's description. No speculative batch API or cross-module query was added.

## Dependency follow-up — HIGH — sensitive text can reach dependency logs

At the pinned `phoenix_kit_ai` revision `f8f2968`, `GuardEvents.insert/1` inserts an off-purpose event including its model-written `reason` without `log: false`. With query logging enabled, that text can be logged. Separately, `Completion.generic_error_status/2` logs provider error messages, which can echo request content; the latter issue is already noted in this repository's turn-log tests. These are dependency-owned paths and are not fixed by this repository's changes. Dependency work was raised separately rather than suppressing host logging or dropping the recorded reason in this consumer.

The dependency fix should disable query logging on sensitive guard-event writes and retain only HTTP status/class in provider-error logs, with whole-event secret probes, then update this repository's pin to the verified revision. Until that lands, the full end-to-end no-content-in-logs contract cannot be claimed.

## Other checks and validation

Rechecked turn admission under locks, guard refusals, call task/admission attribution, capability checks, new endpoint selection, vision-call guard mapping, journal-based spend, and block-lift authorization against the pinned AI implementation. Final validation results are recorded in the PR #6 Codex review.
