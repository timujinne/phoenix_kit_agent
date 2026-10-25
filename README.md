# PhoenixKitAgent

An AI agent module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit): a
personal assistant inside the application. Every user gets their own chats kept
in the database, can attach files to a message, and talks to a model that works
through prepared tools from the PhoenixKit API registry. The assistant sees and
does no more than the user can in their current session. Model calls, endpoints,
credentials, budget and the request journal come from
[`phoenix_kit_ai`](https://github.com/BeamLabEU/phoenix_kit_ai).

**Status: under development.** So far: the `PhoenixKit.Module` registration
(module key `agent`) and the enable/disable switch, the module's tables (own
migration chain, run by `mix phoenix_kit.update`), the permissions `agent` and
`agent.manage`, the module defaults under Settings → AI Agent, a hidden Storage
library for attachments and the cleanup when a user is deleted; the chats and
their messages (`PhoenixKitAgent.Conversations` — session-bound, owner-only,
with a PubSub topic per chat) and the turn loop (`PhoenixKitAgent.Turns` —
locks, rounds of model and tool calls over the session's own tools, stop and
deadline), the writes the user confirms in the chat
(`PhoenixKitAgent.Confirmations`, below), the per-user settings
(`PhoenixKitAgent.UserConfig` — the user's own value, else the module default:
the model, the admin's prompt, the limits, the on/off switch and the personal
instructions), the system prompt put together in the order of priority
(`PhoenixKitAgent.Prompt`), Admin → AI Agent → Users, where an admin with
`agent.manage` sees every user's model, limits and spending and sets them
(with what the assistant can use now — on Settings → AI Agent for the
viewer's session, in the user's form by the user's roles), the
spending and turn limits (`PhoenixKitAgent.Limits` — checked before each turn,
with a notice in the chat and notifications to the user and the watchers) and
Admin → AI Agent → Spending, what everyone spent today and this month, and the
attachments (`PhoenixKitAgent.Attachments` — files added to a chat, kept in the
hidden library and made readable for the model before the turn), and the chat
panel in the admin header (`PhoenixKitAgent.Web.Dock`).

## The chat panel

A user with the `agent` permission gets a button before the notifications bell
in the admin header (the module's header widget, `header_widgets/0`; no panel
while the module is off or the session is impersonated). It opens the list of
their chats — "New chat" on top, then the chats with the newest message first,
20 at a time and "More", each with its time and "Rename" / "Archive" — and the
panel on the right, about 400 px wide (it can be dragged wider), which narrows
the page; on a phone it takes the whole screen. The panel has the feed, the
input with a paper clip for files, "Stop", an indicator of what the assistant
is doing (thinking / calling a tool), and a small form for the user's own
personal instructions. "New chat" empties the panel; the chat is made with its
first message or file, and takes its title from that message (a first message
or file that is refused leaves no chat behind). A long chat opens at its end,
with "Earlier messages" above. Open or closed, the chosen chat and the width are
kept in the browser (`localStorage`) and come back after a navigation, a reload
or a lost connection (a running answer comes back with its indicator and
"Stop"); the text being written is never wiped by an update of the panel. The
indicator and "Stop" follow the chat's lock on the server, never the browser:
after a reconnect the panel shows the turn the lock holds then, and while it
shows one it reads the lock again every 5 s (`config :phoenix_kit_agent,
turn_check_ms:`), so a turn whose end never reached it is let go of, with the
messages it left.
Notices are shown in the user's language by their code.

The interface speaks English, Estonian, Russian, Ukrainian, French and German (`priv/gettext`; `mix gettext.extract --merge` after a change of a text).

What the panel shows of a chat: the user's messages, the model's answers as
markdown without anything that loads by itself — no `<img>` with an outside
address (a picture in an answer is its alt text), no raw HTML, every link
opening in a new tab with `rel="noopener noreferrer nofollow"` and its domain
written beside it (an address whose host is not plain ASCII is written as text,
not linked) — the notices, and each tool call folded to its summary (the
tool, the outcome, how many it found), never what the tool returned. A chat
whose turn was lost with its node (a restart) gets the notice "the answer was
interrupted" when it is opened, and is free again.

The panel works only in the connected mount of a session that is its user's
own and not borrowed: it reads the session reference and the impersonation
flag itself, and passes them with every call, so each one is checked against
the session's scope at that moment; the static render shows nothing of the
user. It does not log events (LiveView would log their parameters, the user's
text), and an exception in an event is caught and logged as its class only (a
crash report would carry the draft). The panel's classes come from the
module's sources (`css_sources/0`), and its browser hooks are runtime colocated
hooks, so the host bundles nothing for it; it needs core's admin layout with
header widgets and the dock column. The hooks are inline scripts without a
nonce: a host with a Content-Security-Policy must allow `script-src
'unsafe-inline'`, or the panel shows but does not remember its state, resize
or send on Enter.
The tools called from the panel get the user's locale and the endpoint's URL as
their request context, and the client address only when the host's LiveView
socket passes `:peer_data` and `:x_headers` in its `connect_info`.

## Changes the user confirms

The assistant never writes on its own. It sees the write tools of a module only
when the module's box "Agent may act" is ticked in Settings → API (core's
setting `api_session_write_modules`, none by default; API keys do not read it),
and it opens nothing beyond what core lists for the session
(`Executor.visible_for/3` and `execute_as/5` with `allow: :all`). Core answers
such a call with a preview and holds it in a confirmation bound to the user;
the turn ends there — the model is not called again, so no answer can say the
change was made — and the chat shows a card:

  * core's preview of the change (its `operation_preview` component, read with
    the session through `PhoenixKit.API.Confirm.get_for_user/2`) and the
    arguments the model sent, as plain text;
  * "Run" runs it (`Executor.redeem_as/6`, with the same tool and arguments,
    under the rights of the session that clicks, checked again from the
    start); "Cancel the change" turns it down; once its time ran out
    (`api_user_confirm_ttl_seconds` of core), "Ask again" asks for the same
    change again, a new card. When the data changed since the preview, the
    card says so and a new card with the fresh preview follows.

