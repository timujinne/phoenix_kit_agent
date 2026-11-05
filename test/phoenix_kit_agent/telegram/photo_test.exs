defmodule PhoenixKitAgent.Telegram.PhotoTest do
  @moduledoc """
  A picture sent to the bot by a linked chat: added to the person's Telegram
  conversation as the panel's upload is (the same checks, storage and
  processing), waited for, and sent to the model with the caption as one turn.
  The pictures of one album are one turn. The model is a `Req.Test` stub behind
  `phoenix_kit_ai`; the bot is `PhoenixKitAgent.Test.TelegramClient`.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKitAgent.Attachments.{Bounds, Slots}
  alias PhoenixKitAgent.Schemas.{Attachment, Message}
  alias PhoenixKitAgent.Telegram.{Bridge, Limiter, Texts}
  alias PhoenixKitAgent.Test.{Files, LogProbe, TelegramClient, Tools}

  @stub __MODULE__
  @model "a/chat"
  @chat 428_897_538

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)
    _bucket = Files.local_bucket!()

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    Application.put_env(:phoenix_kit_agent, :telegram_album_settle_ms, 100)
    TelegramClient.start()

    end_queues()

    on_exit(fn ->
      stop_all_turns()
      end_queues()
      TelegramClient.stop()
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_agent, :telegram_album_settle_ms)
      Application.delete_env(:phoenix_kit_agent, :telegram_attachment_wait_ms)
      Req.Test.set_req_test_to_private()
    end)

    endpoint = chat_endpoint("yes")
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    user = user_with(["agent", "agent.telegram", "dashboard"], "photo")
    connection = UUIDv7.generate()
    ref = telegram_link_fixture(user, connection, @chat)
    Limiter.clear_unlinked(connection)
    TelegramClient.set(:download, fn _file_id, _opts -> {:ok, Files.png(40, 30)} end)

    %{user: user, connection: connection, ref: ref, endpoint: endpoint}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp chat_endpoint(vision) do
    endpoint_fixture(%{
      model: @model,
      provider_settings: %{"capabilities" => %{"vision" => vision, "model" => @model}}
    })
  end

  # The model answers `text` to every call, and tells the test what it was sent.
  defp model_says(text) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "model" => @model,
        "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}],
        "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}
      })
    end)
  end

  defp images_in(body) do
    body["messages"]
    |> Enum.flat_map(&if(is_list(&1["content"]), do: &1["content"], else: []))
    |> Enum.count(&(&1["type"] == "image_url"))
  end

  defp photo(ctx, opts \\ []) do
    sizes = Keyword.get(opts, :sizes, [{"small-id", 800}, {"big-id", 90_000}])

    extra =
      Map.merge(
        %{"photo" => for({id, size} <- sizes, do: %{"file_id" => id, "file_size" => size})},
        Map.new(Keyword.take(opts, [:caption, :media_group_id]), fn {k, v} ->
          {to_string(k), v}
        end)
      )

    Bridge.dispatch(
      ctx.connection,
      TelegramClient.update(
        @chat,
        nil,
        Keyword.merge([extra: extra], Keyword.take(opts, [:message_id]))
      )
    )
  end

  defp document(ctx, type, opts \\ []) do
    doc = %{
      "file_id" => "doc-id",
      "mime_type" => type,
      "file_name" => "scan.png",
      "file_size" => 5_000
    }

    extra =
      Map.merge(
        %{"document" => doc},
        Map.new(Keyword.take(opts, [:caption]), fn {_key, v} -> {"caption", v} end)
      )

    Bridge.dispatch(ctx.connection, TelegramClient.update(@chat, nil, extra: extra))
  end

  defp calls_until(done, timeout \\ 8_000) do
    receive do
      {:tg, {:typing, _, _}} -> calls_until(done, timeout)
      {:tg, call} -> if done.(call), do: [call], else: [call | calls_until(done, timeout)]
    after
      timeout -> flunk("the bot was not called as expected")
    end
  end

  defp reaction?(emoji), do: &match?({:react, _, _, _, ^emoji}, &1)
  defp texts(calls), do: for({:send_message, _, _, text} <- calls, do: text)
  defp downloads(calls), do: for({:download_file, _, id, _} <- calls, do: id)

  defp user_messages(user) do
    Repo.all(
      from(m in Message,
        join: c in PhoenixKitAgent.Schemas.Conversation,
        on: c.uuid == m.conversation_uuid,
        where: c.user_uuid == ^user.uuid and m.role == "user",
        select: m.content
      )
    )
  end

  defp attachments(user), do: Repo.all(from(a in Attachment, where: a.user_uuid == ^user.uuid))

  # The queues of earlier tests, and the turns and replies they started, end
  # with the test: a turn left waiting for a model would answer into the next.
  defp end_queues do
    supervisor = PhoenixKitAgent.Telegram.QueueSupervisor

    for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor) do
      DynamicSupervisor.terminate_child(supervisor, pid)
    end

    for tasks <- [
          PhoenixKitAgent.Telegram.TaskSupervisor,
          PhoenixKitAgent.Telegram.ReplySupervisor
        ],
        pid <- Task.Supervisor.children(tasks) do
      Task.Supervisor.terminate_child(tasks, pid)
    end

    :ok
  end

  defp stop_all_turns do
    for {pid, _} <-
          Registry.select(PhoenixKitAgent.Turns.Registry, [{{:_, :"$1", :_}, [], [{{:"$1", 0}}]}]) do
      Process.exit(pid, :kill)
    end

    :ok
  end

  # Until the jobs and replies the bridge started have ended (what they log
  # and send is all there by then); no sleeping on a guess.
  defp settle(tries \\ 250) do
    supervisors = [
      PhoenixKitAgent.Telegram.TaskSupervisor,
      PhoenixKitAgent.Telegram.ReplySupervisor
    ]

    if tries > 0 and Enum.any?(supervisors, &(Task.Supervisor.children(&1) != [])) do
      Process.sleep(10)
      settle(tries - 1)
    else
      :ok
    end
  end

  # ── a picture is asked about ────────────────────────────────────────

  describe "a photo" do
    @tag :imagemagick
    test "is shown to the model with its caption as one turn, and answered", ctx do
      model_says("A grey square.")

      photo(ctx, caption: "What is this?", message_id: 31)
      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["A grey square."]
      assert {:react, _, @chat, 31, "👍"} = List.last(calls)
      assert user_messages(ctx.user) == ["What is this?"]

      assert_received {:model_request, body}
      assert images_in(body) == 1

      assert [%Attachment{status: "ready", kind: "image", message_uuid: message_uuid}] =
               attachments(ctx.user)

      assert message_uuid
    end

    @tag :imagemagick
    test "the largest size that fits is the one downloaded, within the limit", ctx do
      model_says("Ok.")

      photo(ctx, sizes: [{"s", 800}, {"m", 90_000}, {"l", 9_000_000}, {"xl", 11_000_000}])
      calls = calls_until(reaction?("👍"))

      assert downloads(calls) == ["l"]

      assert {:download_file, _, "l", opts} =
               Enum.find(calls, &match?({:download_file, _, _, _}, &1))

      assert opts[:max_bytes] == 10 * 1_048_576
    end

    @tag :imagemagick
    test "with no caption is asked about in the user's language", ctx do
      model_says("A picture.")

      photo(ctx)
      calls_until(reaction?("👍"))

      assert user_messages(ctx.user) == [
               Gettext.with_locale(PhoenixKitAgent.Gettext, "en", fn ->
                 Gettext.gettext(PhoenixKitAgent.Gettext, "What is in this picture?")
               end)
             ]
    end

    @tag :imagemagick
    test "a picture sent as a document (png) is taken too", ctx do
      model_says("Seen.")

      document(ctx, "image/png", caption: "From a file")
      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["Seen."]
      assert downloads(calls) == ["doc-id"]
      assert_received {:model_request, body}
      assert images_in(body) == 1
    end

    @tag :imagemagick
    test "the uploader is the linked user, and the file is theirs alone", ctx do
      model_says("Ok.")

      photo(ctx)
      calls_until(reaction?("👍"))

      assert [%Attachment{user_uuid: user_uuid, file_uuid: file_uuid}] = attachments(ctx.user)
      assert user_uuid == ctx.user.uuid
      assert file_uuid
      assert Repo.aggregate(Attachment, :count) == 1
    end

    test "a model that does not see is told so, nothing is stored", ctx do
      other = chat_endpoint("no")
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", other.uuid)
      model_says("never")

      photo(ctx, caption: "Look")
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.picture(:no_vision_model)]
      assert downloads(calls) == []
      assert attachments(ctx.user) == []
      assert user_messages(ctx.user) == []
      refute_received {:model_request, _}
    end

    @tag :imagemagick
    test "a model that does not see gets a description from the vision model", ctx do
      other = chat_endpoint("no")
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", other.uuid)

      eyes =
        endpoint_fixture(%{
          model: "a/eyes",
          provider_settings: %{"capabilities" => %{"vision" => "yes", "model" => "a/eyes"}}
        })

      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", eyes.uuid)
      model_says("It says SOFA 3 PCS.")

      photo(ctx, caption: "What does it say?")
      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["It says SOFA 3 PCS."]
      # The description, then the turn: the second call carries no pixels.
      assert_received {:model_request, _description}
      assert_received {:model_request, turn}
      assert images_in(turn) == 0
    end

    @tag :imagemagick
    test "a picture that cannot be read is told, with no turn and no file left", ctx do
      eyes =
        endpoint_fixture(%{
          model: "a/eyes",
          provider_settings: %{"capabilities" => %{"vision" => "yes", "model" => "a/eyes"}}
        })

      other = chat_endpoint("no")
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", other.uuid)
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", eyes.uuid)

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "x"}})
      end)

      photo(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.attachment_error("model_error")]
      assert attachments(ctx.user) == []
      assert user_messages(ctx.user) == []
    end

    @tag :imagemagick
    test "a document that says it is a picture and is not is refused", ctx do
      TelegramClient.set(:download, fn _id, _opts -> {:ok, Files.text_pdf(["Hello"])} end)
      model_says("never")

      document(ctx, "image/png")
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.picture(:unsupported_type)]
      assert attachments(ctx.user) == []
      refute_received {:model_request, _}
    end

    test "a pdf document stays refused as text only", ctx do
      document(ctx, "application/pdf")
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.static(:text_only)]
      assert downloads(calls) == []
    end

    test "a file Telegram will not give is told, no turn", ctx do
      TelegramClient.set(:download, fn _id, _opts -> {:error, :unreachable} end)

      photo(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.picture(:download_failed)]
      assert attachments(ctx.user) == []
    end

    test "one over the limit by its own count is too large", ctx do
      photo(ctx, sizes: [{"huge", 12_000_000}])
      calls = calls_until(reaction?("🤷"))

      assert downloads(calls) == []
      assert texts(calls) == [Texts.picture(:too_large)]
    end

    @tag :imagemagick
    test "a turn that is refused leaves no file behind", ctx do
      Repo.insert!(%PhoenixKitAgent.Schemas.UserSettings{
        user_uuid: ctx.user.uuid,
        daily_turn_limit: 0
      })

      model_says("never")

      photo(ctx, caption: "Look")
      calls_until(reaction?("🤷"))

      assert attachments(ctx.user) == []
      refute_received {:model_request, _}
    end

    test "from a chat without agent.telegram: refused before the download", ctx do
      other = user_with(["agent"], "no-telegram")
      telegram_link_fixture(other, ctx.connection, 555)

      extra = %{"photo" => [%{"file_id" => "x", "file_size" => 10}]}
      Bridge.dispatch(ctx.connection, TelegramClient.update(555, nil, extra: extra))
      assert_receive {:tg, {:send_message, _, 555, text}}, 5_000
      settle()

      assert text == Texts.picture(:forbidden)
      refute_received {:tg, {:download_file, _, _, _}}
    end

    @tag :imagemagick
    test "waits for the picture to be read, but not for ever", ctx do
      Application.put_env(:phoenix_kit_agent, :telegram_attachment_wait_ms, 300)
      holder = hold_every_place(ctx.user)
      model_says("never")

      photo(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.attachment_error("timeout")]
      assert attachments(ctx.user) == []
      refute_received {:model_request, _}
      send(holder, :release)
      processing_ended()
    end

    @tag :imagemagick
    test "nothing of the picture or its caption is logged", ctx do
      secret = "SECRET-CAPTION"

      {_result, events} =
        LogProbe.capture(fn ->
          model_says("Fine.")
          photo(ctx, caption: secret)
          calls_until(reaction?("👍"))
          settle()
        end)

      refute Enum.any?(events, &String.contains?(&1, secret))
    end
  end

  # ── an album is one question ─────────────────────────────────────────

  describe "an album" do
    @tag :imagemagick
    test "is one turn: the pictures together, the first caption there is", ctx do
      model_says("Two squares.")

      photo(ctx, media_group_id: "g1", message_id: 1, sizes: [{"a", 100}])

      photo(ctx,
        media_group_id: "g1",
        message_id: 2,
        caption: "Compare them",
        sizes: [{"b", 100}]
      )

      photo(ctx, media_group_id: "g1", message_id: 3, sizes: [{"c", 100}])

      calls = calls_until(reaction?("👍"))

      assert Enum.sort(downloads(calls)) == ["a", "b", "c"]
      assert texts(calls) == ["Two squares."]
      assert user_messages(ctx.user) == ["Compare them"]
      assert_received {:model_request, body}
      assert images_in(body) == 3
      refute_received {:model_request, _}
      settle()
      assert Enum.all?(attachments(ctx.user), &(&1.message_uuid != nil))
    end

    @tag :imagemagick
    test "pictures of another album, or none, are turns of their own", ctx do
      model_says("Answer.")

      photo(ctx, media_group_id: "g1", message_id: 1, sizes: [{"a", 100}])
      photo(ctx, media_group_id: "g2", message_id: 2, sizes: [{"b", 100}])

      calls_until(reaction?("👍"))
      calls_until(reaction?("👍"))

      settle()
      assert length(user_messages(ctx.user)) == 2
    end
  end

  # ── what a picture costs is asked before it is fetched ───────────────

  describe "before the download" do
    test "a picture over the user's size limit is not fetched", ctx do
      Repo.insert!(%PhoenixKitAgent.Schemas.UserSettings{
        user_uuid: ctx.user.uuid,
        max_attachment_mb: 1
      })

      photo(ctx, sizes: [{"big", 2_000_000}])
      calls = calls_until(reaction?("🤷"))

      assert downloads(calls) == []
      assert texts(calls) == [Texts.picture(:too_large)]
    end

    @tag :imagemagick
    test "the size is taken from the biggest file, not from the order of the list", ctx do
      model_says("Ok.")

      photo(ctx, sizes: [{"l", 90_000}, {"m", 5_000}, {"s", 800}])
      calls = calls_until(reaction?("👍"))

      assert downloads(calls) == ["l"]
    end

    test "an album refused as a whole is refused once, nothing fetched", ctx do
      other = user_with(["agent"], "no-telegram-album")
      telegram_link_fixture(other, ctx.connection, 556)

      for id <- 1..3 do
        extra = %{
          "photo" => [%{"file_id" => "x#{id}", "file_size" => 10}],
          "media_group_id" => "g-refused"
        }

        Bridge.dispatch(
          ctx.connection,
          TelegramClient.update(556, nil, extra: extra, message_id: id)
        )
      end

      assert_receive {:tg, {:send_message, _, 556, text}}, 5_000
      settle()

      assert text == Texts.picture(:forbidden)
      refute_received {:tg, {:send_message, _, 556, _}}
      refute_received {:tg, {:download_file, _, _, _}}
    end
  end

  # ── a long album ─────────────────────────────────────────────────────

  describe "an album that comes while the chat is busy" do
    @tag :imagemagick
    test "waits as one job, and is one turn when its place comes", ctx do
      test = self()

      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        send(test, {:model_request, body})

        if List.last(body["messages"])["content"] == "slow question" do
          send(test, {:slow, self()})

          receive do
            :release -> :ok
          end
        end

        Req.Test.json(conn, %{
          "model" => @model,
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "Seen."}}],
          "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}
        })
      end)

      Bridge.dispatch(ctx.connection, TelegramClient.update(@chat, "slow question"))
      assert_receive {:slow, pid}, 8_000

      for id <- 1..4 do
        photo(ctx, media_group_id: "busy", message_id: 10 + id, sizes: [{"p#{id}", 100}])
      end

      send(pid, :release)
      calls_until(reaction?("👍"))
      calls = calls_until(reaction?("👍"))

      refute Enum.any?(texts(calls), &(&1 == Texts.static(:wait)))
      assert Enum.sort(downloads(calls)) == ["p1", "p2", "p3", "p4"]
      assert_received {:model_request, %{"messages" => _} = first}
      assert images_in(first) == 0
      assert_received {:model_request, album}
      assert images_in(album) == 4
      refute_received {:model_request, _}
      settle()
    end
  end

  describe "an album longer than a message takes" do
    @tag :imagemagick
    test "takes the first ones and says how many were left out", ctx do
      Repo.insert!(%PhoenixKitAgent.Schemas.UserSettings{
        user_uuid: ctx.user.uuid,
        max_attachments_per_message: 2
      })

      model_says("Two seen.")

      for id <- 1..3 do
        photo(ctx, media_group_id: "long", message_id: id, sizes: [{"q#{id}", 100}])
      end

      calls = calls_until(reaction?("👍"))

      assert Enum.sort(downloads(calls)) == ["q1", "q2"]

      assert Enum.any?(texts(calls), &(&1 =~ "Pictures taken: 2 of 3"))
      assert_received {:model_request, body}
      assert images_in(body) == 2
      settle()
    end

    @tag :imagemagick
    test "says how many could not be read when others were", ctx do
      model_says("One seen.")

      TelegramClient.set(:download, fn
        "bad", _opts -> {:ok, Files.text_pdf(["Hello"])}
        _id, _opts -> {:ok, Files.png(40, 30)}
      end)

      photo(ctx, media_group_id: "mixed", message_id: 1, sizes: [{"good", 100}])
      photo(ctx, media_group_id: "mixed", message_id: 2, sizes: [{"bad", 100}])
      calls = calls_until(reaction?("👍"))

      assert Enum.any?(texts(calls), &(&1 == "Pictures that could not be read: 1."))
      assert_received {:model_request, body}
      assert images_in(body) == 1
      settle()
    end

    @tag :imagemagick
    test "describes the pictures one after the other: none is lost to the wait for a place",
         ctx do
      other = chat_endpoint("no")
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", other.uuid)

      eyes =
        endpoint_fixture(%{
          model: "a/eyes",
          provider_settings: %{"capabilities" => %{"vision" => "yes", "model" => "a/eyes"}}
        })

      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", eyes.uuid)
      Application.put_env(:phoenix_kit_agent, :telegram_attachment_wait_ms, 60_000)
      model_says("A description or an answer.")

      for id <- 1..4 do
        photo(ctx, media_group_id: "describe", message_id: id, sizes: [{"d#{id}", 100}])
      end

      calls = calls_until(reaction?("👍"), 30_000)

      refute Enum.any?(texts(calls), &(&1 =~ "could not be read"))
      assert length(downloads(calls)) == 4
      settle()
    end
  end

  describe "a turn that was cut off after adding a picture" do
    @tag :imagemagick
    test "leaves a file that the next picture of the chat sweeps away", ctx do
      Repo.insert!(%PhoenixKitAgent.Schemas.UserSettings{
        user_uuid: ctx.user.uuid,
        max_attachments_per_message: 1
      })

      Application.put_env(:phoenix_kit_agent, :telegram_attachment_wait_ms, 300)
      model_says("Fine.")

      photo(ctx, message_id: 1)
      calls_until(reaction?("👍"))
      settle()

      # What a killed turn leaves: a picture no message took, long ago.
      conversation = PhoenixKitAgent.Conversations.latest_telegram_conversation(ctx.user.uuid)

      orphan =
        Repo.insert!(%Attachment{
          conversation_uuid: conversation.uuid,
          user_uuid: ctx.user.uuid,
          filename: "telegram-picture",
          content_type: "image/png",
          size_bytes: 81,
          kind: "image",
          status: "ready"
        })

      Repo.update_all(
        from(a in Attachment, where: a.uuid == ^orphan.uuid),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      photo(ctx, message_id: 2)
      calls_until(reaction?("👍"))
      settle()

      assert Enum.all?(attachments(ctx.user), &(&1.message_uuid != nil))
      assert length(attachments(ctx.user)) == 2
    end
  end

  describe "the sweep of pictures nobody took" do
    alias PhoenixKit.Modules.Storage
    alias PhoenixKitAgent.{Attachments, Conversations}
    alias PhoenixKitAgent.Schemas.{Conversation, Message}

    @bound 5_000

    defp telegram_conversation(user) do
      {:ok, conversation} =
        Conversations.create_conversation_for(user,
          metadata: %{"source" => "telegram", "chat_id" => @chat}
        )

      conversation
    end

    defp row(conversation, user, attrs) do
      attachment =
        Repo.insert!(
          struct(
            %Attachment{
              conversation_uuid: conversation.uuid,
              user_uuid: user.uuid,
              filename: "telegram-picture",
              content_type: "image/png",
              size_bytes: 81,
              kind: "image",
              status: "ready"
            },
            Map.delete(attrs, :age_s)
          )
        )

      Repo.update_all(
        from(a in Attachment, where: a.uuid == ^attachment.uuid),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -Map.get(attrs, :age_s, 60), :second)]
      )

      attachment.uuid
    end

    defp remaining(uuids),
      do: Repo.all(from(a in Attachment, where: a.uuid in ^uuids, select: a.uuid))

    test "removes only the old, unsent pictures of the chat that the bridge added", ctx do
      conversation = telegram_conversation(ctx.user)
      other_conversation = telegram_conversation(ctx.user)
      stranger = user_with(["agent", "agent.telegram"], "stranger")
      strangers_conversation = telegram_conversation(stranger)

      sent_message =
        Repo.insert!(
          Message.changeset(%Message{conversation_uuid: conversation.uuid}, %{
            role: "user",
            content: "asked"
          })
        )

      old = row(conversation, ctx.user, %{})
      young = row(conversation, ctx.user, %{age_s: 1})
      sent = row(conversation, ctx.user, %{message_uuid: sent_message.uuid})
      panel_upload = row(conversation, ctx.user, %{filename: "report.png"})
      elsewhere = row(other_conversation, ctx.user, %{})
      strangers = row(strangers_conversation, stranger, %{})

      assert :ok = Attachments.sweep_unsent_for_telegram(ctx.ref, conversation.uuid, @bound)

      left = remaining([old, young, sent, panel_upload, elsewhere, strangers])

      refute old in left
      assert young in left, "too young"
      assert sent in left, "sent"
      assert panel_upload in left, "panel upload"
      assert elsewhere in left, "other conversation"
      assert strangers in left, "other user"
    end

    test "does not reach into the conversation of another user", ctx do
      stranger = user_with(["agent", "agent.telegram"], "stranger-2")
      strangers_conversation = telegram_conversation(stranger)
      strangers = row(strangers_conversation, stranger, %{})

      assert {:error, _refusal} =
               Attachments.sweep_unsent_for_telegram(
                 ctx.ref,
                 strangers_conversation.uuid,
                 @bound
               )

      assert remaining([strangers]) == [strangers]
      assert %Conversation{} = Repo.get(Conversation, strangers_conversation.uuid)
    end

    test "a user who may hold no picture at all is told there is no room", ctx do
      Repo.insert!(%PhoenixKitAgent.Schemas.UserSettings{
        user_uuid: ctx.user.uuid,
        max_attachments_per_message: 0
      })

      photo(ctx)
      calls = calls_until(reaction?("🤷"))

      assert downloads(calls) == []
      assert texts(calls) == [Texts.picture(:too_many)]
    end

    @tag :imagemagick
    test "a row discarded while it is being processed is let go without a crash or a file",
         ctx do
      Application.put_env(:phoenix_kit_agent, :telegram_attachment_wait_ms, 1_500)
      holder = hold_every_place(ctx.user)
      model_says("never")

      {_result, events} =
        LogProbe.capture(fn ->
          photo(ctx)
          assert_eventually(fn -> Enum.any?(attachments(ctx.user), & &1.file_uuid) end)
          [%Attachment{file_uuid: file_uuid, status: "pending"}] = attachments(ctx.user)

          # The wait runs out, the row is discarded under the processing.
          calls = calls_until(reaction?("🤷"))
          assert texts(calls) == [Texts.attachment_error("timeout")]
          assert attachments(ctx.user) == []

          send(holder, :release)
          processing_ended()
          settle()
          assert attachments(ctx.user) == []
          refute Repo.get(Storage.File, file_uuid)
        end)

      refute Enum.any?(events, &(&1 =~ "could not be settled" or &1 =~ "crashed"))
    end
  end

  describe "pictures nobody took" do
    @tag :imagemagick
    test "siblings that were not taken run together, in front of the waiting ones", ctx do
      alias PhoenixKitAgent.Telegram.ChatQueue

      Process.flag(:trap_exit, true)
      model_says("Both seen.")

      {:ok, pid} =
        ChatQueue.start_link(key: {ctx.connection, @chat}, connection_uuid: ctx.connection)

      job = fn id ->
        %{
          kind: :photo,
          message_id: id,
          text: nil,
          group: "orphans",
          photo: %{file_id: "o#{id}", size: 100}
        }
      end

      # A job of the album has ended without taking its siblings.
      task_ref = make_ref()

      :sys.replace_state(pid, fn state ->
        %{
          state
          | task: %Task{ref: task_ref, pid: self(), owner: self(), mfa: {__MODULE__, :x, 0}},
            group: "orphans",
            siblings: [{ctx.ref, job.(1)}, {ctx.ref, job.(2)}]
        }
      end)

      send(pid, {task_ref, :ended})
      calls = calls_until(reaction?("👍"))

      assert Enum.sort(downloads(calls)) == ["o1", "o2"]
      assert_received {:model_request, body}
      assert images_in(body) == 2
      refute_received {:model_request, _}
      settle()
    end
  end

  defp assert_eventually(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("did not happen in time")
      true -> Process.sleep(25) && assert_eventually(fun, tries - 1)
    end
  end

  # How often the bot showed "typing" before a call that `done` matches.
  defp typing_count_until(done, count \\ 0) do
    receive do
      {:tg, {:typing, _, _}} -> typing_count_until(done, count + 1)
      {:tg, call} -> if done.(call), do: count, else: typing_count_until(done, count)
    after
      8_000 -> flunk("the bot was not called as expected")
    end
  end

  describe "while a picture is being read" do
    @tag :imagemagick
    test "the bot goes on showing typing", ctx do
      Application.put_env(:phoenix_kit_agent, :telegram_attachment_wait_ms, 1_500)
      Application.put_env(:phoenix_kit_agent, :telegram_typing_every_ms, 100)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :telegram_typing_every_ms) end)
      holder = hold_every_place(ctx.user)
      model_says("never")

      photo(ctx)

      assert typing_count_until(reaction?("🤷")) >= 4
      send(holder, :release)
      processing_ended()
    end
  end

  defp processing_ended(tries \\ 200) do
    if tries > 0 and Task.Supervisor.children(PhoenixKitAgent.Attachments.TaskSupervisor) != [] do
      Process.sleep(10)
      processing_ended(tries - 1)
    end
  end

  # A process that holds every place for the user's files until `:release`.
  defp hold_every_place(user) do
    test = self()

    holder =
      spawn_link(fn ->
        for _ <- 1..Bounds.get(:jobs_per_user) do
          :ok = Slots.acquire(user.uuid)
        end

        send(test, :holding)

        receive do
          :release -> :ok
        end
      end)

    assert_receive :holding, 5_000
    holder
  end
end
