defmodule PhoenixKitAgent.Web.DockVoiceTest do
  @moduledoc """
  The microphone of the chat panel: it is there only where voice input is on;
  a clip it delivers is written down off the panel's process, and the words are
  pushed to the composer for the person to edit and send — no turn is started,
  and nothing of the recording or the words is logged. The model is a
  `Req.Test` stub behind `phoenix_kit_ai`; the clip is sent to the panel as the
  core's recorder sends it (`{:audio_recorded, id, clip}`).
  """

  use PhoenixKitAgent.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAgent.Schemas.{Conversation, Message}
  alias PhoenixKitAgent.Test.LogProbe
  alias PhoenixKitAgent.Web.Dock

  @stub __MODULE__
  @ears "google/gemini-2.5-flash"

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Req.Test.set_req_test_to_private()
    end)

    ears =
      endpoint_fixture(%{
        model: @ears,
        provider_settings: %{"capabilities" => %{"audio_input" => "yes", "model" => @ears}}
      })

    {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", ears.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentVoice#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("voice")
    {:ok, _} = Roles.assign_role(user, role.name)
    {_ref, token} = session_fixture(user)

    %{conn: conn, user: user, role: role, token: token, ears: ears}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp dock(ctx) do
    {:ok, view, _html} =
      ctx.conn
      |> Plug.Test.init_test_session(%{"user_token" => ctx.token})
      |> live_isolated(Dock, session: %{"user_uuid" => ctx.user.uuid, "locale" => "en"})

    view
  end

  defp clip, do: %{data: "RIFF-clip", format: "wav", content_type: "audio/wav", duration: 2.0}

  defp heard(text) do
    %{
      "model" => @ears,
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => Jason.encode!(%{"text" => text, "language" => "en"})
          }
        }
      ],
      "usage" => %{"prompt_tokens" => 30, "completion_tokens" => 8, "total_tokens" => 38}
    }
  end

  defp model_hears(text), do: Req.Test.expect(@stub, &Req.Test.json(&1, heard(text)))

  defp record(view, clip \\ clip()), do: send(view.pid, {:audio_recorded, "pk-agent-mic", clip})

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp eventually(fun, tries \\ 50) do
    case fun.() do
      falsey when falsey in [false, nil, []] and tries > 0 ->
        Process.sleep(50)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end

  # ── the microphone ──────────────────────────────────────────────────

  describe "the microphone" do
    test "is in the composer where voice input is on", ctx do
      view = dock(ctx)

      assert has_element?(view, "#pk-agent-composer #pk-agent-mic")
      assert render(view) =~ "Dictate"
    end

    test "is not there without a speech model", ctx do
      {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", "")
      view = dock(ctx)

      refute has_element?(view, "#pk-agent-mic")
    end
  end

  describe "the microphone where the platform lacks something" do
    defmodule NoTranscribe do
      @moduledoc false
    end

    test "is not there on a core without the recorder", ctx do
      Application.put_env(:phoenix_kit_agent, :audio_recorder, __MODULE__.NoSuchRecorder)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :audio_recorder) end)

      view = dock(ctx)

      refute has_element?(view, "#pk-agent-mic")
      assert has_element?(view, "#pk-agent-composer")
    end

    test "is not there on an AI module that cannot write speech down", ctx do
      Application.put_env(:phoenix_kit_agent, :speech_ai, NoTranscribe)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :speech_ai) end)

      view = dock(ctx)

      refute has_element?(view, "#pk-agent-mic")
    end
  end

  describe "a recording being written down" do
    defp slow_model do
      test = self()

      Req.Test.expect(@stub, fn conn ->
        send(test, {:recognising, self()})

        receive do
          :release -> Req.Test.json(conn, heard("late words"))
        end
      end)
    end

    test "is journaled even when the panel is gone before the answer", ctx do
      Process.flag(:trap_exit, true)
      slow_model()
      view = dock(ctx)
      record(view)
      assert_receive {:recognising, pid}, 5_000

      ref = Process.monitor(view.pid)
      Process.exit(view.pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000

      send(pid, :release)

      assert eventually(fn ->
               Repo.all(from(r in PhoenixKitAI.Request, where: r.endpoint_uuid == ^ctx.ears.uuid))
             end) != []
    end

    test "is given up after the wait, the microphone is free and a late answer is let go",
         ctx do
      Application.put_env(:phoenix_kit_agent, :speech_wait_ms, 100)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :speech_wait_ms) end)

      slow_model()
      view = dock(ctx)
      record(view)
      assert_receive {:recognising, pid}, 5_000

      assert eventually(fn -> not has_element?(view, "#pk-agent-transcribing") end)
      assert has_element?(view, "#pk-agent-dock-error")

      send(pid, :release)
      refute_push_event(view, "pk-agent:dictated", _any, 500)
    end
  end

  # ── a clip becomes words in the composer ────────────────────────────

  describe "a clip" do
    test "is written down and its words are put into the composer, nothing is sent", ctx do
      model_hears("  how many orders today?\n")
      view = dock(ctx)

      record(view)

      assert_push_event(view, "pk-agent:dictated", %{text: "how many orders today?"})
      refute has_element?(view, "#pk-agent-transcribing")
      refute has_element?(view, "#pk-agent-dock-error")
      assert count(Conversation) == 0
      assert count(Message) == 0
    end

    test "is paid by the user, as the agent", ctx do
      model_hears("hello")
      view = dock(ctx)

      record(view)
      assert_push_event(view, "pk-agent:dictated", %{text: "hello"})

      assert [%{user_uuid: user_uuid, metadata: %{"source" => "agent"}}] =
               Repo.all(from(r in PhoenixKitAI.Request, where: r.endpoint_uuid == ^ctx.ears.uuid))

      assert user_uuid == ctx.user.uuid
    end

    test "shows that it is being written down, one clip at a time", ctx do
      test = self()

      Req.Test.expect(@stub, fn conn ->
        send(test, {:recognising, self()})

        receive do
          :release -> Req.Test.json(conn, heard("slowly"))
        end
      end)

      view = dock(ctx)
      record(view)
      assert_receive {:recognising, pid}, 5_000

      assert has_element?(view, "#pk-agent-transcribing")

      # A second clip meanwhile is let go (the recorder is busy as well).
      record(view)
      refute render(view) =~ "went wrong"

      send(pid, :release)
      assert_push_event(view, "pk-agent:dictated", %{text: "slowly"})
      refute has_element?(view, "#pk-agent-transcribing")
      refute_push_event(view, "pk-agent:dictated", _any, 200)
    end

    test "with no speech in it is told so", ctx do
      model_hears("  ")
      view = dock(ctx)

      record(view)

      assert render_async(view) =~ "No speech was heard"
      assert has_element?(view, "#pk-agent-dock-error")
      refute has_element?(view, "#pk-agent-transcribing")
    end

    test "a failing provider is told as a failure", ctx do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "no"}})
      end)

      view = dock(ctx)
      record(view)

      assert render_async(view) =~ "could not be written down"
    end

    test "after the right to the assistant was taken away is refused, nothing is paid", ctx do
      view = dock(ctx)
      :ok = Permissions.revoke_permission(ctx.role.uuid, "agent")
      Req.Test.stub(@stub, fn _conn -> flunk("the model was asked") end)

      record(view)

      assert render_async(view) =~ "You may not use the assistant now"
      assert Repo.aggregate(PhoenixKitAI.Request, :count) == 0
    end

    test "arriving while voice is off is ignored", ctx do
      view = dock(ctx)
      {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", "")
      view2 = dock(ctx)
      Req.Test.stub(@stub, fn _conn -> flunk("the model was asked") end)

      record(view2)

      refute render(view2) =~ "went wrong"
      refute_push_event(view2, "pk-agent:dictated", _any, 200)
      _ = view
    end

    test "something that is not a clip is ignored", ctx do
      view = dock(ctx)
      Req.Test.stub(@stub, fn _conn -> flunk("the model was asked") end)

      send(view.pid, {:audio_recorded, "pk-agent-mic", %{format: "wav"}})
      send(view.pid, {:audio_recorded, "someone-else", clip()})

      refute_push_event(view, "pk-agent:dictated", _any, 200)
      refute has_element?(view, "#pk-agent-transcribing")
    end

    test "nothing of the recording or the words is logged", ctx do
      secret = "SECRET-SPOKEN-WORDS"
      view = dock(ctx)

      {_result, events} =
        LogProbe.capture(fn ->
          model_hears(secret)
          record(view, %{clip() | data: "SECRET-AUDIO-BYTES"})
          assert_push_event(view, "pk-agent:dictated", %{text: ^secret})

          Req.Test.stub(@stub, fn conn ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => %{"message" => secret}})
          end)

          record(view, %{clip() | data: "SECRET-AUDIO-BYTES"})
          render_async(view)
        end)

      refute Enum.any?(events, &(&1 =~ secret or &1 =~ "SECRET-AUDIO"))
    end
  end
end