At most one change of a round waits; a second one of the same answer is
refused to the model, and so is any other call of that answer after it (the
turn ends there). The same change asked for again while its card waits is
refused too: one card per change. This includes "Ask again" on an expired
card when a later turn has already proposed the same change. A click is
refused while a turn of the user or another click runs, and no message starts
a turn while a click runs, however
long it takes (the click keeps its lock fresh; a lock left by a node that went
down frees the user 30 s after its last keep). A click calls no model and
spends no turn of the limits; it runs in a task of the module's own
supervisor, not linked to the panel. A refusal before the change is made
(the session, the rights, the module's box, the tool's own check, the rate
limit) leaves the card waiting with its reason. What became of a card is a
notice with the same confirmation uuid (`confirmed`, `rejected`, `expired`,
`changed`, `failed`), and the model reads it in the next turn as a fixed phrase
of the module — "[confirmation] done: <tool>" in the user's language — never
the tool's result; a card with no outcome yet reads "[confirmation] waiting:
<tool>". `failed` means the handler failed after the confirmation was spent; a
confirmation spent by a click that was lost before it said so is taken as
done, and one core has deleted as run out. A card that stopped waiting with no
click to say so (it ran out, or its click was lost with its node) gets its
notice when the panel opens the chat and before a turn reads the history, so it
never reads as waiting; a card the user may no longer run (the right to its
tool is gone) keeps "Cancel the change". The module's prompt tells the model
that a write is a proposal that waits, never to be said done before such a
message, nor asked for again while it waits. A card still waiting is found
again when the panel is opened again, even one further back than the messages
the panel loads (it is shown above them); a borrowed session gets no panel and
no click.

## Attachments

