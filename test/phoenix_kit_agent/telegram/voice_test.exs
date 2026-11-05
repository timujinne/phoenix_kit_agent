defmodule PhoenixKitAgent.Telegram.VoiceTest do
  @moduledoc """
  A voice message of a linked chat: checked like a text turn before anything
  is downloaded, written down (the model stubbed behind `phoenix_kit_ai`),
  shown as "🎙 Recognised: …", and then run exactly as the typed text, in the
  same queue of the chat. The bot is `PhoenixKitAgent.Test.TelegramClient`.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKitAgent.{Conversations, Speech}
  alias PhoenixKitAgent.Schemas.Message
  alias PhoenixKitAgent.Telegram.{Bridge, Limiter, Texts}
  alias PhoenixKitAgent.Test.{LogProbe, TelegramClient, Tools}

  @stub __MODULE__
  @model "deepseek/deepseek-v4.1-flash"
  @ears "google/gemini-2.5-flash"
  @chat 428_897_538

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    TelegramClient.start()

    end_queues()

    on_exit(fn ->
      stop_all_turns()
      end_queues()
      TelegramClient.stop()
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Req.Test.set_req_test_to_private()
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    ears =
      endpoint_fixture(%{
        model: @ears,
        provider_settings: %{"capabilities" => %{"audio_input" => "yes", "model" => @ears}}
      })

    {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", ears.uuid)

    user = user_with(["agent", "agent.telegram", "dashboard"], "voice")
    connection = UUIDv7.generate()
    ref = telegram_link_fixture(user, connection, @chat)
    Limiter.clear_unlinked(connection)

    %{user: user, connection: connection, ref: ref, ears: ears}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp answer(text) do
    %{
      "model" => @model,
      "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}],
      "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}
    }
  end

  defp model_says(text) do
    Req.Test.expect(@stub, fn conn -> Req.Test.json(conn, answer(text)) end)
  end

  defp ears_hear(text) do
    json = %{"text" => text, "language" => "en"}

    Req.Test.expect(@stub, fn conn ->
      Req.Test.json(conn, %{
        "model" => @ears,
        "choices" => [%{"message" => %{"role" => "assistant", "content" => Jason.encode!(json)}}],
        "usage" => %{"prompt_tokens" => 30, "completion_tokens" => 8, "total_tokens" => 38}
      })
    end)
  end

  # Any call to the model, to be counted.
  defp model_must_not_be_called do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      send(test, :model_called)
      Req.Test.json(conn, answer("No."))
    end)
  end

  defp voice(ctx, kind \\ "voice", opts \\ []),
    do: Bridge.dispatch(ctx.connection, TelegramClient.voice_update(@chat, kind, opts))

  defp calls_until(done, timeout \\ 5_000) do
    receive do
      {:tg, {:typing, _, _}} ->
        calls_until(done, timeout)

      {:tg, call} ->
        if done.(call), do: [call], else: [call | calls_until(done, timeout)]
    after
      timeout -> flunk("the bot was not called as expected")
    end
  end

  # How many times the bot showed "typing" before a call that `done` matches.
  defp typing_count_until(done, count \\ 0) do
    receive do
      {:tg, {:typing, _, _}} ->
        typing_count_until(done, count + 1)

      {:tg, call} ->
        if done.(call), do: count, else: typing_count_until(done, count)
    after
      5_000 -> flunk("the bot was not called as expected")
    end
  end

  defp reaction?(emoji), do: &match?({:react, _, _, _, ^emoji}, &1)
  defp texts(calls), do: for({:send_message, _, _, text} <- calls, do: text)
  defp emojis(calls), do: for({:react, _, _, _, emoji} <- calls, do: emoji)

  defp downloaded(calls), do: Enum.find(calls, &match?({:download_file, _, _, _}, &1))

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

  # ── a voice message is written down, shown, and answered ─────────────

  describe "a voice message" do
    test "is shown as recognised, then answered as the text it said, then 👍", ctx do
      ears_hear("How many orders?")
      model_says("You have three orders.")

      voice(ctx, "voice", message_id: 41, file_id: "AwAD-voice")
      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["🎙 Recognised: How many orders?", "You have three orders."]
      assert emojis(calls) == ["👀", "👀", "👍"]
      assert {:react, _, @chat, 41, "👍"} = List.last(calls)
      assert user_messages(ctx.user) == ["How many orders?"]
    end

    test "is downloaded by its file id, within the size a recognition takes", ctx do
      ears_hear("Hi")
      model_says("Hello.")

      voice(ctx, "voice", file_id: "AwAD-voice")
      calls = calls_until(reaction?("👍"))

      assert {:download_file, connection, "AwAD-voice", opts} = downloaded(calls)
      assert connection == ctx.connection
      assert opts[:max_bytes] == Speech.max_bytes()
    end

    test "an audio file is taken too, in the format its type says", ctx do
      TelegramClient.set(:download, fn _file_id, _opts -> {:ok, "ID3-mp3-bytes"} end)
      ears_hear("From a file.")
      model_says("Done.")

      voice(ctx, "audio", mime_type: "audio/mpeg")
      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["🎙 Recognised: From a file.", "Done."]
    end

    test "the recognition is paid by the user, as the agent", ctx do
      ears_hear("Hi")
      model_says("Hello.")

      voice(ctx)
      calls_until(reaction?("👍"))

      requests =
        Repo.all(from(r in PhoenixKitAI.Request, where: r.endpoint_uuid == ^ctx.ears.uuid))

      assert [%{user_uuid: user_uuid, metadata: %{"source" => "agent"}}] = requests
      assert user_uuid == ctx.user.uuid
    end

    test "waits its turn in the queue of the chat: a text sent after it is answered after it",
         ctx do
      test = self()

      Req.Test.expect(@stub, fn conn ->
        send(test, {:recognising, self()})

        receive do
          :release ->
            Req.Test.json(conn, %{
              "model" => @ears,
              "choices" => [
                %{
                  "message" => %{
                    "role" => "assistant",
                    "content" =>
                      Jason.encode!(%{"text" => "First, by voice.", "language" => "en"})
                  }
                }
              ],
              "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 3, "total_tokens" => 6}
            })
        end
      end)

      model_says("Answer one.")
      model_says("Answer two.")

      voice(ctx, "voice", message_id: 1)
      assert_receive {:recognising, pid}, 5_000

      Bridge.dispatch(
        ctx.connection,
        TelegramClient.update(@chat, "Second, typed.", message_id: 2)
      )

      refute_receive {:tg, {:send_message, _, _, "Answer two."}}, 200

      send(pid, :release)
      calls = calls_until(&match?({:send_message, _, _, "Answer two."}, &1))

      assert texts(calls) == ["🎙 Recognised: First, by voice.", "Answer one.", "Answer two."]
      assert user_messages(ctx.user) |> Enum.sort() == ["First, by voice.", "Second, typed."]
    end

    test "nothing of the recording or the words is logged", ctx do
      secret = "SECRET-SPOKEN-WORDS"
      TelegramClient.set(:download, fn _id, _opts -> {:ok, "OggS-SECRET-AUDIO"} end)

      {_result, events} =
        LogProbe.capture(fn ->
          ears_hear(secret)
          model_says("Fine.")
          voice(ctx)
          calls_until(reaction?("👍"))
          settle()
        end)

      refute Enum.any?(events, &(&1 =~ secret or &1 =~ "SECRET-AUDIO"))
    end
  end

  # ── what is refused, and nothing paid or downloaded ───────────────────

  describe "a voice message that cannot be taken" do
    test "without a speech model: told so, 🤷, nothing downloaded", ctx do
      {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", "")
      model_must_not_be_called()

      voice(ctx, "voice", message_id: 9)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.speech(:speech_off)]
      refute downloaded(calls)
      refute_received :model_called
    end

    test "longer than two minutes: told so, nothing downloaded", ctx do
      model_must_not_be_called()

      voice(ctx, "voice", duration: 121)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.speech(:too_long)]
      refute downloaded(calls)
      refute_received :model_called
    end

    test "larger than the recognition takes: told so, nothing downloaded", ctx do
      model_must_not_be_called()

      voice(ctx, "audio", file_size: Speech.max_bytes() + 1)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.speech(:too_long)]
      refute downloaded(calls)
    end

    test "from a chat without agent.telegram: refused before the download", ctx do
      other = user_with(["agent"], "no-telegram")
      telegram_link_fixture(other, ctx.connection, 555)
      model_must_not_be_called()

      Bridge.dispatch(ctx.connection, TelegramClient.voice_update(555, "voice", []))
      assert_receive {:tg, {:send_message, _, 555, text}}, 5_000

      settle()
      assert text == Texts.speech(:forbidden)
      refute_received {:tg, {:download_file, _, _, _}}
      refute_received :model_called
    end

    test "from a chat nobody linked: no download either", ctx do
      model_must_not_be_called()

      Bridge.dispatch(ctx.connection, TelegramClient.voice_update(777, "voice", []))
      assert_receive {:tg, {:send_message, _, 777, _}}, 5_000

      settle()
      refute_received {:tg, {:download_file, _, _, _}}
      refute_received :model_called
    end

    test "a file Telegram will not give: told so, no turn", ctx do
      TelegramClient.set(:download, fn _id, _opts -> {:error, :unreachable} end)
      model_must_not_be_called()

      voice(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.speech(:download_failed)]
      refute_received :model_called
      assert user_messages(ctx.user) == []
    end

    test "a core that cannot download: told so", ctx do
      TelegramClient.set(:download, fn _id, _opts -> {:error, :unavailable} end)

      voice(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.speech(:voice_unavailable)]
    end

    test "a file over the limit by Telegram's own count is too long", ctx do
      TelegramClient.set(:download, fn _id, _opts -> {:error, {:file_too_large, 99, 10}} end)

      voice(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.speech(:too_long)]
    end

    test "with no speech in it: told so, no turn", ctx do
      ears_hear("   ")

      voice(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.speech(:no_speech)]
      assert user_messages(ctx.user) == []
      assert Conversations.latest_telegram_conversation(ctx.user.uuid) == nil
    end

    test "over the user's limit: told so, nothing paid", ctx do
      Repo.insert!(%PhoenixKitAgent.Schemas.UserSettings{
        user_uuid: ctx.user.uuid,
        daily_cost_limit_micro_usd: 0
      })

      model_must_not_be_called()

      voice(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.speech({:limit_reached, :daily_cost})]
      assert downloaded(calls) == nil
      refute_received :model_called
    end
  end

  describe "while it is being written down" do
    test "the bot shows typing again and again", ctx do
      Application.put_env(:phoenix_kit_agent, :telegram_typing_every_ms, 40)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :telegram_typing_every_ms) end)

      Req.Test.expect(@stub, fn conn ->
        Process.sleep(400)

        Req.Test.json(conn, %{
          "model" => @ears,
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => Jason.encode!(%{"text" => "slowly", "language" => "en"})
              }
            }
          ],
          "usage" => %{"prompt_tokens" => 30, "completion_tokens" => 8, "total_tokens" => 38}
        })
      end)

      model_says("Done.")
      voice(ctx)

      assert typing_count_until(&match?({:send_message, _, _, "🎙" <> _}, &1)) >= 4
    end
  end

  describe "a core that cannot download a file" do
    test "takes no voice message, and the help does not promise one", ctx do
      TelegramClient.set(:can_download, false)
      model_must_not_be_called()

      refute Texts.static(:help) =~ "Voice messages"

      voice(ctx)
      calls = calls_until(&match?({:send_message, _, _, _}, &1))

      assert texts(calls) == [Texts.static(:text_only)]
      assert downloaded(calls) == nil
      refute_received :model_called
    end
  end

  describe "the help" do
    test "mentions voice messages when they are on, and not when they are off", ctx do
      assert Texts.static(:help) =~ "Voice messages work too"

      {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", "")
      refute Texts.static(:help) =~ "Voice messages"
      _ = ctx
    end

    test "tells what the bot reads: pictures always, voice when it is on, text only without files",
         ctx do
      assert Texts.static(:help) =~ "Pictures work too"
      assert Texts.static(:text_only) =~ "text, voice messages and pictures"

      {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", "")
      assert Texts.static(:help) =~ "Pictures work too"
      refute Texts.static(:text_only) =~ "voice"
      assert Texts.static(:text_only) =~ "text and pictures"

      TelegramClient.set(:can_download, false)
      assert Texts.static(:help) =~ "I read text only."
      refute Texts.static(:help) =~ "Pictures"
      assert Texts.static(:text_only) == "I understand text only for now."
      _ = ctx
    end
  end
end
