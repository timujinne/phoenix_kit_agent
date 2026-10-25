# Codex Review — PR #8

- Reviewer: Codex
- Reviewed: 2026-10-23
- PR: Chat notice for an AI account with no credit left in all locales
- Author: Tymofii Shapovalov (`timujinne`)
- Merge: `11c280f`; rechecked with Claude's follow-up `54abd09`.

## BUG — MEDIUM — transient model errors still appeared in English (fixed)

Claude's follow-up fixed administrative endpoint errors, but ordinary timeouts, malformed responses, connection errors, generic provider errors and unknown model failures still fell through to stored English text. A retry is appropriate in these cases; its language was the remaining defect.

`Texts.notice/2` now translates the two fixed stored model-error texts at render time. The second explains that rejected pictures were removed from the message and may be sent again. Matching these fixed texts preserves that distinction even though both picture and non-picture provider failures use `api_error`; it also handles older messages. A known error code still takes precedence, so old insufficient-credit and invalid-key messages retain their specific administrative guidance. Other stored notice text remains intact.

Both texts and the duplicate-card refusal from PR #6 are translated into en, et, ru, uk, fr and de. Tests check all transient error codes in every locale, preserve the distinct picture guidance and unknown notice fallback, and render both transient/picture notices in a Russian panel.

## Other checks and validation

HTTP 402 still maps to `insufficient_credits`, and that notice remains distinct from rate limiting. The pin still treats 429 as `rate_limited`; quota subtypes require an AI-dependency change. Pictures remain attached on credit, credential, 404, timeout and server failures; only the established request-refusal statuses can unlink them. See the PR #7 Codex review for the separate dependency logging follow-up. Final validation results are recorded in the PR #6 Codex review.
