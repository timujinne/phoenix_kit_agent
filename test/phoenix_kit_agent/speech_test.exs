defmodule PhoenixKitAgent.SpeechTest do
  @moduledoc """
  A recording written down for a user (`PhoenixKitAgent.Speech`): who may ask,
  what is checked before the paid call, how the model's answer and its
  refusals become codes, and where the money goes. The model is stubbed behind
  `phoenix_kit_ai` (the real `PhoenixKitAI.transcribe/3` runs).
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitAgent.{Config, Speech, Spend}
  alias PhoenixKitAgent.Schemas.UserSettings
  alias PhoenixKitAgent.Test.LogProbe

  @stub __MODULE__
  @model "google/gemini-2.5-flash"
  @words "Hello, this is my order"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Req.Test.set_req_test_to_private()
    end)

    user = user_with(["agent"], "speaker")
    {ref, _token} = session_fixture(user)
    %{user: user, ref: ref, endpoint: speech_endpoint()}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp speech_endpoint(audio \\ "yes") do
    endpoint =
      endpoint_fixture(%{
        model: @model,
        provider_settings: %{"capabilities" => %{"audio_input" => audio, "model" => @model}}
      })

    {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", endpoint.uuid)
    endpoint
  end

  defp heard(json) do
    %{
      "model" => @model,
      "choices" => [%{"message" => %{"role" => "assistant", "content" => Jason.encode!(json)}}],
      "usage" => %{"prompt_tokens" => 30, "completion_tokens" => 8, "total_tokens" => 38}
    }
  end

  defp model_hears(json) do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      send(test, :model_called)
      Req.Test.json(conn, heard(json))
    end)
  end

  defp model_not_called do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      send(test, :model_called)
      Req.Test.json(conn, heard(%{"text" => "no", "language" => "en"}))
    end)
  end

  defp transcribe(ref, bytes \\ "RIFF-not-really-audio", format \\ "wav"),
    do: Speech.transcribe(ref, bytes, format, impersonated: false)

  # ── the answer ──────────────────────────────────────────────────────

  describe "transcribe/4" do
    test "writes the recording down", %{ref: ref} do
      model_hears(%{"text" => "  #{@words}\n", "language" => "en"})

      assert {:ok, @words} = transcribe(ref)
      assert_received :model_called
    end

    test "the journal row is the user's, of the agent, and holds no words", %{
      ref: ref,
      user: user,
      endpoint: endpoint
    } do
      model_hears(%{"text" => @words, "language" => "en"})
      assert {:ok, @words} = transcribe(ref)

      [request] =
        Repo.all(from(r in PhoenixKitAI.Request, where: r.endpoint_uuid == ^endpoint.uuid))

      assert request.user_uuid == user.uuid
      assert request.metadata["source"] == "agent"
      refute inspect(request.metadata) =~ @words
    end

    test "a recording with no speech is :no_speech", %{ref: ref} do
      model_hears(%{"text" => "  ", "language" => nil})
      assert {:error, :no_speech} = transcribe(ref)
    end

    test "an empty recording is :no_speech and the model is not asked", %{ref: ref} do
      model_not_called()
      assert {:error, :no_speech} = transcribe(ref, "")
      refute_received :model_called
    end

    test "a recording over the limit is :too_long and the model is not asked", %{ref: ref} do
      model_not_called()
      assert {:error, :too_long} = transcribe(ref, :binary.copy(<<0>>, Speech.max_bytes() + 1))
      refute_received :model_called
    end

    test "a model that cannot take audio is :unfit", %{ref: ref} do
      _ = speech_endpoint("no")
      model_not_called()

      assert {:error, :unfit} = transcribe(ref)
      refute_received :model_called
    end

    test "a provider that fails is :failed, and nothing of the audio or text is logged", %{
      ref: ref
    } do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => @words}})
      end)

      {result, events} = LogProbe.capture(fn -> transcribe(ref, "SECRET-AUDIO-BYTES") end)

      assert {:error, :failed} = result
      refute Enum.any?(events, &(&1 =~ "SECRET-AUDIO-BYTES" or &1 =~ @words))
    end

    test "money lands in the journal where the user's spending counts it", %{
      ref: ref,
      user: user,
      endpoint: endpoint
    } do
      model_hears(%{"text" => @words, "language" => "en"})
      assert {:ok, _} = transcribe(ref)

      cost = Decimal.new("0.0004")

      Repo.update_all(
        from(r in PhoenixKitAI.Request, where: r.endpoint_uuid == ^endpoint.uuid),
        set: [cost: cost]
      )

      assert %{day_micro_usd: 400} = Spend.for_users([user.uuid])[user.uuid]
    end
  end

  describe "before the paid call" do
    test "no speech model chosen is :speech_off", %{ref: ref} do
      {:ok, _} = Config.put_speech_endpoint(nil, [])
      model_not_called()

      assert {:error, :speech_off} = transcribe(ref)
      refute_received :model_called
    end

    test "a user who may not use the assistant is refused", %{} do
      outsider = user_with(["dashboard"], "outsider")
      {ref, _token} = session_fixture(outsider)
      model_not_called()

      assert {:error, :forbidden} = transcribe(ref)
      refute_received :model_called
    end

    test "a borrowed session is refused", %{ref: ref} do
      model_not_called()

      assert {:error, :impersonated} =
               Speech.transcribe(ref, "audio", "wav", impersonated: true)

      refute_received :model_called
    end

    test "an ended session is refused", %{user: user} do
      {ref, token} = session_fixture(user)
      Auth.delete_user_session_token(token)
      model_not_called()

      assert {:error, :session_gone} = transcribe(ref)
      refute_received :model_called
    end

    test "a user over a limit is refused and nothing is paid", %{ref: ref, user: user} do
      Repo.insert!(%UserSettings{user_uuid: user.uuid, daily_cost_limit_micro_usd: 0})
      model_not_called()

      assert {:error, {:limit_reached, kind}} = transcribe(ref)
      assert kind == :daily_cost
      refute_received :model_called
    end

    test "a linked Telegram chat is a session too, if it holds agent.telegram" do
      user = user_with(["agent", "agent.telegram"], "tg")
      ref = telegram_link_fixture(user, UUIDv7.generate(), 4242)
      model_hears(%{"text" => @words, "language" => "en"})

      assert {:ok, @words} = Speech.transcribe(ref, "ogg-bytes", "ogg", impersonated: false)
    end

    test "a linked chat without agent.telegram is refused" do
      user = user_with(["agent"], "tg-no")
      ref = telegram_link_fixture(user, UUIDv7.generate(), 4243)
      model_not_called()

      assert {:error, :forbidden} =
               Speech.transcribe(ref, "ogg-bytes", "ogg", impersonated: false)

      refute_received :model_called
    end
  end

  describe "the AI module is off" do
    test "is :ai_disabled and the model is not asked", %{ref: ref} do
      {:ok, _} = PhoenixKitAI.disable_system()
      model_not_called()

      assert {:error, :ai_disabled} = transcribe(ref)
      refute_received :model_called
    end
  end

  describe "what the AI module refuses is told as a code" do
    defmodule Refusing do
      @moduledoc false
      def transcribe(_endpoint, _audio, _opts) do
        case Agent.get(:speech_refusal, & &1) do
          :raise -> raise "boom with SECRET-AUDIO"
          :throw -> throw(:SECRET_WORDS)
          answer -> answer
        end
      end
    end

    setup do
      {:ok, _} = Agent.start_link(fn -> nil end, name: :speech_refusal)
      Application.put_env(:phoenix_kit_agent, :speech_ai, Refusing)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :speech_ai) end)
      :ok
    end

    defp refused(ref, answer) do
      Agent.update(:speech_refusal, fn _ -> answer end)
      transcribe(ref)
    end

    test "the guard's and the budget's refusals keep their own codes", %{ref: ref} do
      assert {:error, :budget_exceeded} = refused(ref, {:error, {:budget_exceeded, :global}})
      assert {:error, :task_blocked} = refused(ref, {:error, :task_blocked})
      assert {:error, :task_blocked} = refused(ref, {:error, {:task_blocked, %{}}})

      assert {:error, :task_limit_exceeded} =
               refused(ref, {:error, {:task_limit_exceeded, :user, :requests, :day}})
    end

    test "the provider's refusals keep their own codes", %{ref: ref} do
      assert {:error, :insufficient_credits} = refused(ref, {:error, :insufficient_credits})
      assert {:error, :rate_limited} = refused(ref, {:error, :rate_limited})
      assert {:error, :endpoint_unusable} = refused(ref, {:error, :invalid_api_key})
      assert {:error, :endpoint_unusable} = refused(ref, {:error, :endpoint_not_found})
      assert {:error, :no_provider} = refused(ref, {:error, {:no_provider_for_params, [:a]}})
      assert {:error, :unverified} = refused(ref, {:error, {:model_unverified, [:audio_input]}})
      assert {:error, :unfit} = refused(ref, {:error, {:model_unfit, [:audio_input]}})
    end

    test "the answer that is not the words asked for is :bad_answer", %{ref: ref} do
      assert {:error, :bad_answer} = refused(ref, {:error, {:no_json_in_response, "x"}})
      assert {:error, :bad_answer} = refused(ref, {:error, {:output_truncated, "x"}})
    end

    test "a recording format the model cannot take is :unsupported_format", %{ref: ref} do
      assert {:error, :unsupported_format} = refused(ref, {:error, :unknown_audio_format})
      assert {:error, :unsupported_format} = refused(ref, {:error, :invalid_audio_input})
    end

    test "the size and the silence the AI module found are :too_long and :no_speech", %{ref: ref} do
      assert {:error, :too_long} = refused(ref, {:error, {:audio_too_large, 2, 1}})
      assert {:error, :no_speech} = refused(ref, {:error, :empty_input})
    end

    test "anything else is :failed", %{ref: ref} do
      assert {:error, :failed} = refused(ref, {:error, :nxdomain})
      assert {:error, :failed} = refused(ref, :nonsense)
    end

    test "an exception or a throw is :failed and nothing of it is logged", %{ref: ref} do
      {raised, events} = LogProbe.capture(fn -> refused(ref, :raise) end)
      assert {:error, :failed} = raised
      refute Enum.any?(events, &(&1 =~ "SECRET"))

      {thrown, events} = LogProbe.capture(fn -> refused(ref, :throw) end)
      assert {:error, :failed} = thrown
      refute Enum.any?(events, &(&1 =~ "SECRET"))
    end
  end

  describe "one recognition of a user at a time" do
    defmodule Slow do
      @moduledoc false
      # Says it came in, waits to be let go.
      def transcribe(endpoint, _audio, _opts) do
        test = Agent.get(:speech_slow, & &1)
        send(test, {:endpoint, endpoint})
        send(test, {:in, self()})

        receive do
          :go -> {:ok, %{text: "words", language: "en"}}
        end
      end
    end

    setup do
      test = self()
      {:ok, _} = Agent.start_link(fn -> test end, name: :speech_slow)
      Application.put_env(:phoenix_kit_agent, :speech_ai, Slow)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :speech_ai) end)
      :ok
    end

    defp in_task(ref), do: Task.async(fn -> transcribe(ref) end)

    test "the second waits until the first is done", %{ref: ref} do
      first = in_task(ref)
      assert_receive {:in, pid1}, 2_000

      second = in_task(ref)
      refute_receive {:in, _other}, 300

      send(pid1, :go)
      assert {:ok, "words"} = Task.await(first)

      assert_receive {:in, pid2}, 2_000
      send(pid2, :go)
      assert {:ok, "words"} = Task.await(second)
    end

    test "another user is not kept waiting", %{ref: ref} do
      other = user_with(["agent"], "other-speaker")
      {other_ref, _token} = session_fixture(other)

      first = in_task(ref)
      assert_receive {:in, pid1}, 2_000
      second = in_task(other_ref)
      assert_receive {:in, pid2}, 2_000

      send(pid1, :go)
      send(pid2, :go)
      assert {:ok, "words"} = Task.await(first)
      assert {:ok, "words"} = Task.await(second)
    end

    test "what the wait changed is seen right before the call: the session ended", %{
      ref: ref,
      user: user
    } do
      {late_ref, late_token} = session_fixture(user)

      first = in_task(ref)
      assert_receive {:in, pid1}, 2_000

      second = in_task(late_ref)
      refute_receive {:in, _other}, 300

      Auth.delete_user_session_token(late_token)
      send(pid1, :go)

      assert {:ok, "words"} = Task.await(first)
      assert {:error, :session_gone} = Task.await(second)
      refute_receive {:in, _never}, 300
    end

    test "a caller that gave up while the recognition waited is not paid for", %{ref: ref} do
      first = in_task(ref)
      assert_receive {:in, pid1}, 2_000

      deadline = System.monotonic_time(:millisecond) + 300

      second =
        Task.async(fn ->
          Speech.transcribe(ref, "bytes", "wav", impersonated: false, deadline: deadline)
        end)

      Process.sleep(400)

      send(pid1, :go)
      assert {:ok, "words"} = Task.await(first)
      assert {:error, :abandoned} = Task.await(second)
      refute_receive {:in, _never}, 300
    end

    test "the call is made for the model the limits were checked for, as it is after the wait",
         %{ref: ref, endpoint: first_endpoint} do
      first_uuid = first_endpoint.uuid
      first = in_task(ref)
      assert_receive {:endpoint, ^first_uuid}, 2_000
      assert_receive {:in, pid1}, 2_000

      second = in_task(ref)
      refute_receive {:in, _other}, 300

      other = speech_endpoint()
      send(pid1, :go)
      assert {:ok, "words"} = Task.await(first)

      assert_receive {:endpoint, endpoint}, 2_000
      assert endpoint == other.uuid
      assert_receive {:in, pid2}, 2_000
      send(pid2, :go)
      assert {:ok, "words"} = Task.await(second)
    end

    test "what the wait changed is seen right before the call: the user's limit", %{
      ref: ref,
      user: user
    } do
      first = in_task(ref)
      assert_receive {:in, pid1}, 2_000

      second = in_task(ref)
      refute_receive {:in, _other}, 300

      Repo.insert!(%UserSettings{user_uuid: user.uuid, daily_cost_limit_micro_usd: 0})
      send(pid1, :go)

      assert {:ok, "words"} = Task.await(first)
      assert {:error, {:limit_reached, :daily_cost}} = Task.await(second)
      refute_receive {:in, _never}, 300
    end
  end

  describe "the AI module without transcribe/3" do
    defmodule NoSpeech do
    end

    test "voice is off", %{ref: ref} do
      Application.put_env(:phoenix_kit_agent, :speech_ai, NoSpeech)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :speech_ai) end)

      refute Config.speech?()
      assert {:error, :speech_off} = transcribe(ref)
    end
  end
end