A user adds png/jpg/webp/heic pictures, PDFs, xlsx/csv sheets and txt/md
files to their own chat. The content decides what a file is, not its name or
the type the browser claimed. A file is kept in the module's hidden Storage
library, in a folder named by the user's uuid: it is in no media picker or
browser, not even for a holder of `media.view_all`, and its bytes are reached
only through `PhoenixKitAgent.Attachments.url/3`, an expiring address minted
for the owner's own session. The size and the number of files per message come
from the user's settings (`max_attachment_mb`, `max_attachments_per_message`);
a user also has no more than 20 files waiting for a message in all their chats,
a failed one included, until they discard it. Discarding a file removes its bytes
from Storage unless another attachment uses them, and Storage is given a
neutral name for the file, not the user's. A text, CSV or Markdown file must be
UTF-8: one saved by Excel in a code page or as UTF-16 is refused with its own
reason (`unsupported_encoding`), and bytes that are not UTF-8 inside a file show
as U+FFFD.

Before the turn a task makes each file readable, and the row goes from
`pending` to `ready` (or `failed`, with a code in `error`): a PDF gives its
text; a PDF with no text (a scan) and a picture are shown to a model known to
take images as pixels, shrunk to 1600 px, in the message they came with only;
for any other model the vision model (setting `agent_vision_endpoint_uuid`)
describes them once and the description is kept in the history; a sheet
becomes CSV text, the first rows of each sheet; a text file is read as it is.
All of it is cut to a size (`config :phoenix_kit_agent, attachment_limits:
[…]`, see `PhoenixKitAgent.Attachments.Bounds`), between rows where there are
rows, and the sheets of a workbook share that size, so one large sheet does not
push the others out. A text that holds less than its file ends with a line the
model reads, such as `[... the sheet continues: 1240 of 1300 rows not shown in
full]` or `[... the workbook continues: 2 more sheets not shown: Q3, Q4]`, so it
does not take part of the data for all of it; the attachments of one message
share `agent_history_chars` between them, and one cut to its share there says
so too.

