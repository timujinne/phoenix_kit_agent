# AGENTS.md

Guidance for AI agents working on `phoenix_kit_agent`.

## Overview

AI agent module for PhoenixKit: per-user chats stored in the database, file
attachments, a managed system prompt, and a model-and-tools loop over the
PhoenixKit API registry. It implements the `PhoenixKit.Module` behaviour for
auto-discovery by the host application; it is a library, and the host supplies
endpoint and router (`config/` exists only for tests).

**Status: under development.** In place: module registration and the
enable/disable switch (`PhoenixKitAgent`), the module-owned migration chain and
its tables (`PhoenixKitAgent.Migrations`, `PhoenixKitAgent.Schemas.*`), the
permission keys `agent` / `agent.manage`, the module settings and the
Settings → AI Agent page (`PhoenixKitAgent.Config`,
`PhoenixKitAgent.Web.SettingsLive`), the card of what the assistant can use
now on it and on Users → Configure (`PhoenixKitAgent.Web.ToolAvailability`),
the hidden Storage library
(`PhoenixKitAgent.Library`), the user-deletion cleanup
(`PhoenixKitAgent.UserDeletion`), the chats and messages
(`PhoenixKitAgent.Conversations`: session-bound, owner-only; a client writes
only the user's text and never reads raw tool results) and the turn loop
(`PhoenixKitAgent.Turns` with `Turns.Monitor`, `Runner`, `Locks`, `Tools`), the
writes the user confirms (`PhoenixKitAgent.Confirmations`),
the per-user settings (`PhoenixKitAgent.UserConfig`: `effective/1` is the one
place a turn reads them — user value, else module default; `admin_update/4`
for an admin with `agent.manage`, which logs field names to Activity;
`put_personal_instructions/3` for the user's own text), the system prompt
(`PhoenixKitAgent.Prompt`, spec §7.1, with the host's `prompt_addendum` and
`page_context`), the endpoint choice (`PhoenixKitAgent.Models`: only
`phoenix_kit_ai` endpoints that chat, marked for tool support from
`PhoenixKitAI.Capabilities`), the AI tasks of the guard (`ai_tasks/0`:
`agent.chat`, `agent.attachment`), the spending
read from the AI journal (`PhoenixKitAgent.Spend`), Admin → AI Agent → Users
(`PhoenixKitAgent.Web.UsersLive`), the limits and their notices
(`PhoenixKitAgent.Limits`: checked by `Turns.start/6` under the turn's locks;
one notice per limit and period through `phoenix_kit_agent_limit_events`;
notification type `agent_limit` from `notification_types/0`) and Admin → AI
Agent → Spending (`PhoenixKitAgent.Web.SpendingLive`) and the attachments
(`PhoenixKitAgent.Attachments` with `Attachments.Detect`, `Extract`, `Processor`,
`Cmd`, `Bounds`, `Unzip`, `Jpeg`, `Work`) and the chat panel
(`PhoenixKitAgent.Web.Dock`, the module's header widget, with
`Web.Dock.Panel` (markup and hooks), `Web.Dock.Components`, `Web.Dock.Texts`
and `Web.Markdown`).

- **Depends on:** `phoenix_kit` `~> 2.64` (the writes of a live session:
  `allow: :all`, `Executor.redeem_as/6`, the session functions of
  `API.Confirm`, the `OperationPreview` component,
  `Executor.tool_availability/1`; the AI journal's cost in dollars, V223),
  `phoenix_kit_ai` `~> 0.26` (the AI task guard, tool calling, a call's
  cost from one place, `Request.cost` in dollars), `phoenix_live_view`, and
  `mdex` (already phoenix_kit's) for the markdown of the chat panel.
- **Module key** `"agent"`; settings prefix `agent_`; tables
  `phoenix_kit_agent_*` (marker `pk_agent_schema:<N>` on
  `phoenix_kit_agent_conversations`).
- **Permissions:** `agent` (use the assistant) and `agent.manage` (defaults,
  other users' settings, spending; core auto-grants it to Admin). Do not add an
  `agent.view_all`: it would be auto-granted to Admin too.
- **Admin pages:** every event re-checks the permission against the socket's
  scope and the scope of the session as it is now
  (`PhoenixKitAgent.Web.Access`: `assign_session/2` in mount takes the session
  reference in the connected mount; `session_scope/1` is
  `SessionRef.scope_for_session/2` — the session's active role, never a scope
  rebuilt from the user by uuid): `agent.manage` for the Users page and the
  Settings page, and `Scope.owner?` — not just the tab's `agent.manage`, which
  an Admin holds — for `agent_capture_ai_content` and for changing an Owner's
  settings. A form takes only the fields it offers; the user being edited is
  the one the server opened, never a submitted uuid; a save is refused when
  the shown values changed since the form opened (`admin_update/4`,
  `expected:`). A model or a watcher a form did not offer is refused (and
  `Config.put_default_endpoint/2` / `put_vision_endpoint/2` take only an
  existing endpoint that chats). Pages keep endpoints as `Models.summary/1`,
  never the row with its API key. The admin pages run with `log: false` (an
  event's parameters hold prompts). The module prompt is written without
  core's settings history (which keeps a value in Activity and in the query
  log) and its change is logged as `agent.settings_updated`, field names only;
  every other text a person writes (personal instructions, an admin's prompt
  for a user) is written with `log: false`.
- **Money and turns:** money only from the AI journal (`user_uuid` +
  `metadata.source = "agent"`), never from the module's own messages; every
  model call of the module passes `user_uuid:` and `source: "agent"`; every
  journal row with a cost counts, whatever its status. The journal's `cost`
  is dollars; the module counts whole micro-dollars (`*_micro_usd`), made
  only by `Config.cost_to_micro/1` (half up; a limit's day or month sum is
  rounded once, a message's own cost on its own — a chat's total adds those).
  Turns from the `user` messages with a `turn_ref`. The limit check runs
  under the locks, so the previous turn's spending is in. A turn is never killed
  outright: "Stop" and the deadline ask it to stop between steps
  (`Turns.Monitor.check_stop/0`), and only after `turn_stop_grace_ms` is it
  killed. A "Stop" for a turn whose task is not in this node's registry, while
  the chat's lock is within its TTL, is broadcast on `agent:turn:<turn_ref>`
  (`Monitor.broadcast_stop/1`, the ref only); the monitor subscribes to the
  topic of each turn it runs. Ownership is checked in `Turns.stop/4`, before.
  Nothing answers a Stop but the turn's end: the panel offers Stop again
  (`:stop_unanswered`) when that end has not come within
  `stop_grace_ms + turn_check_ms`.
- **Attachments:** session-bound like `Conversations` (`impersonated:` in the
  options); only the owner adds, reads, discards or gets the address of a
  file, an Owner/Admin of the site included. Bytes live in the hidden library
  (`PhoenixKitAgent.Library`) and leave only through `Attachments.url/3`
  (`Storage.authorized_url/4` for the session's scope) — never a Media URL.
  The content, not the name, decides the kind (`Attachments.Detect`). Files are
  processed in a task under `PhoenixKitAgent.Attachments.TaskSupervisor`
  (`children/0`), with a deadline and a heap limit; a failure is a code in
  `attachments.error`, never a parser's message. A workbook is read with
  `Attachments.Unzip` (never `:zip.extract` — declared sizes are the uploader's),
  a JPEG for a model goes through `Attachments.Jpeg.strip_metadata/1`, and
  every temporary file or directory is made by `Attachments.Work` (private,
  random, removed by the supervising process, not the worker that may be
  killed). Storage is given a neutral file name (it logs names). Concurrency is
  `Bounds.concurrent_jobs` (and `jobs_per_user`), enforced by the waiting
  queue `Attachments.Slots` (a place is held by the job process, free when it
  ends); workers run under their own supervisor. A picture reaches the model as
  pixels in its own turn (`Attachments.model_parts/3`, used by `Turns.Runner`)
  only for a model known to take images, asked again as the turn starts (one
  that stopped being known to: no call, the files go back, notice
  `pictures_not_seen`); any other (unknown abilities included) gets a
  description kept in the row, or a `no_vision_model` refusal
  (`Processor.picture_mode/1`). A description is paid: right before it the AI
  module and the session that added the file are checked again (the
  processing gets the session reference), and one user's descriptions are
  made one at a time (`:global` lock), so each sees what the last one cost.
  Files leave a message only when the provider refuses the request (400, 413,
  415, 422), not on a 404 or a 5xx. Every extractor that cuts a file ends
  its text with a `[... the … continues: …]` line (`Extract.continues/1`) —
  keep that for a new kind. Children in `children/0` need ids of their own
  (`PhoenixKitAgent.…`): PhoenixKit.Supervisor starts every module's children
  in one list. Writes
  that bind a file name or its text use `log: false`. Tests that need poppler
  or ImageMagick carry `@tag :poppler` / `:imagemagick` and are excluded, with a
  message, where the program is missing.
- **The chat panel** (`Web.Dock`): the widget's session carries only the
  user's uuid and locale (`header_widget_session/1`); the session reference and
  the impersonation flag are read by the panel itself in its **connected**
  mount, never taken from the widget session, params or events, and the static
  render shows nothing of the user. Every event calls `Conversations`, `Turns`,
  `Attachments` or `UserConfig` with them — no Repo query of its own, no
  shortcut through a uuid the browser sent. Model text is rendered only through
  `Web.Markdown` (no `<img>`, no raw HTML, links with domain and
  `rel="noopener noreferrer nofollow"`), a tool call only by its
  `tool_summary`. A refusal is shown through `Web.Dock.Texts`, never as a code.
  The LiveView runs with `log: false` (event parameters are the user's text);
  every `handle_event` / `handle_info` / `handle_async` / upload progress goes
  through `guarded/2`, which catches an exception and logs its class only (a
  crash report carries the event and the whole state) — keep new callbacks
  behind it; `mount` and `render` are not covered. The
  path given to `Attachments.add/4` is LiveView's own upload file
  (`consume_uploaded_entry/3` with `:postpone` until `add/4` is done), and
  `add/4` runs in its task under a guard that logs only the exception's class.
  Browser hooks are runtime colocated hooks (`runtime` attribute), since a
  dependency's extracted hooks would not reach the host's bundle; they live in
  `Web.Dock.Panel` with the elements that use them (a colocated hook is named
  after its module). An element a hook owns is `phx-update="ignore"` (the
  composer's textarea). A re-join after a lost connection mounts the LiveView
  afresh but calls the hook's `reconnected()`, not `mounted()`: state the
  server must get back (`restore`) is pushed from both. They are inline
  scripts: a host CSP needs `script-src 'unsafe-inline'`. The indicator and
  "Stop" come from the server only: while a turn is shown the panel reads the
  chat's lock again every `:turn_check_ms` and lets an ended turn go (with the
  messages it left), and every `restore` changes `data-restored`, so its
  answer patches the whole panel over whatever the browser kept. A daisyUI focus
  dropdown's trigger is a `div` with `tabindex="0"`, never a `<button>`
  (Safari does not focus a clicked button).
- **Prompt input from a browser** (`page:`, `locale:` of `Turns.start/6`) is
  untrusted: `PhoenixKitAgent.Prompt` drops a value with a control character and
  cuts a long one. The host's `page_context: {Mod, :fun}` hook is called as
  `Mod.fun(path, scope)` with the session's scope (the one `Turns.start/6` got
  from `SessionRef.scope_for_session/2`, never `Scope.for_user/1`); its text is
  put on one line and cut to 200 characters; a failure logs the reason only.
  It runs in the panel's process under the turn's locks, with no timeout.
- **Writes** (`PhoenixKitAgent.Confirmations`, spec §12 Ф2): the module adds
  no filter of its own and opens nothing beyond core — `visible_for/3` /
  `execute_as/5` with `allow: :all`, `via: "agent"`; whether a session sees a
  module's writes is core's `api_session_write_modules` alone. Core holds
  every write of a session for confirmation; the turn stores it as a `tool`
  message `needs_confirmation` with `confirmation_uuid` and
  `assistant_message_uuid` (V2 of the migrations) and only
  `{status, confirmation_id}` as its result — never a code, the preview or
  the arguments — lets one write of a round wait (a second one, or one whose
  call id another call of the answer shares, is `denied`; so is every read
  after it, "held for confirmation", which the model would never see) and
  **ends the turn: no model call after a round with a waiting write**. A write
  of the same tool and arguments as a card of the chat that still waits is
  `denied` ("already waiting for confirmation"), never a second card. A click
  (`confirm/5`, `reject/5`, `repeat/5`) takes the user's turn lock alone
  (`Locks.acquire_user/4` with a `Locks.click_ref/0`; a 30 s hold, kept fresh
  by a process next to the click for as long as it runs, `Locks.keep_user/4`)
  and is `:turn_running` while a turn runs, `:click_running` while another
  click does; a turn started meanwhile is `:click_in_flight`. It redeems with
  the card's registry name and `Tools.arguments/1` of the raw arguments of its
  assistant message's call (never found by the call id across the chat). The
  outcome is a `notice` with the same `confirmation_uuid` and `tool_outcome`;
  a refusal before core spends the row writes nothing (the card waits, with
  its reason). `failed` only when the handler failed after core spent the row;
  a row core reports `used` with no notice here (its click was lost) is
  `confirmed` once `get_for_user/2` reads it `used`, else the card waits;
  core's `invalid` (the row is gone) is `expired`. With the right to the tool
  gone core withholds `get_for_user/2` (`:forbidden`); the status is then read
  from the user's row (`lookup_for_user/2`), and such a card keeps "Cancel the
  change" (`rejectable?`). A card with no notice that core no longer holds
  (`used`, `rejected`, ran out, gone) gets its notice from
  `Confirmations.settle_lapsed/3` (the panel, on opening a chat, under the
  user's lock only when there is one) and `settle_lapsed_in_turn/2` (a turn,
  under its locks, before the history): only a card core still holds reads as
  waiting to the model, to `waiting_same?/3` and above the feed. A notice the
  chat refuses makes the click `{:error, :not_stored}`. The notice of `changed`, or
  the `expired` one of "Ask again", and the new card are one transaction
  (`Conversations.add_turn_messages/3`). Only these notices, and each card
  with none yet ("[confirmation] waiting: <tool>"), go into the next turn's
  history, as `user` messages with the module's fixed phrase
  (`History.confirmation_phrase/2`); other notices stay out. The panel reads
  the cards with `Confirmations.cards/4` (core's preview via
  `Confirm.get_for_user/2`, rendered with core's `operation_preview`; the
  arguments as escaped text), finds a waiting card older than the page it
  loaded with `Confirmations.waiting_cards/3` (shown above the feed) and runs
  a click in a task under `PhoenixKitAgent.Confirmations.TaskSupervisor`.
  Nothing of the arguments or the preview is logged, here or by core (its
  insert of the row is `log: false`). The test write tool is
  `agenttest.write_item` in `test/support/agent_test_tools.ex`.
  "Ask again" also refuses a duplicate waiting write from a later turn
  (`:already_waiting`, under the click's lock), and an expired card offers
  it only while no card of the chat waits for the same tool and arguments.
- **The AI task guard** (`phoenix_kit_ai`): every model call names its task
  (`task: "agent.chat"` / `"agent.attachment"`); a turn is admitted once in
  `Turns` (`Guard.admit/4`, after `Limits.check/3`, under the locks) and its
  rounds pass `guard_admission:`; the guard's refusals are notices with their
  own codes, all in `Runner.model_failed/4`. The module does not tell anyone
  of a refusal of the AI budget: `phoenix_kit_ai` does. Pixels go to a model
  only when `Capabilities` says `:yes` (never on `:unknown`). The
  off-purpose marker is cut in `Runner.store_answer/5`, before anything is
  stored, only at the very end of the model's own text. It is not cut from
  the AI journal: with `agent_capture_ai_content` on, the captured answer
  there carries the marker and its reason, which every holder of `ai` reads
  — the reason is seen wherever the journal is. A page that saves
  an endpoint for a task checks it with `Tasks.check_selection/2` when it is
  a new choice; the lift of a block goes through `Web.Access` and then
  `Guard.unblock/3` with the session's scope (the guard decides own and
  Owner blocks).
- **Boundaries:** nothing about orders, customers or other host domain data
  lives here — the module only knows "tools from the registry". Model calls,
  budget and the request journal stay in `phoenix_kit_ai`.

## Commands

```bash
mix deps.get
mix test                     # needs a local PostgreSQL (test DB phoenix_kit_agent_test)
PK_AGENT_SKIP_DB=1 mix test  # no Postgres: unit tests only (never in CI or before a release)
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer
```

Test database settings come from `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`
(defaults: `localhost`, `postgres`, `postgres`, `phoenix_kit_agent_test`).

`phoenix_kit*` deps resolve from their pin in `mix.exs`. To run against a local
checkout, export `<APP>_PATH` (the dep's app name upper-cased plus `_PATH`, e.g.
`PHOENIX_KIT_PATH=../phoenix_kit`); `pk_dep/3` in `mix.exs` swaps the pin for a
`path:` dep at resolve time. Never commit a hand-edited `path:` tuple.

## Conventions

- `0 tests` is not a pass: a test run that excluded everything proves nothing.
- Do not edit `CHANGELOG.md` or `@version` in `mix.exs` in a pull request.
- Tables are PhoenixKit-style: UUIDv7 primary keys, module-owned migrations.
- Nothing of a chat — the user's text, a model answer, a tool result, a system
  prompt — may reach `Logger` (message, metadata or crash report): log the
  class of a failure only. `test/support/log_probe.ex` checks whole log events
  for it.
- Every text a person sees goes through `PhoenixKitAgent.Gettext`; the catalogues (`priv/gettext`: en, et, ru, uk, fr, de) are complete — a new msgid is translated in all of them (`test/phoenix_kit_agent/translations_test.exs` checks it). No new language is added.
