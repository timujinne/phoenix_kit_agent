# Changelog

All notable changes to PhoenixKitAgent will be documented in this file.

## 0.1.0 - 2026-10-24

First release. An AI assistant inside a PhoenixKit application: every user
gets their own chats, kept in the database, with a model that works through the
tools of the PhoenixKit API registry. It sees and does no more than the user
can in their current session. Model calls, endpoints, credentials, budget and
the request journal come from `phoenix_kit_ai`.

### Requirements

- `phoenix_kit ~> 2.64` with core migrations run up to V223 (`mix
  phoenix_kit.update`), which records the AI journal's cost in dollars. Before
  V223 every limit check fails, and so does every turn.
- `phoenix_kit_ai ~> 0.26`, enabled (`required_modules/0` is `["ai"]`).
- Optional host tools: poppler (`pdfinfo`, `pdftotext`, `pdftoppm`) for PDFs,
  ImageMagick (`convert`, `identify`) for pictures. Without them those files
  fail with `pdf_tools_missing` / `image_tools_missing` and nothing else
  breaks.
- A host with a Content-Security-Policy must allow `script-src
  'unsafe-inline'`; the panel's runtime hooks are inline scripts without a
  nonce.

### Migrations

The module owns its tables through its own chain (`PhoenixKitAgent.Migrations`,
marker `pk_agent_schema:<N>` on `phoenix_kit_agent_conversations`), run by
`mix phoenix_kit.update`:

- **V1:** `phoenix_kit_agent_conversations`, `_messages`, `_attachments`,
  `_user_settings` and `_limit_events`.
- **V2:** `assistant_message_uuid` and `confirmation_uuid` on messages, for
  confirmed writes.

### Added

- **Module registration** (key `agent`, off by default via `agent_enabled`)
  with the permissions `agent` and `agent.manage`.
- **The chat panel in the admin header** (`PhoenixKitAgent.Web.Dock`, a header
  widget). It lists the user's chats, newest first, with rename and archive,
  and docks a resizable panel with the feed, file attachments, Stop, a
  thinking / calling-a-tool indicator and the user's personal instructions.
  The open chat and width survive navigation, reloads and reconnects. Answers
  render as markdown with no remote images or raw HTML, and links open in a
  new tab with their domain shown. Tool calls appear as a summary only. No
  panel while the module is off or the session is impersonated, and the host
  bundles no JS or CSS for it.
- **The turn loop** (`PhoenixKitAgent.Turns`): rounds of model and tool calls
  over the session's own tools (`Executor.visible_for/3`, `execute_as/5`), with
  per-chat locks, Stop, a turn deadline and grace-period kill, Stop across
  nodes over PubSub, and recovery of turns lost with their node.
- **Writes the user confirms** (`PhoenixKitAgent.Confirmations`). The assistant
  sees a module's write tools only when that module's "Agent may act" box is
  ticked in Settings → API. A write ends the turn with a card showing core's
  preview: Run (re-checked under the clicking session), Cancel the change, or
  Ask again once it expired. One waiting change per answer, one card per
  change. The model reads the outcome as a fixed phrase, never the tool's
  result.
- **Attachments** (`PhoenixKitAgent.Attachments`): png/jpg/webp/heic, PDF,
  xlsx/csv and txt/md, recognised by content. They are kept in a hidden
  Storage library reachable only through expiring owner-session URLs. Before
  the turn, PDFs become text and sheets become CSV. Pictures go to the model
  as pixels when it is known to take images, otherwise the vision model
  (`agent_vision_endpoint_uuid`) describes them. Everything is cut to
  configurable bounds with a visible "continues" line. JPEG metadata is
  stripped, workbooks are unzipped against a byte budget, and processing slots
  are capped per node and per user.
- **Limits** (`PhoenixKitAgent.Limits`): money per day and month and turns per
  day, per user or the module default, counted from the AI journal in the
  site time zone. They are checked before each turn, with a chat notice and
  `agent_limit` notifications at 80 % and 100 % to the user and the watchers
  (`agent_limit_watchers`, default every Owner).
- **The AI task guard:** the `agent.chat` and `agent.attachment` tasks
  (`ai_tasks/0`). Each turn is admitted once, a blocked user or a task over its
  limit gets a notice, off-purpose requests are flagged through a marker that
  is stripped from the stored answer, and models that don't fit the task are
  refused in the settings forms.
- **System prompt** (`PhoenixKitAgent.Prompt`), in this order: the module's
  prompt and its write rule, the host's `prompt_addendum`, the admin's prompt
  for the user, the user's instructions, and the session context (name, role,
  locale, date, page path and the host's `page_context`).
- **Admin pages:** Settings → AI Agent (default and vision models, limits,
  prompt, watchers, and an Owner-only `agent_capture_ai_content` switch),
  AI Agent → Users (each user's model, limits, spending and guard blocks, for
  `agent.manage`) and AI Agent → Spending (today and this month). Every event
  is checked against the browser session's current scope.
- Per-user settings (`PhoenixKitAgent.UserConfig`), and cleanup of a user's
  chats and files when the user is deleted.
- Notices for an AI account out of credit, model errors and limits, in the
  user's language. The interface ships in English, Estonian, Russian,
  Ukrainian, French and German.