How a picture reaches the model (decided 2026-10-20):

  * A model known to take images (`PhoenixKitAI.Capabilities`: the
    provider's catalogue, or what an admin declared on the endpoint) is
    sent the pixels in the picture's own turn only; later turns carry a line
    that names the file and the assistant's own earlier answer, not a second
    (paid) description.
  * A model whose abilities are not known (a provider without a catalogue
    and nothing declared on the endpoint) is taken for a blind one: the vision model
    describes the picture. With no vision model set, `Attachments.add/4`
    refuses a picture at once (`no_vision_model`), before anything is stored;
    a scan, known to be one only once it is read, fails with the same code.
    Pixels are never sent on a guess, also not when the model changes between
    the upload and the send: the turn then calls no model, the files go back
    to wait for a message, and the notice `pictures_not_seen` says to attach
    them again (to be described).
  * When the first model call of a turn that carries pictures is refused by
    the provider as a request it does not take (`api_error` 400, 413, 415 or
    422), the files are taken off the message, the notice says so, and they
    wait to be sent again. A missing model (404) or a failure of the provider
    (5xx) says nothing of the pictures: the files stay with the message.
  * A description is paid, so right before it the AI module must be on and
    the session that added the file must still be one that may use the
    assistant (else the file fails as `ai_disabled`, `session_gone` or
    `forbidden`, and nothing is called); one user's descriptions are made one
    at a time (a `:global` lock per user), each checked against the limits
    with the cost of the one before already in the journal.

A JPEG for a model has its metadata removed (EXIF with the time and place of a
photo, XMP, IPTC, comments; `Attachments.Jpeg`). A workbook is never opened by
trusting the sizes its zip declares: its parts are inflated by the module
(`Attachments.Unzip`) against one budget, and the file is `too_large` when the
budget is spent. A worker that is killed for its deadline or its heap leaves
nothing in the temporary directory: the copy of the file lives in a private
directory (`Attachments.Work`) that the supervising process removes, and what
is still left after a node crash is swept at start-up and when a new one is
made. At most `concurrent_jobs` files (8) are processed at the same time on a
node, of them at most `jobs_per_user` (3) one user's; the others wait for a
place, in turn, up to `queue_wait_ms` (30 s), with at most `queued_jobs` (64)
waiting on the node, and are refused as `unavailable` after that
(`Attachments.Slots`). The limits are read at each decision. A workbook is
unpacked within `sheet_unzipped_bytes` (40 MB), and a job holds its parts twice,
so the binary memory a busy node may use for workbooks is about
`concurrent_jobs × 2 × 40 MB`. A row that is still `pending` after the wait and
the processing deadline (the node restarted) is read as `failed`/`timeout`.

The `path` of an upload given to `Attachments.add/4` is trusted: it must be the
temporary file of LiveView's own upload, never a value from the client.

PDF processing needs poppler (`pdfinfo`, `pdftotext`, `pdftoppm`) and pictures
need ImageMagick (`convert`, `identify`) on the host; without them such a file
fails with `pdf_tools_missing` / `image_tools_missing`, nothing else breaks.

## Limits

Per user, the user's own value else the module default (Settings → AI Agent):
money per day and per month and turns per day. Money is what the AI request
journal of `phoenix_kit_ai` recorded for the user's assistant calls
(`metadata.source = "agent"`, attachment descriptions included). The journal
holds dollars; the module counts them as whole micro-dollars (`$1 = 1_000_000`),
each day's and month's sum rounded half up once; a turn is one message the user
sent. The day and the month are those of the site time zone. Money counts only on an endpoint
whose calls get a cost in the journal (`PhoenixKitAI.reports_cost?/1`: the
provider reports it, as OpenRouter does, or `phoenix_kit_ai` prices the model
from the operator's catalogue, a manual price on the endpoint or Anthropic's
list price); on another only the turn limit applies, and the admin pages say
so. A picture's description is held to the money limits of the **vision**
endpoint it is paid on, not of the chat endpoint, and `phoenix_kit_ai` prices a
description like a chat call, from the same sources: when nothing prices the
vision endpoint's model, the money limits do not cover descriptions at all
(only the turn limit and the `phoenix_kit_ai` budget stop them): such an
endpoint has no cost to count.

The limits are checked when a turn starts; a turn that started under them runs
to its end. A limit used up refuses the turn with a notice in the chat (one per
chat, limit and period, however often the user tries again). Money counts every
journal row with a cost, a failed call's included. The
user is told in the app at 80 % of a limit and when it is reached; the
watchers (setting `agent_limit_watchers`, empty meaning every Owner, plus the
user's own `notify_user_uuids`) get a notification of type `agent_limit` when
the user's `notify_on_limit` is on, at most once per limit and period; with
`notify_on_limit` switched on later in a period, the watchers still hear of
that period. A refusal of the `phoenix_kit_ai` budget is told by
`phoenix_kit_ai` itself, to its watchers and to the module's (below); the
chat says the budget is used up.

## The AI task guard

The module declares two AI tasks of `phoenix_kit_ai` (`ai_tasks/0`):
`agent.chat` (the calls of a turn; needs tools) and `agent.attachment` (a
picture described by the vision model; needs images in). Both are private
(the reasons of their flags and blocks are shown only to holders of
`ai.manage`), share the block group `free_text` with the AI Playground, and
have no per-user limits in the guard (`user_limits: false`): the module's
own limits above stay the per-user ones; the guard adds only limits of the
task. Its watchers are `agent_limit_watchers` and, with `notify_on_limit`,
the user's `notify_user_uuids`, never the user.

  * A turn is admitted once, after the module's limits
    (`PhoenixKitAI.Guard.admit/4`); its calls carry the admission, so a turn
    that started runs to its end. A blocked user, or a task over its limit,
    gets a notice in the chat (`task_blocked`, `task_limit_exceeded`) and
    nothing is sent or stored.
  * A model the guard refuses is a notice of its own (`model_unfit`,
    `model_unverified`, `no_provider_for_params`).
  * When the task flags off-purpose requests (its guard mode), the system
    prompt carries the guard's instruction and the marker
    `⟦off_purpose: <reason>⟧`, above the admin's and the user's
    instructions. The turn cuts the marker off the end of an answer before
    it is stored and reports it, once per turn; a marker anywhere else, or in
    a tool's result, flags nothing. With `agent_capture_ai_content` on, the
    AI journal keeps the model's answer as it came, marker and reason
    included: the reason is then seen wherever the journal is, by every
    holder of `ai` (`/admin/ai/usage`), not only by `ai.manage`. The chat
    message itself never has it.
  * Settings → AI Agent and AI Agent → Users refuse a newly chosen model that
    does not fit its task (`PhoenixKitAI.Tasks.check_selection/2`), or that
    nobody knows to fit until an admin marks what it can do on its endpoint.
  * AI Agent → Users shows who is blocked (the reason only to `ai.manage`)
    and lets a holder of `agent.manage` lift another person's block (never
    their own, never an Owner's unless they are an Owner).

"Stop" and the turn deadline ask the turn to stop between its steps, so a model
call under way finishes and its cost reaches the journal; a turn still running
after the grace period (`config :phoenix_kit_agent, turn_stop_grace_ms:`,
default 30 000) is killed. With several nodes, a "Stop" made on a node the turn
does not run on goes over PubSub (topic `agent:turn:<turn_ref>`, the message
carries the turn ref only) to the node that runs it, which stops it the same
way; who may stop is checked where "Stop" was pressed. No answer comes back but
the turn's end: when it has not come within the grace period and one more check
of the lock (`turn_check_ms`, default 5 000), the panel says the answer has not
stopped and offers "Stop" again — the request may have been lost, or the turn
was lost with its node (its lock then frees the chat when it expires).

## Configuration

```elixir
# Optional: text the host adds to the assistant's system prompt (what an order
# is, the statuses, the language of the answer). `Mod.fun(%{user_uuid:, locale:})`
# when exported with one argument, else `Mod.fun()`; returns a string or nil.
# An exception or a result that is not a string skips the addendum.
config :phoenix_kit_agent, prompt_addendum: {MyApp.Agent, :prompt}

# Optional: what the host says of the page the chat panel is open on (the
# number of the order shown there, say). `Mod.fun(path, scope)` — the page's
# path and the scope of the user's browser session (the role it acts as);
# returns a string (cut to 200 characters, on one line) or nil, and tells only
# what that scope may see. An exception or a result that is not a string skips
# it; the log names the reason only, never the path or the text. It is called
# as the turn starts, in the panel's process and under the turn's locks, with
# no timeout: keep it fast.
config :phoenix_kit_agent, page_context: {MyApp.Agent, :page_context}
```

The system prompt of a turn is, in this order: the module's prompt (Settings →
AI Agent) and the module's fixed rule for writes, the host's addendum, the admin's prompt for the user, the user's
personal instructions (marked as ranking below the rest), and the context of the
session — the user's name, the role the session acts as, the locale, the date
(not the time, so the prompt stays cacheable) in the site time zone, the path of
the page the panel is open on and what the host's `page_context` says of it.

The admin pages check every event against the scope of the browser session
as it is now — the role it acts as, a logout — not the user's default role. An
Owner's assistant settings are changed by an Owner only, and a settings form
opened before another admin's save does not overwrite it.

Settings → AI Agent sets the module defaults: the default model and the vision
model (among the `phoenix_kit_ai` endpoints that chat; the default's list marks
the models without tools, the vision model's the ones that take no pictures),
the per-user limits, the limits of one turn, the module's prompt (its change is
recorded in the Activity log by field name, never its text) and who is told
about limits (none chosen: every Owner). A user without a model of their own,
while no default is chosen, is refused every turn with a text that says where
the model is chosen.

The Settings page has one switch only an Owner can change,
`agent_capture_ai_content`: when on, the bodies of the assistant's requests are
written to the AI request journal and every holder of the `ai` permission reads
them on `/admin/ai/usage`.

## Installation

```elixir
def deps do
  [
    {:phoenix_kit_agent, "~> 0.1"}
  ]
end
```

The module requires `phoenix_kit_ai` to be enabled (`required_modules/0` is
`["ai"]`) and is switched on in Admin > Modules; it is off by default
(setting `agent_enabled`).

It needs `phoenix_kit` 2.64 or later with its migrations run up to V223 (`mix
phoenix_kit.update`), which keeps the AI journal's cost in dollars (`cost`):
before V223 every limit check fails on the missing column, and so does every
turn.

## Development

```bash
mix deps.get
mix test              # needs a local PostgreSQL; see test/test_helper.exs
mix precommit         # compile --warnings-as-errors + format + credo --strict + dialyzer
```

## License

MIT, see [LICENSE](LICENSE).
