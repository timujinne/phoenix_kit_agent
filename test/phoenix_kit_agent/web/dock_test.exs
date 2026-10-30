defmodule PhoenixKitAgent.Web.DockTest do
  @moduledoc """
  The chat panel (spec §10, §8, §8.2, §12 Б1.7): the header widget, the list
  of chats and the panel, a sticky LiveView that finds its session itself in
  its connected mount and does everything through `Conversations`, `Turns`,
  `Attachments` and `UserConfig` with the session's fresh scope.

  The model is a `Req.Test` stub behind `phoenix_kit_ai`; the panel is mounted
  with `live_isolated/3` over a conn whose cookie session holds the user's
  token, which LiveView merges into the panel's session as it does in a host.
  """

  use PhoenixKitAgent.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.HeaderWidget
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAgent.{Config, Conversations, Turns, UserConfig}
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, Message, UserSettings}
  alias PhoenixKitAgent.Test.{Endpoint, Files, LogProbe, Tools}
  alias PhoenixKitAgent.Turns.Monitor
  alias PhoenixKitAgent.Web.Dock

  @stub __MODULE__
  @model "deepseek/deepseek-v4.1-flash"

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)
    # Uploaded files go to a bucket in a temporary directory.
    _bucket = Files.local_bucket!()

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)

    on_exit(fn ->
      stop_all_turns()
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_agent, :turn_handshake_ms)
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentDock#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("dock")
    {:ok, _} = Roles.assign_role(user, role.name)
    {ref, token} = session_fixture(user)

    %{conn: conn, user: user, role: role, ref: ref, token: token}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp dock(ctx, opts \\ []) do
    cookie = Keyword.get(opts, :cookie, %{"user_token" => ctx.token})
    user_uuid = Keyword.get(opts, :user_uuid, ctx.user.uuid)
    locale = Keyword.get(opts, :locale, "en")

    {:ok, view, _html} =
      ctx.conn
      |> Plug.Test.init_test_session(cookie)
      |> live_isolated(Dock, session: %{"user_uuid" => user_uuid, "locale" => locale})

    view
  end

  defp open_chat(view, chat) do
    view |> element("#pk-agent-chat-#{chat.uuid} [data-role=open]") |> render_click()
  end

  defp send_text(view, text, page \\ "/en/admin/orders/7") do
    # The page is set by the `.Composer` hook in a browser, as the form goes.
    view
    |> form("#pk-agent-composer", message: %{text: text})
    |> render_submit(%{message: %{page: page}})
  end

  defp text_answer(text) do
    %{
      "model" => @model,
      "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}],
      "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}
    }
  end

  defp tool_answer(calls) do
    %{
      "model" => @model,
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => nil, "tool_calls" => calls},
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 9, "total_tokens" => 29}
    }
  end

  defp answer_next(answer) do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})
      Req.Test.json(conn, answer)
    end)
  end

  defp hang_next do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      send(test, {:model_waiting, self()})

      receive do
        :never -> conn
      end
    end)
  end

  # The panel once every turn's task is gone: what a task broadcast (its
  # messages) went out before it ended, so it is with the panel before the
  # render asks for it (all on one node).
  defp await_turn(view) do
    await_children(PhoenixKitAgent.Turns.TaskSupervisor)
    render(view)
  end

  # The panel once the turn of `chat` has ended: the test hears the monitor's
  # `:agent_turn_finished` (`listen/2` first), and once the monitor has
  # handled its next request its broadcast has gone to the panel as well.
  defp await_turn_end(view, chat) do
    uuid = chat.uuid
    assert_receive {:agent_turn_finished, ^uuid, _turn_ref}, 5_000
    _ = :sys.get_state(PhoenixKitAgent.Turns.Monitor)
    render(view)
  end

  defp listen(ctx, chat),
    do: :ok = Conversations.subscribe(ctx.ref, chat.uuid, impersonated: false)

  # The panel once its files are added (`render_async/1`) and read: the
  # processing tasks are gone, and their broadcasts are with the panel.
  defp await_files(view) do
    render_async(view)
    await_children(PhoenixKitAgent.Attachments.TaskSupervisor)
    render(view)
  end

  defp await_children(supervisor) do
    for pid <- Task.Supervisor.children(supervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end

  defp messages(chat) do
    Repo.all(
      from(m in Message,
        where: m.conversation_uuid == ^chat.uuid,
        order_by: [asc: m.inserted_at, asc: m.uuid]
      )
    )
  end

  defp chats_of(user) do
    Repo.all(from(c in Conversation, where: c.user_uuid == ^user.uuid))
  end

  defp lock_of(chat) do
    c = Repo.get!(Conversation, chat.uuid)
    {c.busy_since, c.busy_turn_ref}
  end

  defp stop_all_turns do
    for pid <- Task.Supervisor.children(PhoenixKitAgent.Turns.TaskSupervisor) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    _ = :sys.get_state(PhoenixKitAgent.Turns.Monitor)
  end

  defp chat_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#pk-agent-chats li[id^=pk-agent-chat-]")
    |> Enum.map(fn node -> node |> LazyHTML.attribute("id") |> hd() end)
  end

  defp at(seconds_ago), do: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

  # The chat topics the panel's process listens to.
  defp subscriptions(view), do: Registry.keys(:phoenix_kit_internal_pubsub, view.pid)

  # Holds the test database (the sandbox's one connection) in a transaction
  # of another process until the returned function is called: whatever needs
  # the database meanwhile — `Attachments.add/4` in the panel's task — waits.
  defp hold_the_database do
    test = self()

    holder =
      spawn(fn ->
        Repo.transaction(fn ->
          send(test, :holding)

          receive do
            :release -> :ok
          end
        end)

        send(test, :released)
      end)

    assert_receive :holding

    fn ->
      send(holder, :release)
      assert_receive :released
    end
  end

  # The JS commands of an element's `phx-click`, as `[op, args]` pairs.
  defp click_ops(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("phx-click")
    |> hd()
    |> Jason.decode!()
  end

  defp hook_script(view, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("script[data-phx-runtime-hook$='#{name}']")
    |> LazyHTML.text()
  end

  # ── the header widget ───────────────────────────────────────────────

  describe "the header widget" do
    test "the module declares the panel as a docked header widget" do
      assert [{Dock, "pk-agent-dock-widget", fun, [dock: true]} = entry] =
               PhoenixKitAgent.header_widgets()

      assert is_function(fun, 1)
      assert {:ok, %HeaderWidget{dock: true}} = HeaderWidget.new(entry)
    end

    test "its session is the user's uuid and locale, nothing else", ctx do
      assigns = %{
        phoenix_kit_current_scope: scope_of(ctx.user),
        phoenix_kit_current_user: ctx.user,
        current_locale_base: "et",
        impersonating?: false
      }

      assert PhoenixKitAgent.header_widget_session(assigns) ==
               %{"user_uuid" => ctx.user.uuid, "locale" => "et"}
    end

    test "there is no widget without the agent right, with the module off or when impersonating",
         ctx do
      outsider = user_with(["dashboard"], "outsider")

      base = %{
        phoenix_kit_current_scope: scope_of(ctx.user),
        phoenix_kit_current_user: ctx.user,
        current_locale_base: "en",
        impersonating?: false
      }

      assert PhoenixKitAgent.header_widget_session(%{
               base
               | phoenix_kit_current_scope: scope_of(outsider),
                 phoenix_kit_current_user: outsider
             }) == nil

      assert PhoenixKitAgent.header_widget_session(%{base | impersonating?: true}) == nil

      assert PhoenixKitAgent.header_widget_session(%{base | phoenix_kit_current_scope: nil}) ==
               nil

      {:ok, _} = PhoenixKitAgent.disable_system()
      assert PhoenixKitAgent.header_widget_session(base) == nil
    end
  end

  # ── what is rendered before the panel knows the session ─────────────

  describe "the static render" do
    test "carries no data of the user and no chats; the connected panel does", ctx do
      conversation_fixture(ctx.user, %{title: "Static secret chat"})

      conn =
        ctx.conn
        |> Plug.Test.init_test_session(%{
          "user_token" => ctx.token,
          "test_user_uuid" => ctx.user.uuid
        })

      static = conn |> get("/en/admin/dock-host") |> html_response(200)

      assert static =~ "dock-host-page"
      refute static =~ "Static secret chat"
      refute static =~ "pk-agent-dock-button"
      refute static =~ ctx.user.uuid

      {:ok, host, _html} = live(conn, "/en/admin/dock-host")
      panel = find_live_child(host, "pk-agent-dock-widget")
      assert has_element?(panel, "#pk-agent-dock-button")
      assert has_element?(panel, "#pk-agent-chats", "Static secret chat")
    end
  end

  # ── who gets no panel ───────────────────────────────────────────────

  describe "an impersonated session" do
    setup ctx do
      operator = user_with(["agent"], "operator")
      root = Auth.generate_user_session_token(operator)
      cookie = %{"user_token" => ctx.token, "pk_session_accounts" => [root, ctx.token]}
      chat = conversation_fixture(ctx.user, %{title: "Borrowed chat"})
      %{cookie: cookie, chat: chat}
    end

    test "renders nothing and refuses every event", ctx do
      view = dock(ctx, cookie: ctx.cookie)

      html = render(view)
      refute html =~ "pk-agent-dock-button"
      refute html =~ "Borrowed chat"

      render_click(view, "new_chat", %{})
      render_click(view, "open_chat", %{"uuid" => ctx.chat.uuid})
      render_click(view, "rename_chat", %{"uuid" => ctx.chat.uuid, "title" => "Hijacked"})
      render_click(view, "archive_chat", %{"uuid" => ctx.chat.uuid})
      render_click(view, "restore", %{"open" => true, "conversation_uuid" => ctx.chat.uuid})
      render_submit(view, "send", %{"message" => %{"text" => "Read it all"}})

      refute render(view) =~ "Borrowed chat"
      assert [%Conversation{title: "Borrowed chat", status: "active"}] = chats_of(ctx.user)
      assert messages(ctx.chat) == []
    end
  end

  describe "a session without the right" do
    test "renders nothing and refuses events, even with a forged widget session", ctx do
      outsider = user_with(["dashboard"], "no-agent")
      {_ref, token} = session_fixture(outsider)

      view = dock(ctx, cookie: %{"user_token" => token}, user_uuid: outsider.uuid)

      refute render(view) =~ "pk-agent-dock-button"
      render_click(view, "new_chat", %{})
      assert chats_of(outsider) == []
    end

    test "a widget session made for another user than the cookie's is refused", ctx do
      other = user_with(["agent"], "other")
      conversation_fixture(ctx.user, %{title: "Mine"})

      view = dock(ctx, user_uuid: other.uuid)

      refute render(view) =~ "pk-agent-dock-button"
      refute render(view) =~ "Mine"
    end

    test "nothing without a session at all", ctx do
      view = dock(ctx, cookie: %{})
      refute render(view) =~ "pk-agent-dock-button"
    end
  end

  # ── the list of chats ───────────────────────────────────────────────

  describe "the list of chats:" do
    test "newest first, 20 at a time, then more", ctx do
      chats =
        for n <- 1..23 do
          conversation_fixture(ctx.user, %{title: "Chat #{n}"})
          |> Ecto.Changeset.change(last_message_at: at(1_000 - n))
          |> Repo.update!()
        end

      newest_first = chats |> Enum.reverse() |> Enum.map(&"pk-agent-chat-#{&1.uuid}")

      view = dock(ctx)
      assert chat_ids(render(view)) == Enum.take(newest_first, 20)
      assert has_element?(view, "#pk-agent-new-chat")

      html = view |> element("#pk-agent-more-chats") |> render_click()
      assert chat_ids(html) == newest_first
      refute has_element?(view, "#pk-agent-more-chats")
    end

    test "the button and the list speak the user's language", ctx do
      view = dock(ctx, locale: "et")
      assert has_element?(view, "#pk-agent-dock-button[aria-label='AI-assistent']")
      assert has_element?(view, "#pk-agent-new-chat", "Uus vestlus")
      assert has_element?(view, "#pk-agent-chats", "Vestlusi veel pole.")

      view = dock(ctx, locale: "uk")
      assert has_element?(view, "#pk-agent-new-chat", "Новий чат")
    end

    test "New chat writes nothing until the first message, which makes the chat", ctx do
      old = conversation_fixture(ctx.user, %{title: "Old one"})
      view = dock(ctx)
      open_chat(view, old)

      view |> element("#pk-agent-new-chat") |> render_click()

      assert [%Conversation{title: "Old one"}] = chats_of(ctx.user)
      refute has_element?(view, "#pk-agent-panel[data-conversation]")
      assert subscriptions(view) == []

      answer_next(text_answer("Hello."))
      send_text(view, "A fresh question")
      assert await_turn(view) =~ "Hello."

      assert [new] = Enum.filter(chats_of(ctx.user), &(&1.uuid != old.uuid))
      assert hd(chat_ids(render(view))) == "pk-agent-chat-#{new.uuid}"
      assert has_element?(view, "#pk-agent-panel[data-conversation='#{new.uuid}']")
    end

    test "the title of a new chat and the order of the list follow its messages", ctx do
      older = conversation_fixture(ctx.user, %{title: "Older"})
      older |> Ecto.Changeset.change(last_message_at: at(600)) |> Repo.update!()
      newer = conversation_fixture(ctx.user, %{title: "Newer"})
      newer |> Ecto.Changeset.change(last_message_at: at(60)) |> Repo.update!()

      view = dock(ctx)

      assert chat_ids(render(view)) == [
               "pk-agent-chat-#{newer.uuid}",
               "pk-agent-chat-#{older.uuid}"
             ]

      open_chat(view, older)
      answer_next(text_answer("Fine."))
      send_text(view, "Back to this one")
      assert await_turn(view) =~ "Fine."

      assert chat_ids(render(view)) == [
               "pk-agent-chat-#{older.uuid}",
               "pk-agent-chat-#{newer.uuid}"
             ]

      view |> element("#pk-agent-new-chat") |> render_click()
      answer_next(text_answer("Sure."))
      send_text(view, "Name me by this")
      assert await_turn(view) =~ "Sure."

      assert has_element?(view, "#pk-agent-panel h2", "Name me by this")
      [top | _] = chat_ids(render(view))
      assert has_element?(view, "##{top}", "Name me by this")
    end

    test "the times of the list are in the user's language", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Two days"})
      chat |> Ecto.Changeset.change(last_message_at: at(2 * 86_400 + 60)) |> Repo.update!()

      view = dock(ctx, locale: "et")
      assert has_element?(view, "#pk-agent-chat-time-#{chat.uuid}", "2 päeva tagasi")
    end

    # Core's time_ago carries the TimeAgo hook, which rewrites the text in English in
    # the browser, and prints its tooltip as an English date: the list's time is the
    # module's own, rendered by the server only.
    test "the time of a chat is the server's text, with the moment in the site's time zone",
         ctx do
      {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", "Europe/Tallinn")
      chat = conversation_fixture(ctx.user, %{title: "When"})
      moment = at(5 * 86_400 + 60)
      chat |> Ecto.Changeset.change(last_message_at: moment) |> Repo.update!()

      view = dock(ctx, locale: "ru")
      selector = "#pk-agent-chat-time-#{chat.uuid}"

      tallinn =
        moment
        |> DateTime.shift_zone!("Europe/Tallinn", Tz.TimeZoneDatabase)
        |> Calendar.strftime("%Y-%m-%d %H:%M")

      ago =
        Gettext.with_locale(PhoenixKitAgent.Gettext, "ru", fn ->
          Gettext.ngettext(PhoenixKitAgent.Gettext, "%{count} day ago", "%{count} days ago", 5)
        end)

      refute has_element?(view, "#{selector}[phx-hook]")
      assert has_element?(view, "#{selector}[title='#{tallinn}']")
      assert has_element?(view, selector, ago)
    end

    test "renames and archives the user's own chat", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Before"})
      view = dock(ctx)

      view |> element("#pk-agent-rename-#{chat.uuid}") |> render_click()

      view
      |> form("#pk-agent-rename-form-#{chat.uuid}", %{"title" => "After"})
      |> render_submit()

      assert Repo.get!(Conversation, chat.uuid).title == "After"
      assert has_element?(view, "#pk-agent-chat-#{chat.uuid}", "After")

      view |> element("#pk-agent-archive-#{chat.uuid}") |> render_click()
      assert Repo.get!(Conversation, chat.uuid).status == "archived"
      refute has_element?(view, "#pk-agent-chat-#{chat.uuid}")
    end

    test "someone else's chat cannot be opened, renamed or archived", ctx do
      other = user_with(["agent"], "stranger")
      theirs = conversation_fixture(other, %{title: "Their chat"})
      {other_ref, _} = session_fixture(other)

      view = dock(ctx)

      render_click(view, "open_chat", %{"uuid" => theirs.uuid})
      assert has_element?(view, "#pk-agent-dock-error")
      refute has_element?(view, "#pk-agent-panel[data-conversation='#{theirs.uuid}']")

      render_click(view, "rename_chat", %{"uuid" => theirs.uuid, "title" => "Mine now"})
      render_click(view, "archive_chat", %{"uuid" => theirs.uuid})

      assert %Conversation{title: "Their chat", status: "active"} =
               Repo.get!(Conversation, theirs.uuid)

      # Not subscribed: their new message does not reach this panel.
      {:ok, _} =
        Conversations.add_message(other_ref, theirs.uuid, %{content: "Private words"},
          impersonated: false
        )

      refute render(view) =~ "Private words"
    end
  end

  # ── the button, the list and the panel in the browser ──────────────

  describe "the browser:" do
    test "the list opens from a focusable element that is not a <button> (Safari)", ctx do
      view = dock(ctx)

      assert has_element?(view, "div#pk-agent-dock-button[role=button][tabindex='0']")
      refute has_element?(view, "button#pk-agent-dock-button")
      assert view |> element("#pk-agent-dock-button") |> render_click() =~ "pk-agent-new-chat"
    end

    test "choosing a chat or New chat takes the focus out of the list", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Focus"})
      view = dock(ctx)

      assert ["focus", %{"to" => "#pk-agent-input"}] in click_ops(view, "#pk-agent-new-chat")

      assert ["focus", %{"to" => "#pk-agent-panel"}] in click_ops(
               view,
               "#pk-agent-chat-#{chat.uuid} [data-role=open]"
             )

      assert has_element?(view, "#pk-agent-panel[tabindex='-1']")
    end

    test "the draft goes to the server only when the field is left", ctx do
      view = dock(ctx)
      assert has_element?(view, "#pk-agent-input[phx-debounce=blur]")
    end

    test "the browser's memory is pushed on mount and again after a reconnect", ctx do
      script = ctx |> dock() |> hook_script(".DockState")

      assert script =~ ~r/mounted\(\)\s*\{[^`]*this\.restore\(\)\s*\},\s*updated\(\)/
      assert script =~ ~r/reconnected\(\)\s*\{\s*this\.apply\(\)\s*this\.restore\(\)/
      assert script =~ ~r/restore\(\)\s*\{[^}]*pushEvent\("restore"/
    end

    test "restore opens the user's own chat and remembers it, once", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Remembered"})
      uuid = chat.uuid
      view = dock(ctx)

      render_hook(view, "restore", %{"open" => true, "conversation_uuid" => uuid})
      assert has_element?(view, "#pk-agent-panel[data-conversation='#{uuid}']")
      assert_push_event(view, "pk-agent:store", %{open: true, conversation_uuid: ^uuid})

      # A second restore (a reconnect) neither doubles the subscription nor the feed.
      turn_message!(chat, %{role: "notice", content: "Only once."})
      render_hook(view, "restore", %{"open" => true, "conversation_uuid" => uuid})

      assert subscriptions(view) == [Conversations.topic(uuid)]

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#pk-agent-feed [data-role=notice]")
             |> Enum.count() == 1
    end

    test "a chat of another user, an archived one or a malformed uuid is forgotten", ctx do
      other = user_with(["agent"], "stranger")
      theirs = conversation_fixture(other, %{title: "Their chat"})
      archived = conversation_fixture(ctx.user, %{title: "Put away"})
      {:ok, _} = Conversations.archive_conversation(ctx.ref, archived.uuid, impersonated: false)

      view = dock(ctx)

      for uuid <- [theirs.uuid, archived.uuid, "not-a-uuid"] do
        render_hook(view, "restore", %{"open" => true, "conversation_uuid" => uuid})

        assert_push_event(view, "pk-agent:store", %{open: true, conversation_uuid: nil})
        refute has_element?(view, "#pk-agent-panel[data-conversation]")
        refute has_element?(view, "#pk-agent-dock-error")
        assert subscriptions(view) == []
      end

      refute render(view) =~ "Their chat"
    end

    test "a panel remembered as closed reads nothing until a chat is opened", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Closed"})
      lost = UUIDv7.generate()
      since = at(Config.turn_deadline_s() + 120)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [busy_since: since, busy_turn_ref: lost]
      )

      view = dock(ctx)
      render_hook(view, "restore", %{"open" => false, "conversation_uuid" => chat.uuid})

      refute has_element?(view, "#pk-agent-panel[data-conversation]")
      assert subscriptions(view) == []
      assert messages(chat) == []
      assert {_since, ^lost} = lock_of(chat)

      open_chat(view, chat)
      assert [%Message{role: "notice", error: "interrupted"}] = messages(chat)
    end

    test "closing the panel and New chat are remembered", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Kept in mind"})
      uuid = chat.uuid
      view = dock(ctx)

      open_chat(view, chat)
      assert_push_event(view, "pk-agent:store", %{open: true, conversation_uuid: ^uuid})

      view |> element("#pk-agent-close") |> render_click()
      assert_push_event(view, "pk-agent:store", %{open: false, conversation_uuid: ^uuid})

      view |> element("#pk-agent-new-chat") |> render_click()
      assert_push_event(view, "pk-agent:store", %{open: true, conversation_uuid: nil})
    end
  end

  # ── a turn in the panel ─────────────────────────────────────────────

  describe "sending:" do
    setup ctx do
      %{chat: conversation_fixture(ctx.user, %{title: "Work"})}
    end

    test "starts a turn and the feed follows it over PubSub", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)
      listen(ctx, ctx.chat)

      answer_next(
        text_answer(
          "Here **it is**. ![chart](http://evil.example/leak?d=1) See [docs](https://docs.example.org/x)."
        )
      )

      send_text(view, "What is new?")

      html = await_turn(view)
      assert html =~ "it is"

      assert_received {:model_request, body}
      system = body["messages"] |> hd() |> Map.fetch!("content")
      assert system =~ "/en/admin/orders/7"

      assert has_element?(view, "#pk-agent-feed [data-role=user]", "What is new?")
      assert has_element?(view, "#pk-agent-feed [data-role=assistant] strong", "it is")

      doc = LazyHTML.from_fragment(html)
      assert doc |> LazyHTML.query("#pk-agent-feed img") |> Enum.count() == 0
      refute html =~ "evil.example"

      [link] = doc |> LazyHTML.query("#pk-agent-feed a[href^='https://docs']") |> Enum.to_list()
      assert LazyHTML.attribute(link, "rel") == ["noopener noreferrer nofollow"]
      assert has_element?(view, "#pk-agent-feed [data-link-domain]", "docs.example.org")

      refute await_turn_end(view, ctx.chat) =~ "pk-agent-waiting"
      assert [%Message{role: "user"}, %Message{role: "assistant"}] = messages(ctx.chat)
    end

    test "the input is left to the browser, so a re-render never wipes a draft", ctx do
      view = dock(ctx)
      assert has_element?(view, "#pk-agent-input[phx-update=ignore]")
    end

    test "a message without an open chat makes one", ctx do
      view = dock(ctx)
      answer_next(text_answer("Hi"))

      send_text(view, "Start somewhere")
      assert await_turn(view) =~ "Start somewhere"

      assert Enum.any?(chats_of(ctx.user), &(&1.title == "Start somewhere"))
    end

    test "a blank message is refused before anything is made", ctx do
      view = dock(ctx)
      before = length(chats_of(ctx.user))

      send_text(view, "   ")

      assert has_element?(view, "#pk-agent-dock-error")
      assert length(chats_of(ctx.user)) == before
    end

    test "a tool call shows as a folded card with its summary, never the result", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      answer_next(
        tool_answer([
          %{
            "id" => "c1",
            "type" => "function",
            "function" => %{"name" => "agenttest_list_items", "arguments" => "{}"}
          }
        ])
      )

      answer_next(text_answer("Three things."))

      send_text(view, "List them")
      html = await_turn(view)
      assert html =~ "Three things."

      assert has_element?(view, "#pk-agent-feed [data-role=tool]", "agenttest.list_items")
      assert has_element?(view, "#pk-agent-feed [data-role=tool]", "3")

      feed =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#pk-agent-feed") |> LazyHTML.to_html()

      for item <- ["chair", "table", "lamp"], do: refute(feed =~ item)
    end

    test "a refused start says why in words", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: "someone-else"]
      )

      send_text(view, "Now?")
      assert has_element?(view, "#pk-agent-dock-error")
      refute render(view) =~ "conversation_busy"
      # The turn that holds the chat is shown, so the Stop the text speaks of is there.
      assert has_element?(view, "#pk-agent-stop")
      assert has_element?(view, "#pk-agent-waiting")
      # A chat that was there before stays, refused or not.
      assert Repo.get!(Conversation, ctx.chat.uuid).status == "active"
    end

    test "a refused first message leaves no chat behind", ctx do
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", "")
      view = dock(ctx)

      send_text(view, "Hello there")

      assert has_element?(view, "#pk-agent-dock-error", "No model is chosen")
      # It says where the model is chosen.
      assert has_element?(view, "#pk-agent-dock-error", "Settings → AI Agent")
      refute has_element?(view, "#pk-agent-panel[data-conversation]")
      assert chat_ids(render(view)) == [ctx.chat.uuid] |> Enum.map(&"pk-agent-chat-#{&1}")

      assert [%Conversation{uuid: kept}] =
               Enum.reject(chats_of(ctx.user), &(&1.status == "deleted"))

      assert kept == ctx.chat.uuid

      # The text is still the browser's: nothing told it to clear the field.
      refute_push_event(view, "pk-agent:sent", %{})
    end

    test "a first message too long for the model leaves no chat behind", ctx do
      view = dock(ctx)

      send_text(view, String.duplicate("x", Config.history_chars() + 1))

      assert has_element?(view, "#pk-agent-dock-error", "too long")

      assert [%Conversation{uuid: kept}] =
               Enum.reject(chats_of(ctx.user), &(&1.status == "deleted"))

      assert kept == ctx.chat.uuid
    end

    test "a send after a turn whose end was never heard goes through", ctx do
      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: UUIDv7.generate()]
      )

      view = dock(ctx)
      open_chat(view, ctx.chat)
      assert has_element?(view, "#pk-agent-stop")

      # The turn ended, but its broadcast never reached this panel.
      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: nil, busy_turn_ref: nil]
      )

      answer_next(text_answer("Through."))
      send_text(view, "Again")

      refute has_element?(view, "#pk-agent-dock-error")
      assert await_turn(view) =~ "Through."
      assert [%Message{role: "user", content: "Again"} | _] = messages(ctx.chat)
    end

    test "an exception in an event is a notice; nothing of the event is logged", ctx do
      secret = "Secret-#{System.unique_integer([:positive])}"
      view = dock(ctx)
      monitor = Process.monitor(view.pid)

      # Every new chat is refused by the database: the insert raises.
      Repo.query!(
        "ALTER TABLE phoenix_kit_agent_conversations ADD CONSTRAINT pk_agent_probe CHECK (false) NOT VALID"
      )

      {_, logs} = LogProbe.capture(fn -> send_text(view, "Ask-" <> secret) end)

      assert has_element?(view, "#pk-agent-dock-error")
      refute_received {:DOWN, ^monitor, :process, _, _}
      assert Enum.any?(logs, &(&1 =~ "ConstraintError"))
      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)
    end

    test "a second send while the turn runs is let go without a word", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)
      hang_next()

      send_text(view, "First")
      assert_receive {:model_waiting, _}, 3_000

      send_text(view, "Second")

      refute has_element?(view, "#pk-agent-dock-error")
      assert [%Message{role: "user", content: "First"}] = messages(ctx.chat)
    end

    test "a page that is not a path of the site never reaches the model", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)
      answer_next(text_answer("Ok."))

      send_text(view, "Where am I?", "https://evil.example/phish")
      assert await_turn(view) =~ "Ok."

      assert_received {:model_request, body}
      refute Jason.encode!(body) =~ "evil.example"
    end

    test "the tools get the language and the address of the site as their context", ctx do
      Application.put_env(:phoenix_kit_agent, :test_tool_listener, self())
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :test_tool_listener) end)

      view = dock(ctx, locale: "et")
      open_chat(view, ctx.chat)

      answer_next(
        tool_answer([
          %{
            "id" => "c1",
            "type" => "function",
            "function" => %{"name" => "agenttest_list_items", "arguments" => "{}"}
          }
        ])
      )

      answer_next(text_answer("Done."))
      send_text(view, "List them")

      assert_receive {:agent_test_tool, "agenttest.list_items", _input, tool_ctx}, 3_000
      assert tool_ctx.language == "et"
      assert tool_ctx.base_url == Endpoint.url()
      assert await_turn(view) =~ "Done."
    end

    test "a send while a file is still read waits for it, and makes no turn", ctx do
      Repo.insert!(%Attachment{
        conversation_uuid: ctx.chat.uuid,
        user_uuid: ctx.user.uuid,
        filename: "slow.pdf",
        content_type: "application/pdf",
        size_bytes: 10,
        kind: "pdf",
        status: "pending",
        truncated: false
      })

      view = dock(ctx)
      open_chat(view, ctx.chat)

      send_text(view, "Read it")

      assert has_element?(view, "#pk-agent-dock-error", "Wait until the files are read.")
      assert messages(ctx.chat) == []
      assert lock_of(ctx.chat) == {nil, nil}
    end

    test "a send while a file is still uploading waits for it", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      view
      |> file_input("#pk-agent-composer", :files, [
        %{name: "half.txt", content: String.duplicate("a", 4_000), type: "text/plain"}
      ])
      |> render_upload("half.txt", 50)

      send_text(view, "Now")

      assert has_element?(view, "#pk-agent-dock-error", "Wait until the files are read.")
      assert messages(ctx.chat) == []
    end

    test "an exception at the start does not take the panel down", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      # The monitor's handshake time is read as the turn starts.
      Application.put_env(:phoenix_kit_agent, :turn_handshake_ms, :not_a_number)

      monitor = Process.monitor(view.pid)
      send_text(view, "Break it")

      assert has_element?(view, "#pk-agent-dock-error")
      refute_received {:DOWN, ^monitor, :process, _, _}
      assert lock_of(ctx.chat) == {nil, nil}
      refute render(view) =~ "ArithmeticError"
    end

    test "Stop ends the turn and the indicator goes away", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)
      listen(ctx, ctx.chat)
      hang_next()

      send_text(view, "Take your time")
      assert_receive {:model_waiting, _}, 3_000
      assert has_element?(view, "#pk-agent-waiting")

      view |> element("#pk-agent-stop") |> render_click()

      refute await_turn_end(view, ctx.chat) =~ "pk-agent-waiting"
      assert lock_of(ctx.chat) == {nil, nil}
      refute Enum.any?(messages(ctx.chat), &(&1.role == "assistant"))
    end

    test "nothing of the conversation reaches the log", ctx do
      secret = "Secret-#{System.unique_integer([:positive])}"
      answer_next(text_answer("Answer-" <> secret))

      {_, logs} =
        LogProbe.capture(fn ->
          view = dock(ctx)
          open_chat(view, ctx.chat)

          name = "File-#{secret}.txt"

          view
          |> file_input("#pk-agent-composer", :files, [
            %{name: name, content: "Body-" <> secret, type: "text/plain"}
          ])
          |> render_upload(name)

          assert await_files(view) =~ ~s(data-status="ready")
          send_text(view, "Ask-" <> secret)
          assert await_turn(view) =~ "Answer-" <> secret
        end)

      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)
    end
  end

  # ── a turn lost with its node ──────────────────────────────────────

  describe "opening a chat locked by a lost turn" do
    test "writes the notice that the answer was interrupted and frees the chat", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Lost"})
      lost = UUIDv7.generate()
      since = at(Config.turn_deadline_s() + 120)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [busy_since: since, busy_turn_ref: lost]
      )

      Repo.insert!(%UserSettings{
        user_uuid: ctx.user.uuid,
        busy_since: since,
        busy_turn_ref: lost
      })

      view = dock(ctx)
      open_chat(view, chat)

      assert has_element?(view, "#pk-agent-feed [data-role=notice]", "interrupted")
      assert lock_of(chat) == {nil, nil}
      assert [%Message{role: "notice", error: "interrupted"}] = messages(chat)
    end

    test "a turn still within its time is shown as running, nothing written", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Busy"})

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: UUIDv7.generate()]
      )

      view = dock(ctx)
      open_chat(view, chat)

      assert has_element?(view, "#pk-agent-waiting")
      assert messages(chat) == []
    end

    test "Stop on a turn within its time that runs not here asks the other nodes", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Elsewhere"})
      elsewhere = UUIDv7.generate()

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: elsewhere]
      )

      :ok = PubSub.subscribe("agent:turn:" <> elsewhere)

      view = dock(ctx)
      open_chat(view, chat)
      view |> element("#pk-agent-stop") |> render_click()

      assert_receive {:agent_stop_turn, ^elsewhere}, 1_000
      assert has_element?(view, "#pk-agent-waiting[data-activity=stopping]")
      refute has_element?(view, "#pk-agent-dock-error")
    end

    test "a Stop no node answers gives Stop back after the grace period; " <>
           "pressed again, it asks again",
         ctx do
      chat = conversation_fixture(ctx.user, %{title: "Unanswered"})
      elsewhere = UUIDv7.generate()

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: elsewhere]
      )

      :ok = PubSub.subscribe("agent:turn:" <> elsewhere)

      view = dock(ctx)
      open_chat(view, chat)
      pid = view.pid
      :erlang.trace(pid, true, [:receive])

      view |> element("#pk-agent-stop") |> render_click()
      assert_receive {:agent_stop_turn, ^elsewhere}, 1_000
      assert has_element?(view, "#pk-agent-stop[disabled]")

      assert_receive {:trace, ^pid, :receive, {:pk_agent_stop_unanswered, ^elsewhere}},
                     Monitor.stop_grace_ms() + 10_000

      assert has_element?(view, "#pk-agent-dock-error", "has not stopped")
      assert has_element?(view, "#pk-agent-waiting")
      refute has_element?(view, "#pk-agent-stop[disabled]")

      view |> element("#pk-agent-stop") |> render_click()
      assert_receive {:agent_stop_turn, ^elsewhere}, 1_000
      assert has_element?(view, "#pk-agent-waiting[data-activity=stopping]")
      assert lock_of(chat) |> elem(1) == elsewhere
    end

    test "a Stop whose turn ends in time leaves no complaint behind", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Answered"})
      listen(ctx, chat)
      hang_next()

      view = dock(ctx)
      open_chat(view, chat)
      send_text(view, "Hi")
      assert_receive {:model_waiting, _}, 3_000
      {_since, turn_ref} = lock_of(chat)
      pid = view.pid
      :erlang.trace(pid, true, [:receive])

      view |> element("#pk-agent-stop") |> render_click()
      await_turn_end(view, chat)

      assert_receive {:trace, ^pid, :receive, {:pk_agent_stop_unanswered, ^turn_ref}},
                     Monitor.stop_grace_ms() + 10_000

      refute has_element?(view, "#pk-agent-dock-error")
      refute has_element?(view, "#pk-agent-waiting")
    end

    test "Stop while the monitor restarts says the answer is no longer running here", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Restarting"})
      listen(ctx, chat)
      hang_next()

      view = dock(ctx)
      open_chat(view, chat)
      send_text(view, "Hi")
      assert_receive {:model_waiting, _}, 3_000
      {_since, turn_ref} = lock_of(chat)

      name = PhoenixKitAgent.Turns.Monitor
      monitor = Process.whereis(name)
      true = Process.unregister(name)

      on_exit(fn ->
        if Process.alive?(monitor) and Process.whereis(name) == nil,
          do: Process.register(monitor, name)
      end)

      view |> element("#pk-agent-stop") |> render_click()
      true = Process.register(monitor, name)

      assert has_element?(view, "#pk-agent-dock-error", "no longer running here")
      refute has_element?(view, "#pk-agent-stop")
      assert lock_of(chat) |> elem(1) == turn_ref

      :ok = Turns.stop(ctx.ref, false, chat.uuid, turn_ref)
      await_turn_end(view, chat)
    end

    test "Stop on a turn whose lock has expired since the chat was opened frees it", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Gone"})
      gone = UUIDv7.generate()

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: gone]
      )

      :ok = PubSub.subscribe("agent:turn:" <> gone)

      view = dock(ctx)
      open_chat(view, chat)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [busy_since: at(Config.turn_deadline_s() + 120)]
      )

      view |> element("#pk-agent-stop") |> render_click()

      refute_received {:agent_stop_turn, _}
      refute has_element?(view, "#pk-agent-stop")
      refute has_element?(view, "#pk-agent-waiting")
      assert has_element?(view, "#pk-agent-feed [data-role=notice]", "interrupted")
      assert lock_of(chat) == {nil, nil}
    end
  end

  # ── a connection lost and found again ──────────────────────────────

  describe "the panel after a reconnect" do
    setup ctx do
      Application.put_env(:phoenix_kit_agent, :turn_check_ms, 30)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :turn_check_ms) end)
      %{chat: conversation_fixture(ctx.user, %{title: "Work"})}
    end

    # The next model call waits for `:go` before it answers with `answer`.
    defp gate_next(answer) do
      test = self()

      Req.Test.expect(@stub, fn conn ->
        send(test, {:model_gate, self()})

        receive do
          :go -> Req.Test.json(conn, answer)
        end
      end)
    end

    # The panel's own checks of the turn it shows, until it lets the turn go.
    defp await_let_go(view, tries \\ 50)
    defp await_let_go(_view, 0), do: flunk("the panel kept showing the turn")

    defp await_let_go(view, tries) do
      pid = view.pid
      assert_receive {:trace, ^pid, :receive, :pk_agent_check_turn}, 2_000
      _ = render(view)
      if has_element?(view, "#pk-agent-waiting"), do: await_let_go(view, tries - 1), else: :ok
    end

    test "a turn that ended before the panel mounted again is not shown as running", ctx do
      first = dock(ctx)
      open_chat(first, ctx.chat)
      listen(ctx, ctx.chat)
      gate_next(text_answer("Finished meanwhile."))

      send_text(first, "A long one")
      assert_receive {:model_gate, model}, 3_000
      assert has_element?(first, "#pk-agent-stop")

      # The connection is lost; the turn ends while there is none.
      send(model, :go)
      uuid = ctx.chat.uuid
      assert_receive {:agent_turn_finished, ^uuid, _turn_ref}, 5_000

      # The browser joins again: a fresh panel, restored from its memory.
      second = dock(ctx)
      render_hook(second, "restore", %{"open" => true, "conversation_uuid" => uuid})

      refute has_element?(second, "#pk-agent-waiting")
      refute has_element?(second, "#pk-agent-stop")
      assert has_element?(second, "#pk-agent-feed [data-role=assistant]", "Finished meanwhile.")
    end

    test "a turn whose end the panel did not hear after it mounted again is let go of", ctx do
      lost = UUIDv7.generate()

      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: lost]
      )

      view = dock(ctx)
      :erlang.trace(view.pid, true, [:receive])
      render_hook(view, "restore", %{"open" => true, "conversation_uuid" => ctx.chat.uuid})
      assert has_element?(view, "#pk-agent-waiting")
      assert has_element?(view, "#pk-agent-stop")

      # The turn answers and ends, but neither its answer nor its end reaches
      # the panel (they came between its read of the chat and its listening,
      # or were lost on the way).
      Repo.insert!(%Message{
        conversation_uuid: ctx.chat.uuid,
        turn_ref: lost,
        role: "assistant",
        content: "Answered unheard."
      })

      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: nil, busy_turn_ref: nil]
      )

      :ok = await_let_go(view)

      refute has_element?(view, "#pk-agent-stop")
      assert has_element?(view, "#pk-agent-feed [data-role=assistant]", "Answered unheard.")

      # Nothing more to check once the turn is let go of.
      pid = view.pid
      refute_receive {:trace, ^pid, :receive, :pk_agent_check_turn}, 200
    end

    test "every restore patches the panel, so nothing the browser kept from before stays", ctx do
      view = dock(ctx)
      uuid = ctx.chat.uuid

      render_hook(view, "restore", %{"open" => true, "conversation_uuid" => uuid})
      assert has_element?(view, "#pk-agent-panel[data-restored='1']")

      # The same state again: still a change for the browser to apply.
      render_hook(view, "restore", %{"open" => true, "conversation_uuid" => uuid})
      assert has_element?(view, "#pk-agent-panel[data-restored='2']")
    end

    test "the feed scroller carries the chat and the restore count the hook pins on", ctx do
      view = dock(ctx)
      uuid = ctx.chat.uuid

      render_hook(view, "restore", %{"open" => true, "conversation_uuid" => uuid})

      assert has_element?(
               view,
               "#pk-agent-feed-scroll[data-conversation='#{uuid}'][data-restored='1']"
             )

      assert has_element?(view, "#pk-agent-feed-scroll > #pk-agent-feed-content #pk-agent-feed")
    end

    test "the hooks keep the open state across navigations and pin the feed after them", ctx do
      view = dock(ctx)
      state = hook_script(view, ".DockState")
      feed = hook_script(view, ".Feed")

      assert state =~ "phx:page-loading-stop"
      assert state =~ ~s|classList.add("pk-dock-open")|
      refute state =~ ~s|classList.remove("pk-dock-open")|
      assert feed =~ "phx:page-loading-stop"
      assert feed =~ "phx:page-loading-start"
      assert feed =~ "resizer.observe(this.el.firstElementChild)"
    end

    test "the indicator's own timeout starts again after a reconnect and for each turn", ctx do
      view = dock(ctx)
      script = hook_script(view, ".Waiting")

      assert script =~ ~r/reconnected\(\)\s*\{\s*this\.arm\(\)/

      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: "turn-1"]
      )

      open_chat(view, ctx.chat)
      assert has_element?(view, "#pk-agent-waiting[data-turn='turn-1']")
    end
  end

  # ── attachments ────────────────────────────────────────────────────

  describe "attachments:" do
    setup ctx do
      %{chat: conversation_fixture(ctx.user, %{title: "Files"})}
    end

    defp upload(view, name, content, type) do
      input =
        file_input(view, "#pk-agent-composer", :files, [
          %{name: name, content: content, type: type}
        ])

      render_upload(input, name)
    end

    defp attachments_of(chat) do
      Repo.all(from(a in Attachment, where: a.conversation_uuid == ^chat.uuid))
    end

    defp upload_refs(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pk-agent-attachments li[id^=pk-agent-upload-]")
      |> Enum.map(fn node ->
        node |> LazyHTML.attribute("id") |> hd() |> String.replace_prefix("pk-agent-upload-", "")
      end)
    end

    test "a file is added to the open chat, read, and goes with the message", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      upload(view, "notes.txt", "Shelf height 2.1 m", "text/plain")

      assert await_files(view) =~ ~s(data-status="ready")

      assert [%Attachment{filename: "notes.txt", status: "ready"} = att] =
               attachments_of(ctx.chat)

      assert has_element?(view, "#pk-agent-att-#{att.uuid}", "notes.txt")

      answer_next(text_answer("Noted."))
      send_text(view, "Read the file")
      assert await_turn(view) =~ "Noted."

      assert_received {:model_request, body}
      assert Jason.encode!(body) =~ "Shelf height 2.1 m"
      assert Repo.get!(Attachment, att.uuid).message_uuid
    end

    test "a refused file is explained in words and keeps no row", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      upload(view, "table.csv", <<0xFF, 0xFE, ?a, 0, ?b, 0>>, "text/csv")

      html = render_async(view)
      assert html =~ "pk-agent-dock-error"
      assert html =~ "UTF-8"
      refute html =~ "unsupported_encoding"
      assert attachments_of(ctx.chat) == []
    end

    test "a picture of an unlisted image type is taken in by the image/* wildcard", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      upload(view, "IMG_20261029_101500", Files.jpeg(64, 48), "image/x-camera-raw")

      # Accepted by LiveView: what stops it is the content check, not the list.
      assert await_files(view) =~ "no model that sees images"
      refute render(view) =~ "pk-agent-upload-error"
    end

    test "a file LiveView refuses is shown and logged by its class only", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      {result, logs} =
        LogProbe.capture(fn ->
          input =
            file_input(view, "#pk-agent-composer", :files, [
              %{name: "SecretName.exe", content: "MZ", type: "application/octet-stream"}
            ])

          result = render_upload(input, "SecretName.exe")
          assert render(view) =~ "text-error"
          # The browser's change event that follows a file pick.
          view |> form("#pk-agent-composer") |> render_change()
          result
        end)

      assert {:error, [[_ref, :not_accepted]]} = result
      assert Enum.any?(logs, &(&1 =~ "[PhoenixKitAgent] an upload was refused: :not_accepted"))
      refute Enum.any?(logs, &(&1 =~ "SecretName"))
      assert attachments_of(ctx.chat) == []
    end

    test "a cancel of an upload that is not there changes nothing", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)
      monitor = Process.monitor(view.pid)

      input =
        file_input(view, "#pk-agent-composer", :files, [
          %{name: "half.txt", content: String.duplicate("a", 4_000), type: "text/plain"}
        ])

      render_upload(input, "half.txt", 50)
      [entry_ref] = view |> render() |> upload_refs()

      render_click(view, "cancel_upload", %{"ref" => "nope"})
      render_click(view, "cancel_upload", %{"ref" => entry_ref})
      render_click(view, "cancel_upload", %{"ref" => entry_ref})

      refute has_element?(view, "#pk-agent-upload-#{entry_ref}")
      refute_received {:DOWN, ^monitor, :process, _, _}
      assert attachments_of(ctx.chat) == []
    end

    test "an exception while a file is added is a notice; nothing of it is logged", ctx do
      secret = "Secret-#{System.unique_integer([:positive])}"
      view = dock(ctx)
      open_chat(view, ctx.chat)
      monitor = Process.monitor(view.pid)

      # The bounds are read as the file is added: a malformed override raises there.
      Application.put_env(:phoenix_kit_agent, :attachment_limits, secret)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :attachment_limits) end)

      {_, logs} =
        LogProbe.capture(fn ->
          upload(view, "File-#{secret}.txt", "text", "text/plain")
          assert render_async(view) =~ "pk-agent-dock-error"
        end)

      refute_received {:DOWN, ^monitor, :process, _, _}
      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)
      refute Enum.any?(logs, &(&1 =~ "FunctionClauseError" and &1 =~ "Keyword"))
    end

    test "a file that is added after its chat was left stays with its chat", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      release = hold_the_database()
      upload(view, "late.txt", "Late words", "text/plain")
      # The panel moves on while `Attachments.add/4` waits for the database.
      view |> element("#pk-agent-new-chat") |> render_click()
      release.()
      render_async(view)

      refute has_element?(view, "#pk-agent-attachments")

      assert [%Attachment{filename: "late.txt", message_uuid: nil} = att] =
               attachments_of(ctx.chat)

      open_chat(view, ctx.chat)
      assert has_element?(view, "#pk-agent-att-#{att.uuid}")
    end

    test "a cancel of an upload that is with Attachments.add/4 already changes nothing", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      release = hold_the_database()
      upload(view, "kept.txt", "Kept words", "text/plain")
      [entry_ref] = view |> render() |> upload_refs()

      render_click(view, "cancel_upload", %{"ref" => entry_ref})
      assert has_element?(view, "#pk-agent-upload-#{entry_ref}")

      release.()
      render_async(view)
      assert await_files(view) =~ ~s(data-status="ready")
      assert [%Attachment{filename: "kept.txt", status: "ready"}] = attachments_of(ctx.chat)
    end

    test "a file for which no chat can be made is dropped from the uploads", ctx do
      view = dock(ctx)
      :ok = Permissions.revoke_permission(ctx.role.uuid, "agent")

      upload(view, "orphan.txt", "No home", "text/plain")

      assert has_element?(view, "#pk-agent-dock-error")
      assert view |> render() |> upload_refs() == []
      assert [%Conversation{uuid: uuid}] = chats_of(ctx.user)
      assert uuid == ctx.chat.uuid
    end

    test "a refused file leaves no chat behind when it was the one to make it", ctx do
      view = dock(ctx)

      upload(view, "table.csv", <<0xFF, 0xFE, ?a, 0, ?b, 0>>, "text/csv")
      render_async(view)

      assert has_element?(view, "#pk-agent-dock-error", "UTF-8")
      refute has_element?(view, "#pk-agent-panel[data-conversation]")

      assert [%Conversation{uuid: kept}] =
               Enum.reject(chats_of(ctx.user), &(&1.status == "deleted"))

      assert kept == ctx.chat.uuid
    end

    test "a failed file is shown with its reason and can be discarded", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      failed =
        Repo.insert!(%Attachment{
          conversation_uuid: ctx.chat.uuid,
          user_uuid: ctx.user.uuid,
          filename: "broken.pdf",
          content_type: "application/pdf",
          size_bytes: 10,
          kind: "pdf",
          status: "failed",
          error: "pdf_tools_missing",
          truncated: false
        })

      # Reopen: the waiting files are read when a chat is opened.
      open_chat(view, ctx.chat)

      assert has_element?(view, "#pk-agent-att-#{failed.uuid}[data-status=failed]")
      refute render(view) =~ "pdf_tools_missing"

      view |> element("#pk-agent-discard-#{failed.uuid}") |> render_click()
      refute has_element?(view, "#pk-agent-att-#{failed.uuid}")
      assert attachments_of(ctx.chat) == []
    end
  end

  # ── the feed and its chat ──────────────────────────────────────────

  describe "the feed:" do
    setup ctx do
      %{chat: conversation_fixture(ctx.user, %{title: "Here"})}
    end

    defp turn_message!(chat, attrs) do
      {:ok, message} = Conversations.add_turn_message(chat.user_uuid, chat.uuid, attrs)
      message
    end

    test "only the open chat is listened to", ctx do
      other = conversation_fixture(ctx.user, %{title: "There"})
      view = dock(ctx)

      open_chat(view, ctx.chat)
      assert subscriptions(view) == [Conversations.topic(ctx.chat.uuid)]

      open_chat(view, other)
      assert subscriptions(view) == [Conversations.topic(other.uuid)]

      view |> element("#pk-agent-archive-#{other.uuid}") |> render_click()
      assert subscriptions(view) == []
    end

    test "a message of another of the user's chats does not enter the feed", ctx do
      other = conversation_fixture(ctx.user, %{title: "There"})
      view = dock(ctx)
      open_chat(view, ctx.chat)

      elsewhere = turn_message!(other, %{role: "assistant", content: "Words from elsewhere"})
      send(view.pid, {:agent_message_added, other.uuid, elsewhere.uuid})

      refute render(view) =~ "Words from elsewhere"
    end

    test "the end of another turn, or of a turn in another chat, keeps the indicator", ctx do
      other = conversation_fixture(ctx.user, %{title: "There"})
      view = dock(ctx)
      open_chat(view, ctx.chat)
      hang_next()

      send_text(view, "Wait")
      assert_receive {:model_waiting, _}, 3_000
      {_since, turn_ref} = lock_of(ctx.chat)

      send(view.pid, {:agent_turn_finished, ctx.chat.uuid, UUIDv7.generate()})
      send(view.pid, {:agent_turn_finished, other.uuid, turn_ref})

      assert has_element?(view, "#pk-agent-waiting")
      assert has_element?(view, "#pk-agent-stop")
    end

    test "a message committed out of order is still shown", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      shown = turn_message!(ctx.chat, %{role: "assistant", content: "Shown first"})
      send(view.pid, {:agent_message_added, ctx.chat.uuid, shown.uuid})
      assert render(view) =~ "Shown first"

      # Written before the shown one, committed after it.
      late = turn_message!(ctx.chat, %{role: "assistant", content: "Late but here"})

      Repo.update_all(from(m in Message, where: m.uuid == ^late.uuid),
        set: [inserted_at: DateTime.add(shown.inserted_at, -5, :second)]
      )

      send(view.pid, {:agent_message_added, ctx.chat.uuid, late.uuid})
      assert render(view) =~ "Late but here"
    end

    test "the end of a turn shows the files that wait for a message again", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)
      listen(ctx, ctx.chat)

      # A file the panel has not heard of (taken off the message by the turn).
      waiting =
        Repo.insert!(%Attachment{
          conversation_uuid: ctx.chat.uuid,
          user_uuid: ctx.user.uuid,
          filename: "back.txt",
          content_type: "text/plain",
          size_bytes: 4,
          kind: "text",
          status: "ready",
          truncated: false
        })

      answer_next(text_answer("Answered."))
      send_text(view, "Go")
      html = await_turn_end(view, ctx.chat)
      assert html =~ "Answered."
      refute html =~ "pk-agent-waiting"

      assert has_element?(view, "#pk-agent-att-#{waiting.uuid}")
    end

    test "a chat archived elsewhere does not come back to the list with a message", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      {:ok, _} = Conversations.archive_conversation(ctx.ref, ctx.chat.uuid, impersonated: false)
      turn_message!(ctx.chat, %{role: "user", content: "From another tab"})

      assert render(view) =~ "From another tab"
      refute has_element?(view, "#pk-agent-chat-#{ctx.chat.uuid}")
    end

    test "the indicator says Stopping until the stopped turn has ended", ctx do
      Application.put_env(:phoenix_kit_agent, :turn_stop_grace_ms, 10_000)
      on_exit(fn -> Application.put_env(:phoenix_kit_agent, :turn_stop_grace_ms, 200) end)

      view = dock(ctx)
      open_chat(view, ctx.chat)
      hang_next()

      send_text(view, "Slowly")
      assert_receive {:model_waiting, _}, 3_000
      view |> element("#pk-agent-stop") |> render_click()
      assert has_element?(view, "#pk-agent-waiting[data-activity=stopping]")

      # A last message of the turn arrives while it stops.
      turn_message!(ctx.chat, %{role: "user", content: "Late words"})
      assert render(view) =~ "Late words"

      assert has_element?(view, "#pk-agent-waiting[data-activity=stopping]")
    end

    test "a notice is shown in the panel's words for its code", ctx do
      turn_message!(ctx.chat, %{role: "notice", content: "Stored words", error: "interrupted"})
      turn_message!(ctx.chat, %{role: "notice", content: "Words of its own", error: "api_error"})

      view = dock(ctx)
      open_chat(view, ctx.chat)

      assert has_element?(view, "#pk-agent-feed [data-role=notice]", "The answer was interrupted")
      refute render(view) =~ "Stored words"
      assert has_element?(view, "#pk-agent-feed [data-role=notice]", "Words of its own")
    end

    test "transient errors and rejected pictures keep their guidance in the panel's language",
         ctx do
      turn_message!(ctx.chat, %{
        role: "notice",
        content: "The model did not answer. Try again.",
        error: "request_timeout"
      })

      turn_message!(ctx.chat, %{
        role: "notice",
        content:
          "The model did not answer; it may not take the pictures. " <>
            "The files were not sent with the message: you can send them again.",
        error: "api_error"
      })

      view = dock(ctx, locale: "ru")
      open_chat(view, ctx.chat)

      assert has_element?(
               view,
               "#pk-agent-feed [data-role=notice]",
               "Модель не ответила. Попробуйте ещё раз."
             )

      assert has_element?(view, "#pk-agent-feed [data-role=notice]", "Файлы не были отправлены")
      refute render(view) =~ "The model did not answer"
    end

    test "an account out of credit is told in the panel's language, never as a retry", ctx do
      turn_message!(ctx.chat, %{
        role: "notice",
        content: "The model did not answer. Try again.",
        error: "insufficient_credits"
      })

      view = dock(ctx)
      open_chat(view, ctx.chat)
      assert has_element?(view, "#pk-agent-feed [data-role=notice]", "run out of credit")
      refute render(view) =~ "Try again"

      view = dock(ctx, locale: "ru")
      open_chat(view, ctx.chat)
      assert has_element?(view, "#pk-agent-feed [data-role=notice]", "закончились средства")
      refute render(view) =~ "Try again"
    end

    test "an endpoint that cannot be used is told in the panel's language, never as a retry",
         ctx do
      turn_message!(ctx.chat, %{
        role: "notice",
        content: "The model did not answer. Try again.",
        error: "invalid_api_key"
      })

      view = dock(ctx)
      open_chat(view, ctx.chat)

      assert has_element?(
               view,
               "#pk-agent-feed [data-role=notice]",
               "An administrator has to check"
             )

      refute render(view) =~ "Try again"

      view = dock(ctx, locale: "ru")
      open_chat(view, ctx.chat)

      assert has_element?(
               view,
               "#pk-agent-feed [data-role=notice]",
               "Администратору нужно проверить"
             )

      refute render(view) =~ "Try again"
    end

    test "a long chat opens at its end; the earlier messages come on request", ctx do
      for n <- 1..60, do: turn_message!(ctx.chat, %{role: "notice", content: "Note #{n}."})

      view = dock(ctx)
      open_chat(view, ctx.chat)

      notes = fn ->
        render(view)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#pk-agent-feed [data-role=notice]")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.trim/1)
      end

      shown = notes.()
      assert length(shown) < 60
      assert List.last(shown) == "Note 60."
      refute "Note 1." in shown

      view |> element("#pk-agent-earlier") |> render_click()

      assert notes.() == Enum.map(1..60, &"Note #{&1}.")
      refute has_element?(view, "#pk-agent-earlier")
    end
  end

  # ── a session that changes under the panel ─────────────────────────

  describe "a session that ends or loses the right after the mount" do
    setup ctx do
      %{chat: conversation_fixture(ctx.user, %{title: "Kept"})}
    end

    test "a revoked session gets nothing more", ctx do
      view = dock(ctx)
      assert has_element?(view, "#pk-agent-chat-#{ctx.chat.uuid}")

      :ok = Auth.delete_user_session_token(ctx.token)

      open_chat(view, ctx.chat)
      refute has_element?(view, "#pk-agent-panel[data-conversation]")
      assert has_element?(view, "#pk-agent-dock-error")

      send_text(view, "Still there?")
      assert [%Conversation{uuid: uuid}] = chats_of(ctx.user)
      assert uuid == ctx.chat.uuid
      assert messages(ctx.chat) == []
    end

    test "a right taken away refuses the next event", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      :ok = Permissions.revoke_permission(ctx.role.uuid, "agent")

      send_text(view, "May I?")
      assert has_element?(view, "#pk-agent-dock-error")
      assert messages(ctx.chat) == []
    end
  end

  # ── the user's own instructions ────────────────────────────────────

  describe "personal instructions:" do
    test "are read and written for the session's user", ctx do
      view = dock(ctx)
      view |> element("#pk-agent-instructions-toggle") |> render_click()

      view
      |> form("#pk-agent-instructions-form",
        instructions: %{personal_instructions: "Answer in Estonian."}
      )
      |> render_submit()

      assert {:ok, "Answer in Estonian."} =
               UserConfig.get_personal_instructions(ctx.ref, impersonated: false)

      too_long = String.duplicate("x", 5_000)

      view
      |> form("#pk-agent-instructions-form", instructions: %{personal_instructions: too_long})
      |> render_submit()

      assert has_element?(view, "#pk-agent-instructions-form .text-error")

      assert {:ok, "Answer in Estonian."} =
               UserConfig.get_personal_instructions(ctx.ref, impersonated: false)
    end

    test "a forged save whose text is not text changes nothing and takes nothing down", ctx do
      secret = "SecretMap-#{System.unique_integer([:positive])}"
      view = dock(ctx)
      view |> element("#pk-agent-instructions-toggle") |> render_click()

      {_, logs} =
        LogProbe.capture(fn ->
          for forged <- [%{"a" => secret}, [secret], 7, nil] do
            render_hook(view, "save_instructions", %{
              "instructions" => %{"personal_instructions" => forged}
            })

            assert has_element?(view, "#pk-agent-instructions-form")
          end
        end)

      assert Process.alive?(view.pid)
      assert {:ok, nil} = UserConfig.get_personal_instructions(ctx.ref, impersonated: false)
      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)
    end
  end
end
