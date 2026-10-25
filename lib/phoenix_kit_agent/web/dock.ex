defmodule PhoenixKitAgent.Web.Dock do
  @moduledoc """
  The assistant in the admin header (spec §10): a button before the
  notifications bell, the list of the user's chats under it, and the chat
  panel on the right. A sticky LiveView, rendered by core's admin layout as
  the module's header widget (`PhoenixKitAgent.header_widgets/0`), so it keeps
  its state across admin navigation.

  ## Whose panel it is

  The widget's session (`PhoenixKitAgent.header_widget_session/1`) holds only
  the user's uuid and locale. Who acts is decided here, in the **connected**
  mount, from the session LiveView hands the panel — the cookie session merged
  in (spec §6.5): the session reference (`SessionRef.from_session/1`) and
  whether the account is borrowed (`MultiSession.impersonated?/1`). The panel
  then works only when the session is not impersonated, belongs to the uuid
  of the widget's session, and may use the assistant
  (`PhoenixKitAgent.Conversations.authorize_session/2`). Otherwise — and in the
  static render, before any of it is known — it renders nothing and every
  event is ignored: no list, no chat, no call (spec §8, В13).

  Every event goes through `PhoenixKitAgent.Conversations`,
  `PhoenixKitAgent.Turns`, `PhoenixKitAgent.Attachments` and
  `PhoenixKitAgent.UserConfig` with the reference and the flag, so each one is
  checked against the session's scope as it is at that moment; a uuid from the
  browser is only ever a chat or a file to look up for that user. A chat's
  topic is subscribed to only through `Conversations.subscribe/3`, after its
  ownership is checked.

  ## The feed

  Opening a chat reads its latest messages (`Conversations.list_messages/3`,
  `latest: true`) into a stream; "Earlier messages" brings the page before
  (`before:` the first one shown). A new message is announced on the chat's
  topic and read with `list_messages/3` (`after:` the last one shown) or
  `get_message/4` — the chat is never read again whole; a message of the user
  moves the chat to the top of the list with its title. Only the chat shown is
  listened to. A tool call is shown folded, by its summary
  (`tool_summary`), never with what the tool returned; a model answer through
  `PhoenixKitAgent.Web.Markdown` (no outside pictures, no raw HTML, every link
  with its domain and `rel="noopener noreferrer nofollow"`, spec §8.2).

  A write the model asked for is a confirmation card in the feed
  (`PhoenixKitAgent.Confirmations`): every `tool` message waiting for one is
  shown with what `Confirmations.cards/4` says of it — core's preview through
  core's `operation_preview` component, the arguments the model sent as plain
  text (never markdown or a link), and "Run" / "Cancel the change"; "Ask
  again" once it ran out; only "Cancel the change" once the user may no
  longer use its tool. Opening a chat first gives the cards core no longer
  holds their notice (`Confirmations.settle_lapsed/3`: a click lost with its
  node, a row that ran out), so none of them waits on the page or above it.
  Opening the chat, "Earlier messages" and every new
  message find the cards by their `confirmation_uuid`, so a card still waiting
  is waiting again after a reload; the notice that settles a card renders it
  again. A card that waits (no notice yet) further back than the page of the
  chat the panel loaded is found too (`Confirmations.waiting_cards/3`): it is
  shown above the feed (under an id of its own), until "Earlier messages"
  reaches it and it takes its place in the feed. A click
  runs off this process: a task under `PhoenixKitAgent.Confirmations.TaskSupervisor`,
  not linked to the panel, which the panel waits for (`start_async/3`), so a
  closed tab does not stop a write half-way. A click while the card is busy
  does nothing; a refusal is shown on the card, which keeps waiting.

  A chat that is locked by a turn lost with its node gets the notice "the
  answer was interrupted" when it is opened (`Turns.settle_interrupted/3`).
  A notice is shown by its `error` code in the panel's language
  (`PhoenixKitAgent.Web.Dock.Texts.notice/1`), else as it was stored.
  "New chat" only empties the panel: the chat is made with its first message
  or file, and deleted again (`Conversations.delete_conversation/3`) when that
  message or file is refused while nothing else is in it.

  ## Sending, stopping, files

  "Send" starts a turn (`Turns.start/6`) with the files that are ready, the
  page the browser is on (a path, for the model's context, spec §7.1 p.5) and
  the user's locale; an exception there is caught, logged as its class only,
  and shown as a notice in the panel. A send while the panel shows a turn
  first asks the chat's lock (`Turns.settle_interrupted/3`): while the turn
  runs the send is let go; a turn whose end never reached the panel is let go
  of, and the message goes. A chat busy with a turn of another tab shows that
  turn, with its "Stop".
  "Stop" asks the turn to stop — on whichever node runs it (`Turns.stop/4`
  passes the request on over PubSub while the chat's lock is within its
  time); nothing answers it but the turn's end, so when that has not come
  within the grace period and one more check of the lock, the panel says the
  answer has not stopped and offers "Stop" again (a turn lost with its node
  frees the chat when its lock expires). When `Turns.stop/4` finds no such
  turn, the chat's lock says what to show. The indicator says whether the model thinks or a
  tool is called; in the browser it gives up after the deadline of a turn and
  its grace period (`Monitor.stop_grace_ms/0`), counted again for each turn
  and after a lost connection is found again.
  The indicator follows the server only: while a turn is shown as running,
  the panel reads the chat's lock again every `:turn_check_ms` (application
  environment, default 5 s), so a turn whose end never reached it — it came
  between the read of the chat and the subscription, or was lost between
  nodes — is let go of, with the messages it left.

  Files come through `allow_upload` (the kinds and the size of §9, the number
  of the user's settings) and are handed to `Attachments.add/4` with the path
  of LiveView's own temporary file (`consume_uploaded_entry/3`, kept until
  `add/4` is done, which runs off this process); the row is read again after
  `add/4` (it may be settled already) and shown only while its chat is the
  one open, and a failed one can be removed. An
  upload can be cancelled while it is on its way, not once `add/4` has it; a
  cancel of an entry that is not there changes nothing. An exception in
  `add/4` is caught in its task and logged as its class only.

  ## In the browser

  The panel opens with the class `pk-dock-open` on `<body>`
  (`PhoenixKitWeb.Components.AdminDock`), which survives a live redirect. Open
  or closed, the chosen chat and the width are kept in `localStorage` by the
  `.DockState` hook and restored (`restore`) when the panel mounts again
  (another `live_session`, a reload) and when it joins again after a lost
  connection, which mounts the LiveView afresh; the turn shown then is the
  one the chat's lock holds now, and every restore patches the whole panel,
  so nothing the browser kept from before the connection was lost stays. A
  panel kept closed reads
  nothing until a chat is opened; a remembered chat that is not the user's
  active one any more is forgotten. The list opens from a focusable `div`
  (Safari does not focus a clicked `<button>`, and the list is open while it
  has the focus); choosing a chat moves the focus to the panel, "New chat" to
  the input, so the list closes. The markup and the hooks are in
  `PhoenixKitAgent.Web.Dock.Panel`; the hooks are runtime colocated hooks, so
  the host bundles nothing for them, but they are inline scripts: under a
  Content-Security-Policy the page needs `script-src 'unsafe-inline'` (they
  carry no nonce). The text being written stays the browser's
  (`phx-update="ignore"`), so no re-render wipes it, and goes to the server
  only with the form (`phx-debounce="blur"`).

  The tools get the user's locale, the endpoint's URL and, when the host's
  socket passes `:peer_data` / `:x_headers` in its `connect_info`, the client
  address as their request context.

  ## Nothing in the log

  `log: false`: LiveView would log every event with its parameters — the
  user's text. No text of a message, an answer or a file name is logged here.
  An exception in an event, a message of the chat, an upload's progress or a
  finished task is caught (`guarded/2`), logged as its class only, and shown
  as a notice: a crash report would hold the event's parameters (the draft)
  and the whole state (the chats, the feed). Not covered: a crash in `mount`
  or in `render` still ends the LiveView with such a report.
  """

  use Phoenix.LiveView, layout: false, log: false
  use Gettext, backend: PhoenixKitAgent.Gettext

  require Logger

  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitAgent.{Attachments, Config, Confirmations, Conversations, Turns, UserConfig}
  alias PhoenixKitAgent.Schemas.{Message, UserSettings}
  alias PhoenixKitAgent.Turns.Monitor
  alias PhoenixKitAgent.Web.Dock.{Panel, Texts}
  alias PhoenixKitWeb.Users.MultiSession

  @accept ~w(.png .jpg .jpeg .webp .heic .heif .pdf .xlsx .csv .txt .md)
  @mb 1_048_576
  # How many messages a chat opens with, and how many more "Earlier" brings.
  @messages_page 50
  # What the browser waits beyond a turn's deadline and its stop grace period
  # (`Monitor.stop_grace_ms/0`) before it says that no answer is coming.
  @wait_margin_ms 15_000
  # How often the panel reads again the state of the turn it shows
  # (`:turn_check_ms`).
  @turn_check_ms 5_000

  # ── mount ───────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    socket = assign(socket, active?: false)

    if connected?(socket),
      do: {:ok, activate(socket, session)},
      else: {:ok, socket}
  end

  # The panel works only for a session that is its user's own, not borrowed,
  # and may use the assistant now (see the moduledoc).
  defp activate(socket, session) do
    impersonated? = MultiSession.impersonated?(session)

    with false <- impersonated?,
         {:ok, {_token_uuid, user_uuid} = ref} <- SessionRef.from_session(session),
         ^user_uuid <- session["user_uuid"],
         {:ok, ^user_uuid} <- Conversations.authorize_session(ref, impersonated: impersonated?) do
      locale = locale(session["locale"])
      if locale, do: put_locale(locale)
      settings = UserConfig.effective(user_uuid)

      socket
      |> assign(
        active?: true,
        ref: ref,
        impersonated?: impersonated?,
        user_uuid: user_uuid,
        locale: locale,
        request_context: request_context(socket, locale),
        open?: false,
        conversation: nil,
        last_uuid: nil,
        first_uuid: nil,
        earlier?: false,
        turn_ref: nil,
        activity: nil,
        unsent: [],
        error: nil,
        renaming: nil,
        instructions_form: nil,
        fresh_uuid: nil,
        turn_check: nil,
        cards: %{},
        pinned: [],
        card_busy: MapSet.new(),
        card_notes: %{},
        restored: 0,
        timeout_ms: Config.turn_deadline_s() * 1_000 + Monitor.stop_grace_ms() + @wait_margin_ms
      )
      |> allow_upload(:files,
        accept: @accept,
        max_entries: max(settings.max_attachments_per_message, 1),
        max_file_size: max(settings.max_attachment_mb * @mb, 1),
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> stream_configure(:messages, dom_id: &"pk-agent-msg-#{&1.uuid}")
      |> stream(:messages, [])
      |> load_chats()
    else
      _not_this_session -> socket
    end
  end

  # The panel's own texts and core's components in it (the times of the list).
  defp put_locale(locale) do
    Gettext.put_locale(PhoenixKitAgent.Gettext, locale)
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
  end

  defp locale(locale) when is_binary(locale) do
    if Regex.match?(~r/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$/, locale), do: locale
  end

  defp locale(_none), do: nil

  # What the tools' handlers get as their context (spec §6.5, ревью В-10):
  # the user's locale, the application's endpoint URL (the panel is mounted by
  # a layout, not at a route, so it has no `host_uri` of its own) and the
  # client address, when the host's socket passes `:peer_data` / `:x_headers`
  # in its `connect_info`.
  defp request_context(socket, locale) do
    [
      language: locale,
      base_url: socket.endpoint.url(),
      ip: IpAddress.client_address_from_socket(socket)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp me(socket), do: [impersonated: socket.assigns.impersonated?]

  # ── events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event(_event, _params, %{assigns: %{active?: false}} = socket),
    do: {:noreply, socket}

  def handle_event(event, params, socket),
    do: guarded(socket, fn -> event(event, params, socket) end)

  # The browser's memory of the panel, when it mounts or joins again after a
  # lost connection (`.DockState`). A panel kept closed reads nothing: its
  # chat is opened from the list; a chat that is not the user's active one
  # any more is forgotten.
  #
  # Every restore changes `restored`, so its answer always patches the panel:
  # whatever the browser kept from before the connection was lost (a copy of
  # the panel it held while an event was waiting for its answer) is replaced by
  # what the server shows now.
  defp event("restore", params, socket) do
    open? = params["open"] == true
    socket = assign(socket, open?: open?, restored: socket.assigns.restored + 1)

    case params["conversation_uuid"] do
      uuid when is_binary(uuid) and open? ->
        case open_conversation(socket, uuid, active_only: true) do
          {:ok, socket} -> {:noreply, socket}
          {:error, _reason, socket} -> {:noreply, store(socket)}
        end

      _none_or_closed ->
        {:noreply, socket}
    end
  end

  defp event("panel_closed", _params, socket),
    do: {:noreply, socket |> assign(open?: false) |> store()}

  defp event("refresh_chats", _params, socket), do: {:noreply, load_chats(socket)}

  defp event("more_chats", _params, socket) do
    case socket.assigns.next_cursor do
      nil ->
        {:noreply, socket}

      cursor ->
        case Conversations.list_conversations(socket.assigns.ref, me(socket) ++ [cursor: cursor]) do
          {:ok, page} ->
            {:noreply,
             assign(socket,
               chats: socket.assigns.chats ++ page.conversations,
               next_cursor: page.next_cursor
             )}

          {:error, reason} ->
            {:noreply, refused(socket, reason)}
        end
    end
  end

  # An empty panel: the chat is made with its first message or file
  # (`ensure_conversation/1`), so a click alone leaves no empty chat behind.
  defp event("new_chat", _params, socket) do
    {:noreply,
     socket
     |> close_conversation()
     |> assign(open?: true, error: nil)
     |> store()}
  end

  defp event("load_earlier", _params, socket) do
    with %{uuid: uuid} <- socket.assigns.conversation,
         first when is_binary(first) <- socket.assigns.first_uuid do
      opts = me(socket) ++ [before: first, limit: @messages_page]

      case Conversations.list_messages(socket.assigns.ref, uuid, opts) do
        {:ok, messages} ->
          {socket, shown, again} = with_cards(socket, messages)
          here = MapSet.new(messages, & &1.uuid)

          {:noreply,
           socket
           |> assign(
             first_uuid: first_uuid(messages, first),
             earlier?: length(messages) == @messages_page,
             pinned: Enum.reject(socket.assigns.pinned, &MapSet.member?(here, &1.uuid))
           )
           |> stream(:messages, Enum.reverse(shown), at: 0)
           |> show_again(again)}

        {:error, reason} ->
          {:noreply, refused(socket, reason)}
      end
    else
      _nothing_earlier -> {:noreply, socket}
    end
  end

  defp event("open_chat", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    case open_conversation(assign(socket, open?: true), uuid) do
      {:ok, socket} -> {:noreply, socket}
      {:error, reason, socket} -> {:noreply, refused(socket, reason)}
    end
  end

  defp event("start_rename", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    if Enum.any?(socket.assigns.chats, &(&1.uuid == uuid)),
      do: {:noreply, assign(socket, renaming: uuid)},
      else: {:noreply, socket}
  end

  defp event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, renaming: nil)}

  defp event("rename_chat", %{"uuid" => uuid, "title" => title}, socket)
       when is_binary(uuid) do
    case Conversations.rename_conversation(socket.assigns.ref, uuid, title, me(socket)) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(renaming: nil, error: nil)
         |> replace_chat(conversation)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         assign(socket, error: gettext("A title cannot be empty or longer than 200 characters."))}

      {:error, reason} ->
        {:noreply, socket |> assign(renaming: nil) |> refused(reason)}
    end
  end

  defp event("archive_chat", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    case Conversations.archive_conversation(socket.assigns.ref, uuid, me(socket)) do
      {:ok, conversation} ->
        socket =
          assign(socket,
            chats: Enum.reject(socket.assigns.chats, &(&1.uuid == conversation.uuid))
          )

        if current_uuid(socket) == conversation.uuid,
          do: {:noreply, socket |> close_conversation() |> store()},
          else: {:noreply, socket}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  defp event("composer_change", _params, socket), do: {:noreply, socket}

  defp event("send", %{"message" => params}, socket) when is_map(params) do
    case sync_turn(socket) do
      # A second Enter (`requestSubmit()` passes the disabled button) while
      # the turn runs: there is nothing to say.
      {:running, socket} -> {:noreply, socket}
      {:idle, socket} -> {:noreply, send_message(socket, params)}
      {:error, reason, socket} -> {:noreply, refused(socket, reason)}
    end
  end

  defp event("stop", _params, socket) do
    with %{uuid: uuid} <- socket.assigns.conversation,
         turn_ref when is_binary(turn_ref) <- socket.assigns.turn_ref do
      case Turns.stop(socket.assigns.ref, socket.assigns.impersonated?, uuid, turn_ref) do
        :ok -> {:noreply, socket |> assign(activity: :stopping, error: nil) |> await_stop()}
        {:error, :not_running} -> {:noreply, after_lost_stop(socket, uuid, turn_ref)}
        {:error, reason} -> {:noreply, refused(socket, reason)}
      end
    else
      _nothing_running -> {:noreply, socket}
    end
  end

  # Only an upload still on its way: a finished one is with
  # `Attachments.add/4` already, and an unknown ref (a second click, an entry
  # gone since) would make `cancel_upload/3` raise.
  defp event("cancel_upload", %{"ref" => ref}, socket) when is_binary(ref) do
    if Enum.any?(socket.assigns.uploads.files.entries, &(&1.ref == ref and not &1.done?)),
      do: {:noreply, cancel_upload(socket, :files, ref)},
      else: {:noreply, socket}
  end

  defp event("discard_attachment", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    case Attachments.discard(socket.assigns.ref, uuid, me(socket)) do
      :ok ->
        {:noreply, assign(socket, unsent: Enum.reject(socket.assigns.unsent, &(&1.uuid == uuid)))}

      {:error, reason} ->
        {:noreply, socket |> refused(reason) |> reload_unsent()}
    end
  end

  defp event("dismiss_error", _params, socket), do: {:noreply, assign(socket, error: nil)}

  defp event("toggle_instructions", _params, socket) do
    if socket.assigns.instructions_form do
      {:noreply, assign(socket, instructions_form: nil)}
    else
      case UserConfig.get_personal_instructions(socket.assigns.ref, me(socket)) do
        {:ok, text} -> {:noreply, assign(socket, instructions_form: instructions_form(text))}
        {:error, reason} -> {:noreply, refused(socket, reason)}
      end
    end
  end

  # Only text: anything else (a forged map or list) would come back into the
  # form and could not be rendered.
  defp event(
         "save_instructions",
         %{"instructions" => %{"personal_instructions" => text}},
         socket
       )
       when is_binary(text) do
    case UserConfig.put_personal_instructions(socket.assigns.ref, text, me(socket)) do
      {:ok, stored} ->
        {:noreply, assign(socket, instructions_form: instructions_form(stored), error: nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, instructions_form: to_form(changeset, as: :instructions))}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  # A click on a confirmation card the panel shows, not busy with one already.
  defp event(action, %{"uuid" => uuid}, socket)
       when action in ["confirm_card", "reject_card", "repeat_card"] and is_binary(uuid) do
    with %{uuid: conversation_uuid} <- socket.assigns.conversation,
         %Message{} = card <- shown_card(socket, uuid),
         false <- MapSet.member?(socket.assigns.card_busy, uuid) do
      %{ref: ref, impersonated?: impersonated?} = socket.assigns
      opts = [request_context: socket.assigns.request_context]
      args = [ref, impersonated?, conversation_uuid, uuid, opts]
      fun = card_action(action)

      socket =
        socket
        |> assign(
          card_busy: MapSet.put(socket.assigns.card_busy, uuid),
          card_notes: Map.delete(socket.assigns.card_notes, uuid)
        )
        |> refresh_cards([card])

      {:noreply,
       start_async(socket, {:card, uuid}, fn ->
         detached(fn -> apply(Confirmations, fun, args) end)
       end)}
    else
      _not_a_card_here_or_busy -> {:noreply, socket}
    end
  end

  # A malformed event (forged, or of an older page) changes nothing.
  defp event(_event, _params, socket), do: {:noreply, socket}

  # ── chats ───────────────────────────────────────────────────────────

  defp load_chats(socket) do
    case Conversations.list_conversations(socket.assigns.ref, me(socket)) do
      {:ok, page} -> assign(socket, chats: page.conversations, next_cursor: page.next_cursor)
      {:error, _reason} -> assign(socket, chats: [], next_cursor: nil)
    end
  end

  defp replace_chat(socket, conversation) do
    chats =
      Enum.map(socket.assigns.chats, fn chat ->
        if chat.uuid == conversation.uuid, do: conversation, else: chat
      end)

    current =
      if current_uuid(socket) == conversation.uuid,
        do: conversation,
        else: socket.assigns.conversation

    assign(socket, chats: chats, conversation: current)
  end

  defp current_uuid(%{assigns: %{conversation: %{uuid: uuid}}}), do: uuid
  defp current_uuid(_socket), do: nil

  # Subscribes to the chat (after the ownership check), settles a turn lost
  # with its node and the cards core no longer holds, and reads its messages
  # and its waiting files. The topic of
  # the chat shown before is left only once the new one is read.
  defp open_conversation(socket, uuid, opts \\ []) do
    %{ref: ref, impersonated?: impersonated?} = socket.assigns
    previous = current_uuid(socket)

    with {:ok, conversation} <- Conversations.owned_conversation(ref, uuid, me(socket)),
         :ok <- openable(conversation, opts),
         :ok <- subscribe(socket, conversation.uuid, previous),
         {:ok, state} <- Turns.settle_interrupted(ref, impersonated?, conversation.uuid),
         # A turn or a click that holds the user's lock settles them itself.
         _lapsed = Confirmations.settle_lapsed(ref, impersonated?, conversation.uuid),
         {:ok, messages} <-
           Conversations.list_messages(
             ref,
             conversation.uuid,
             me(socket) ++ [latest: true, limit: @messages_page]
           ),
         {:ok, unsent} <- Attachments.list_unsent(ref, conversation.uuid, me(socket)) do
      if previous && previous != conversation.uuid, do: Conversations.unsubscribe(previous)

      away = waiting_away(socket, conversation, messages)

      {socket, shown, _again} =
        socket
        |> assign(conversation: conversation, cards: %{}, card_notes: %{})
        |> with_cards(away ++ messages)

      {pinned, messages} = Enum.split(shown, length(away))

      {turn_ref, activity} =
        case state do
          {:running, turn_ref} -> {turn_ref, activity_after(messages, :thinking)}
          _idle_or_settled -> {nil, nil}
        end

      {:ok,
       socket
       |> assign(
         conversation: conversation,
         last_uuid: last_uuid(messages, nil),
         first_uuid: first_uuid(messages, nil),
         earlier?: length(messages) == @messages_page,
         turn_ref: turn_ref,
         activity: activity,
         unsent: unsent,
         pinned: pinned,
         error: nil
       )
       |> stream(:messages, messages, reset: true)
       |> store()}
    else
      {:error, reason} ->
        if is_binary(uuid) and uuid != previous, do: Conversations.unsubscribe(uuid)
        {:error, reason, socket}
    end
  end

  # The cards of the chat that wait, but are not among `messages` (the page
  # loaded): older than all of it.
  defp waiting_away(socket, conversation, messages) do
    %{ref: ref, impersonated?: impersonated?} = socket.assigns
    here = MapSet.new(messages, & &1.uuid)

    case Confirmations.waiting_cards(ref, impersonated?, conversation.uuid) do
      {:ok, cards} -> Enum.reject(cards, &MapSet.member?(here, &1.uuid))
      {:error, _reason} -> []
    end
  end

  defp openable(%{status: "active"}, _opts), do: :ok

  defp openable(_put_away, opts),
    do: if(opts[:active_only], do: {:error, :not_found}, else: :ok)

  # The chat shown now is subscribed to already.
  defp subscribe(_socket, uuid, uuid), do: :ok

  defp subscribe(socket, uuid, _other),
    do: Conversations.subscribe(socket.assigns.ref, uuid, me(socket))

  defp close_conversation(socket) do
    if uuid = current_uuid(socket), do: Conversations.unsubscribe(uuid)

    socket
    |> assign(
      conversation: nil,
      last_uuid: nil,
      first_uuid: nil,
      earlier?: false,
      turn_ref: nil,
      activity: nil,
      unsent: [],
      cards: %{},
      pinned: [],
      card_notes: %{}
    )
    |> stream(:messages, [], reset: true)
  end

  # A message needs a chat: the open one, else a new one.
  defp ensure_conversation(%{assigns: %{conversation: %{}}} = socket), do: {:ok, socket}

  defp ensure_conversation(socket) do
    case Conversations.create_conversation(socket.assigns.ref, %{}, me(socket)) do
      {:ok, conversation} ->
        socket
        |> assign(
          chats: [conversation | socket.assigns.chats],
          open?: true,
          fresh_uuid: conversation.uuid
        )
        |> open_conversation(conversation.uuid)

      {:error, reason} ->
        {:error, reason, socket}
    end
  end

  # A chat the panel made for a first message or file that was then refused
  # is deleted again while nothing is in it, so a failed start leaves no
  # empty "New chat" behind (the refusal stays on the panel).
  defp drop_fresh(socket, done_entry_ref \\ nil) do
    %{fresh_uuid: fresh, last_uuid: last, unsent: unsent} = socket.assigns

    if fresh && fresh == current_uuid(socket) && is_nil(last) && unsent == [] &&
         not uploading?(socket, done_entry_ref) do
      _ = Conversations.delete_conversation(socket.assigns.ref, fresh, me(socket))

      socket
      |> assign(fresh_uuid: nil, chats: Enum.reject(socket.assigns.chats, &(&1.uuid == fresh)))
      |> close_conversation()
      |> store()
    else
      socket
    end
  end

  defp last_uuid([], previous), do: previous
  defp last_uuid(messages, _previous), do: List.last(messages).uuid

  defp first_uuid([], previous), do: previous
  defp first_uuid([first | _], _previous), do: first.uuid

  # Keeps the panel and the chosen chat in the browser (`.DockState`).
  defp store(socket) do
    push_event(socket, "pk-agent:store", %{
      open: socket.assigns.open?,
      conversation_uuid: current_uuid(socket)
    })
  end

  # ── turns ───────────────────────────────────────────────────────────

  # The turn the panel shows as running, as the chat's lock has it now: its
  # end may never have reached this panel (a broadcast lost between nodes).
  defp sync_turn(%{assigns: %{turn_ref: nil}} = socket), do: {:idle, socket}

  defp sync_turn(socket) do
    %{ref: ref, impersonated?: impersonated?} = socket.assigns

    case Turns.settle_interrupted(ref, impersonated?, current_uuid(socket)) do
      {:ok, {:running, turn_ref}} ->
        {:running, assign(socket, turn_ref: turn_ref)}

      {:ok, _idle_or_settled} ->
        {:idle, socket |> assign(turn_ref: nil, activity: nil) |> reload_unsent()}

      {:error, reason} ->
        {:error, reason, socket}
    end
  end

  defp send_message(socket, params) do
    text = params["text"]

    cond do
      not is_binary(text) or String.trim(text) == "" ->
        refused(socket, :empty_message)

      Enum.any?(socket.assigns.unsent, &(&1.status == "pending")) or uploading?(socket) ->
        refused(socket, :files_pending)

      true ->
        case ensure_conversation(socket) do
          {:ok, socket} -> start_turn(socket, text, page(params["page"]))
          {:error, reason, socket} -> refused(socket, reason)
        end
    end
  end

  defp start_turn(socket, text, page) do
    %{ref: ref, impersonated?: impersonated?} = socket.assigns
    ready = for %{status: "ready", uuid: uuid} <- socket.assigns.unsent, do: uuid

    opts = [
      page: page,
      locale: socket.assigns.locale,
      request_context: socket.assigns.request_context
    ]

    case safe_start(ref, impersonated?, current_uuid(socket), text, ready, opts) do
      {:ok, turn_ref} ->
        socket
        |> assign(
          turn_ref: turn_ref,
          activity: :thinking,
          error: nil,
          fresh_uuid: nil,
          unsent: Enum.reject(socket.assigns.unsent, &(&1.uuid in ready))
        )
        |> push_event("pk-agent:sent", %{})

      {:error, :conversation_busy} ->
        socket |> refused(:conversation_busy) |> adopt_running_turn() |> reload_unsent()

      {:error, reason} ->
        socket |> refused(reason) |> reload_unsent() |> drop_fresh()
    end
  end

  # The chat is busy with a turn this panel did not start (another tab): it is
  # shown as running, so its Stop is there.
  defp adopt_running_turn(socket) do
    %{ref: ref, impersonated?: impersonated?} = socket.assigns

    case Turns.settle_interrupted(ref, impersonated?, current_uuid(socket)) do
      {:ok, {:running, turn_ref}} -> assign(socket, turn_ref: turn_ref, activity: :thinking)
      _idle_settled_or_refused -> socket
    end
  end

  # A Stop is told nothing back: the turn's end over the chat's topic is the
  # answer. When none has come within the grace period and one more check of
  # the lock (`info({:pk_agent_stop_unanswered, _}, _)`), Stop is offered
  # again — the request may have been lost between nodes, or no node runs the
  # turn any more (its lock then frees the chat when it expires).
  defp await_stop(socket) do
    Process.send_after(
      self(),
      {:pk_agent_stop_unanswered, socket.assigns.turn_ref},
      Monitor.stop_grace_ms() + turn_check_ms()
    )

    socket
  end

  # "Stop" found no such turn. The chat's lock says what it is now: a newer
  # turn is shown instead; the same turn still in its lock's time (its task is
  # here but the monitor is restarting — the task goes with it — or the lock
  # changed between the two reads) is said to be lost, rather than offer a
  # Stop that cannot work; else the chat is free (a lost turn past its time is
  # settled, its notice comes over the topic).
  defp after_lost_stop(socket, uuid, turn_ref) do
    %{ref: ref, impersonated?: impersonated?} = socket.assigns
    socket = assign(socket, turn_ref: nil, activity: nil)

    case Turns.settle_interrupted(ref, impersonated?, uuid) do
      {:ok, {:running, ^turn_ref}} -> refused(socket, :turn_lost)
      {:ok, {:running, newer}} -> assign(socket, turn_ref: newer, activity: :thinking)
      {:ok, _idle_or_settled} -> socket
      {:error, reason} -> refused(socket, reason)
    end
  end

  # An exception as the turn starts (the history, the prompt, the monitor)
  # must not take the panel down; its terms can hold the user's text, so only
  # its class is logged.
  defp safe_start(ref, impersonated?, uuid, text, attachments, opts) do
    Turns.start(ref, impersonated?, uuid, text, attachments, opts)
  rescue
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] the chat panel could not start a turn: #{inspect(exception.__struct__)}"
      )

      {:error, :start_failed}
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAgent] the chat panel could not start a turn: #{kind}")
      {:error, :start_failed}
  end

  # The page as the browser says it is: a string, or none. Whether it is a
  # path of this site is `PhoenixKitAgent.Prompt`'s to decide (a query, a
  # fragment, another site or a second line are left out there).
  defp page(path) when is_binary(path), do: path
  defp page(_none), do: nil

  # What the turn does now, from the last of its messages.
  defp activity_after(messages, default) do
    Enum.reduce(messages, default, fn message, activity -> activity_of(message, activity) end)
  end

  defp activity_of(%Message{role: "assistant", tool_calls: [_ | _] = calls}, _activity),
    do: {:tool, calls |> Enum.map(& &1["name"]) |> Enum.filter(&is_binary/1) |> Enum.uniq()}

  defp activity_of(%Message{role: role}, :stopping) when role in ["user", "tool"], do: :stopping
  defp activity_of(%Message{role: role}, _activity) when role in ["user", "tool"], do: :thinking
  defp activity_of(_message, activity), do: activity

  # ── files ───────────────────────────────────────────────────────────

  # A valid upload is still on its way, or with `Attachments.add/4` (its
  # entry goes when `add/4` is done); one refused by LiveView waits only to be
  # cancelled.
  # (LiveView drops a consumed entry only after the callback that consumed it:
  # `except` is such an entry.)
  defp uploading?(socket, except \\ nil),
    do: Enum.any?(socket.assigns.uploads.files.entries, &(&1.valid? and &1.ref != except))

  defp handle_progress(name, entry, socket),
    do: guarded(socket, fn -> progress(name, entry, socket) end)

  # A finished upload goes to `Attachments.add/4` off this process; its
  # temporary file is kept (`:postpone`) until `add/4` is done with it.
  defp progress(:files, %{done?: true} = entry, %{assigns: %{active?: true}} = socket) do
    case ensure_conversation(socket) do
      {:ok, socket} ->
        path = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:postpone, path} end)
        %{ref: ref} = socket.assigns
        uuid = current_uuid(socket)
        upload = %{path: path, filename: entry.client_name}
        opts = me(socket)

        {:noreply,
         start_async(socket, {:attach, entry.ref}, fn -> safe_add(ref, uuid, upload, opts) end)}

      {:error, reason, socket} ->
        {:noreply, socket |> cancel_upload(:files, entry.ref) |> refused(reason)}
    end
  end

  defp progress(:files, _entry, socket), do: {:noreply, socket}

  # An exception in `add/4` would end the async task with a crash report that
  # holds its terms (a file name, a changeset): only its class is logged.
  defp safe_add(ref, uuid, upload, opts) do
    Attachments.add(ref, uuid, upload, opts)
  rescue
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] the chat panel could not add a file: #{inspect(exception.__struct__)}"
      )

      {:error, :storage_unavailable}
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAgent] the chat panel could not add a file: #{kind}")
      {:error, :storage_unavailable}
  end

  @impl true
  def handle_async({:card, uuid}, result, socket),
    do: guarded(socket, fn -> card_done(uuid, result, socket) end)

  def handle_async(name, result, socket),
    do: guarded(socket, fn -> attached(name, result, socket) end)

  defp attached({:attach, entry_ref}, result, socket) do
    socket = drop_entry(socket, entry_ref)

    case result do
      {:ok, {:ok, attachment}} ->
        {:noreply,
         socket |> assign(error: nil, fresh_uuid: nil) |> refresh_attachment(attachment.uuid)}

      {:ok, {:error, reason}} ->
        {:noreply, socket |> refused(reason) |> drop_fresh(entry_ref)}

      {:exit, _reason} ->
        {:noreply, socket |> refused(:storage_unavailable) |> drop_fresh(entry_ref)}
    end
  end

  # The upload is done with: its temporary file goes.
  defp drop_entry(socket, entry_ref) do
    case Enum.find(socket.assigns.uploads.files.entries, &(&1.ref == entry_ref)) do
      nil ->
        socket

      entry ->
        consume_uploaded_entry(socket, entry, fn _meta -> {:ok, :done} end)
        socket
    end
  end

  # The row as it is now (`add/4` returns it as it was when the processing
  # started, which may have ended since), in the chat it was added to only.
  defp refresh_attachment(socket, uuid) do
    case Attachments.get(socket.assigns.ref, uuid, me(socket)) do
      {:ok, %{message_uuid: nil} = attachment} ->
        if attachment.conversation_uuid == current_uuid(socket),
          do: assign(socket, unsent: put_unsent(socket.assigns.unsent, attachment)),
          else: socket

      _sent_or_gone ->
        assign(socket, unsent: Enum.reject(socket.assigns.unsent, &(&1.uuid == uuid)))
    end
  end

  defp put_unsent(unsent, attachment) do
    if Enum.any?(unsent, &(&1.uuid == attachment.uuid)),
      do: Enum.map(unsent, &if(&1.uuid == attachment.uuid, do: attachment, else: &1)),
      else: unsent ++ [attachment]
  end

  defp reload_unsent(socket) do
    with uuid when is_binary(uuid) <- current_uuid(socket),
         {:ok, unsent} <- Attachments.list_unsent(socket.assigns.ref, uuid, me(socket)) do
      assign(socket, unsent: unsent)
    else
      _ -> socket
    end
  end

  # ── events of the chat ──────────────────────────────────────────────

  @impl true
  def handle_info(_message, %{assigns: %{active?: false}} = socket), do: {:noreply, socket}
  def handle_info(message, socket), do: guarded(socket, fn -> info(message, socket) end)

  # A Stop the turn's end has not answered (`await_stop/1`).
  defp info(
         {:pk_agent_stop_unanswered, turn_ref},
         %{assigns: %{turn_ref: turn_ref, activity: :stopping}} = socket
       ) do
    case sync_turn(socket) do
      {:running, %{assigns: %{turn_ref: ^turn_ref}} = socket} ->
        {:noreply, socket |> assign(activity: :thinking) |> refused(:stop_unanswered)}

      {:running, socket} ->
        {:noreply, assign(socket, activity: :thinking)}

      {:idle, socket} ->
        {:noreply, catch_up(socket)}

      {:error, reason, socket} ->
        {:noreply, socket |> assign(turn_ref: nil, activity: nil) |> refused(reason)}
    end
  end

  defp info({:pk_agent_stop_unanswered, _turn_ref}, socket), do: {:noreply, socket}

  # The turn shown as running, read again (`watch_turn/1`): its end may never
  # reach this panel — it came between the read of the chat and the
  # subscription, or was lost between nodes. The answers it left are read too.
  defp info(:pk_agent_check_turn, socket) do
    socket = assign(socket, turn_check: nil)

    case sync_turn(socket) do
      {:running, socket} ->
        {:noreply, socket}

      {:idle, %{assigns: %{turn_ref: nil}} = socket} ->
        {:noreply, catch_up(socket)}

      {:error, reason, socket} ->
        {:noreply, socket |> assign(turn_ref: nil, activity: nil) |> refused(reason)}
    end
  end

  defp info({:agent_message_added, uuid, message_uuid}, socket) do
    if uuid == current_uuid(socket),
      do: {:noreply, add_messages(socket, uuid, message_uuid)},
      else: {:noreply, socket}
  end

  defp info({:agent_turn_finished, uuid, turn_ref}, socket) do
    if uuid == current_uuid(socket) and turn_ref == socket.assigns.turn_ref,
      do: {:noreply, socket |> assign(turn_ref: nil, activity: nil) |> reload_unsent()},
      else: {:noreply, socket}
  end

  defp info({:agent_attachment_processed, uuid, attachment_uuid}, socket) do
    if uuid == current_uuid(socket),
      do: {:noreply, refresh_attachment(socket, attachment_uuid)},
      else: {:noreply, socket}
  end

  defp info(_other, socket), do: {:noreply, socket}

  # The messages after the last one shown that the panel did not hear of.
  defp catch_up(socket) do
    with uuid when is_binary(uuid) <- current_uuid(socket),
         opts = me(socket) ++ [after: socket.assigns.last_uuid, limit: @messages_page],
         {:ok, messages} <- Conversations.list_messages(socket.assigns.ref, uuid, opts) do
      socket
      |> assign(last_uuid: last_uuid(messages, socket.assigns.last_uuid))
      |> insert_messages(messages)
    else
      _no_chat_or_refused -> socket
    end
  end

  # The messages after the last one shown, and the announced one if it was
  # not among them (committed out of order).
  defp add_messages(socket, uuid, message_uuid) do
    opts = me(socket) ++ [after: socket.assigns.last_uuid, limit: @messages_page]

    case Conversations.list_messages(socket.assigns.ref, uuid, opts) do
      {:ok, messages} ->
        extra =
          if Enum.any?(messages, &(&1.uuid == message_uuid)),
            do: [],
            else: announced(socket, uuid, message_uuid)

        socket
        |> assign(last_uuid: last_uuid(messages, socket.assigns.last_uuid))
        |> insert_messages(messages ++ extra)
        |> follow_chat(messages ++ extra)

      {:error, :invalid_cursor} ->
        insert_messages(socket, announced(socket, uuid, message_uuid))

      {:error, reason} ->
        refused(socket, reason)
    end
  end

  # A message of the user moves the chat to the top of the list, and the
  # first one gives it its title (`Conversations` sets it as it is stored).
  defp follow_chat(socket, messages) do
    with true <- Enum.any?(messages, &(&1.role == "user")),
         {:ok, conversation} <-
           Conversations.owned_conversation(socket.assigns.ref, current_uuid(socket), me(socket)) do
      chats = Enum.reject(socket.assigns.chats, &(&1.uuid == conversation.uuid))
      chats = if conversation.status == "active", do: [conversation | chats], else: chats
      assign(socket, chats: chats, conversation: conversation)
    else
      _no_user_message_or_refused -> socket
    end
  end

  defp announced(socket, uuid, message_uuid) do
    case Conversations.get_message(socket.assigns.ref, uuid, message_uuid, me(socket)) do
      {:ok, message} -> [message]
      {:error, _reason} -> []
    end
  end

  defp insert_messages(socket, messages) do
    activity =
      if socket.assigns.turn_ref,
        do: activity_after(messages, socket.assigns.activity),
        else: socket.assigns.activity

    {socket, shown, again} = with_cards(socket, messages)

    socket
    |> stream_messages(shown)
    |> show_again(again)
    |> assign(activity: activity)
  end

  defp stream_messages(socket, messages),
    do: Enum.reduce(messages, socket, &stream_insert(&2, :messages, &1))

  # Cards rendered again: where they are shown, above the feed or in it.
  defp show_again(socket, cards) do
    by_uuid = Map.new(cards, &{&1.uuid, &1})
    pinned = socket.assigns.pinned

    socket
    |> assign(pinned: Enum.map(pinned, &Map.get(by_uuid, &1.uuid, &1)))
    |> stream_messages(
      Enum.reject(cards, fn card -> Enum.any?(pinned, &(&1.uuid == card.uuid)) end)
    )
  end

  # ── confirmation cards ──────────────────────────────────────────────

  # `messages` with what the panel shows of each confirmation card among them
  # (`Confirmations.cards/4`), and the cards shown already that a notice among
  # them settles, rendered again. The panel keeps the cards it shows by their
  # `confirmation_uuid`.
  defp with_cards(socket, messages) do
    known = socket.assigns.cards

    settled =
      for %Message{role: "notice", confirmation_uuid: uuid} when is_binary(uuid) <- messages,
          card = known[uuid],
          card != nil,
          not Enum.any?(messages, &(&1.uuid == card.uuid)),
          uniq: true,
          do: card

    new = Enum.filter(messages, &card?/1)

    case decorate(socket, new ++ settled) do
      {:ok, socket, by_uuid} ->
        shown = Enum.map(messages, &Map.get(by_uuid, &1.uuid, &1))
        {socket, shown, for(card <- settled, again = by_uuid[card.uuid], do: again)}

      :error ->
        {socket, messages, []}
    end
  end

  defp card?(%Message{role: "tool", tool_outcome: "needs_confirmation", confirmation_uuid: uuid}),
    do: is_binary(uuid)

  defp card?(_message), do: false

  # The cards rendered again as they are now (a click started or ended).
  defp refresh_cards(socket, cards) do
    case decorate(socket, cards) do
      {:ok, socket, by_uuid} ->
        show_again(socket, for(card <- cards, shown = by_uuid[card.uuid], do: shown))

      :error ->
        socket
    end
  end

  defp decorate(socket, []), do: {:ok, socket, %{}}

  defp decorate(socket, cards) do
    %{ref: ref, impersonated?: impersonated?} = socket.assigns

    case Confirmations.cards(ref, impersonated?, current_uuid(socket), cards) do
      {:ok, shown} ->
        known =
          Enum.reduce(cards, socket.assigns.cards, fn card, acc ->
            if Map.has_key?(shown, card.uuid),
              do: Map.put(acc, card.confirmation_uuid, %{card | card: nil}),
              else: acc
          end)

        by_uuid =
          for card <- cards, %{} = view <- [shown[card.uuid]], into: %{} do
            {card.uuid,
             %{
               card
               | card:
                   Map.merge(view, %{
                     busy?: MapSet.member?(socket.assigns.card_busy, card.uuid),
                     note: socket.assigns.card_notes[card.uuid]
                   })
             }}
          end

        {:ok, assign(socket, cards: known), by_uuid}

      {:error, _reason} ->
        :error
    end
  end

  defp shown_card(socket, message_uuid) do
    Enum.find_value(socket.assigns.cards, fn {_uuid, card} ->
      if card.uuid == message_uuid, do: card
    end)
  end

  defp card_action("confirm_card"), do: :confirm
  defp card_action("reject_card"), do: :reject
  defp card_action("repeat_card"), do: :repeat

  # The click runs in a task of the module's supervisor, not linked to the
  # panel: a closed tab does not stop a write half-way. An exception in it is
  # logged as its class only (its terms may hold the arguments).
  defp detached(fun) do
    PhoenixKitAgent.Confirmations.TaskSupervisor
    |> Task.Supervisor.async_nolink(fn -> safe_click(fun) end)
    |> Task.await(:infinity)
  end

  defp safe_click(fun) do
    fun.()
  rescue
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] a confirmation click failed: #{inspect(exception.__struct__)}"
      )

      {:error, :failed}
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAgent] a confirmation click failed: #{kind}")
      {:error, :failed}
  end

  defp card_done(uuid, result, socket) do
    note =
      case result do
        {:ok, {:ok, _outcome}} -> nil
        {:ok, {:error, reason}} -> Texts.card_refusal(reason)
        {:exit, _reason} -> Texts.card_refusal(:failed)
      end

    notes =
      if note,
        do: Map.put(socket.assigns.card_notes, uuid, note),
        else: Map.delete(socket.assigns.card_notes, uuid)

    socket =
      assign(socket, card_busy: MapSet.delete(socket.assigns.card_busy, uuid), card_notes: notes)

    case shown_card(socket, uuid) do
      %Message{} = card -> {:noreply, refresh_cards(socket, [card])}
      nil -> {:noreply, socket}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp refused(socket, reason), do: assign(socket, error: Texts.refusal(reason))

  # An exception in an event, a chat message or a finished task would end the
  # LiveView with a crash report that holds the event's parameters (the
  # user's draft) and the whole state (the chats, the feed): it is caught
  # here, logged as its class only, and the panel says that something went
  # wrong. The socket is the one from before the callback.
  defp guarded(socket, fun) do
    {:noreply, socket} = fun.()
    {:noreply, watch_turn(socket)}
  rescue
    exception ->
      Logger.warning("[PhoenixKitAgent] the chat panel failed: #{inspect(exception.__struct__)}")
      {:noreply, refused(socket, :failed)}
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAgent] the chat panel failed: #{kind}")
      {:noreply, refused(socket, :failed)}
  end

  # While a turn is shown as running, its state is read again every
  # `:turn_check_ms` (`info(:pk_agent_check_turn, _)`); once none is, the check
  # is called off.
  defp watch_turn(%{assigns: %{active?: true}} = socket) do
    case {socket.assigns.turn_ref, socket.assigns.turn_check} do
      {nil, nil} ->
        socket

      {nil, timer} ->
        Process.cancel_timer(timer)
        assign(socket, turn_check: nil)

      {_turn_ref, nil} ->
        timer = Process.send_after(self(), :pk_agent_check_turn, turn_check_ms())
        assign(socket, turn_check: timer)

      {_turn_ref, _timer} ->
        socket
    end
  end

  defp watch_turn(socket), do: socket

  defp turn_check_ms,
    do: Application.get_env(:phoenix_kit_agent, :turn_check_ms, @turn_check_ms)

  defp instructions_form(text) do
    %UserSettings{}
    |> UserSettings.personal_changeset(%{personal_instructions: text})
    |> to_form(as: :instructions)
  end

  # ── render ──────────────────────────────────────────────────────────

  @impl true
  def render(%{active?: false} = assigns) do
    ~H"""
    <div class="hidden"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <Panel.dock
      user_uuid={@user_uuid}
      chats={@chats}
      next_cursor={@next_cursor}
      renaming={@renaming}
      conversation={@conversation}
      messages={@streams.messages}
      pinned={@pinned}
      earlier?={@earlier?}
      activity={@activity}
      timeout_ms={@timeout_ms}
      turn_ref={@turn_ref}
      restored={@restored}
      error={@error}
      instructions_form={@instructions_form}
      unsent={@unsent}
      upload={@uploads.files}
    />
    """
  end
end
