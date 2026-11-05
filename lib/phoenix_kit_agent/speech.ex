defmodule PhoenixKitAgent.Speech do
  @moduledoc """
  A recording written down for a user of the assistant: a voice message of the
  linked Telegram chat, or a clip of the chat panel's microphone. The text is
  the user's own words, to be sent as a message: this module only recognises,
  it starts no turn and keeps nothing.

  `transcribe/4` is the one door. It answers `{:error, :speech_off}` unless
  `PhoenixKitAgent.Config.speech?/0` (the AI module can write speech down and
  a speech model is chosen on Settings → AI Agent), then, in this order and
  before anything is paid:

    1. the AI module is on;
    2. the session may use the assistant now, as `PhoenixKitAgent.Conversations`
       decides it — a site session that is not borrowed, or a linked Telegram
       chat that is still linked and holds `agent.telegram`; the user is the one
       the session names, never a uuid a client sent;
    3. the recording is not over `max_bytes/0`;
    4. the user's limits (`PhoenixKitAgent.Limits.check/3`, money of the speech
       endpoint as `Models.reports_cost?/2` counts it), under a lock of the
       user's recognitions, so each one sees what the last one cost.

  The session, the AI module, the limits and the chosen model are asked again
  under the lock, right before the call (`check/2`), as the wait for it may have
  been long; the model asked is the one the limits were checked for. With a
  `deadline:` option (`System.monotonic_time(:millisecond)`) a recognition whose
  caller has given up waiting is not paid for: it answers `{:error, :abandoned}`.

  The length of a recording is not known here but for its size: ten megabytes
  are the bound (a few minutes of speech in a compressed format, much more in
  an hour of Opus), and the callers that know a length (Telegram's `duration`)
  refuse a long one before they download it.

  The call is `PhoenixKitAI.transcribe/3` with the user's `user_uuid:`,
  `source: "agent"` and `task: "agent.speech"`, so the journal row is the
  user's and `PhoenixKitAgent.Spend` counts it. The words are not kept in the
  journal (`capture_request_content: false`), and nothing of the audio or the
  text is logged.

  The answer is `{:ok, text}` or `{:error, code}`: `:speech_off`, `:no_speech`
  (the recording holds none), `:too_long`, `:unfit` / `:unverified` (the chosen
  model cannot take audio, or nobody knows), `:no_provider`,
  `:insufficient_credits`, `:rate_limited`, `:endpoint_unusable` (only an
  administrator can end it), `:bad_answer` (billed, but not the shape asked
  for), `:failed`, `:ai_disabled`, `:budget_exceeded`, `:task_blocked`,
  `:task_limit_exceeded`, `{:limit_reached, kind}`, or the refusal of
  `Conversations` (`:forbidden`, `:session_gone`, `:impersonated`, …). The
  texts are `PhoenixKitAgent.Web.Dock.Texts.speech_error/1`.
  """

  require Logger

  alias PhoenixKitAgent.{Config, Conversations, Limits, UserConfig}
  alias PhoenixKitAgent.Schemas.Message
  alias PhoenixKitAgent.Turns.Runner

  @max_bytes 10 * 1_048_576
  @max_seconds 120
  @timeout_ms 60_000

  @guard_refusals ~w(task_blocked task_limit_exceeded)a
  @unsupported_format ~w(unknown_audio_format invalid_audio_input)a

  @typedoc "Why a recording was not written down."
  @type error ::
          :speech_off
          | :no_speech
          | :too_long
          | :unfit
          | :unverified
          | :no_provider
          | :insufficient_credits
          | :rate_limited
          | :endpoint_unusable
          | :bad_answer
          | :unsupported_format
          | :abandoned
          | :failed
          | :ai_disabled
          | :budget_exceeded
          | :task_blocked
          | :task_limit_exceeded
          | {:limit_reached, Limits.kind()}
          | atom()

  @doc "The longest recording taken, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The longest recording taken, in seconds."
  @spec max_seconds() :: pos_integer()
  def max_seconds, do: @max_seconds

  @doc """
  Writes `bytes`, a recording in `format` (`"wav"`, `"ogg"`, …; `nil` where
  the bytes tell it), down for the
  user of `session_ref` (a site session or a linked Telegram chat, see
  `PhoenixKitAgent.Conversations`). `opts` must hold `impersonated:`, as the
  functions of `Conversations` do.
  """
  @spec transcribe(Conversations.session_ref(), binary(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, error()}
  def transcribe(session_ref, bytes, format, opts)
      when is_binary(bytes) and (is_binary(format) or is_nil(format)) do
    with {:ok, user_uuid, _endpoint} <- verify(session_ref, opts),
         :ok <- size_ok(bytes) do
      one_at_a_time(user_uuid, fn -> paid(session_ref, opts, user_uuid, bytes, format) end)
    end
  end

  @doc """
  Everything `transcribe/4` checks before it pays, without paying: voice is on,
  the AI module is on, the session may use the assistant now and the user is
  within their limits. `{:ok, user_uuid}`, or the refusal. A caller that has
  something expensive to do first (the download of a file) asks this before
  it; `transcribe/4` asks it again, and once more under the user's lock.
  """
  @spec check(Conversations.session_ref(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def check(session_ref, opts) do
    with {:ok, user_uuid, _endpoint} <- verify(session_ref, opts), do: {:ok, user_uuid}
  end

  # The user and the model the limits were checked for, which are the ones the
  # call is made for.
  defp verify(session_ref, opts) do
    with :ok <- speech_on(),
         :ok <- ai_enabled(),
         {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts),
         {:ok, endpoint} <- chosen(Config.speech_endpoint_uuid()),
         :ok <- within_limits(user_uuid, endpoint) do
      {:ok, user_uuid, endpoint}
    end
  end

  defp speech_on, do: if(Config.speech?(), do: :ok, else: {:error, :speech_off})

  defp ai_enabled, do: if(PhoenixKitAI.enabled?(), do: :ok, else: {:error, :ai_disabled})

  defp size_ok(bytes), do: if(byte_size(bytes) > @max_bytes, do: {:error, :too_long}, else: :ok)

  # One recognition of a user at a time, on every connected node: the lock is
  # held by this process, and freed when it returns or is killed.
  defp one_at_a_time(user_uuid, fun),
    do: :global.trans({{__MODULE__, :transcribe, user_uuid}, self()}, fun)

  # Right before the call, with the lock held: the wait for it may have been
  # long (another recognition of the user ran), and the session, the limits
  # and the model are what they are now.
  defp paid(session_ref, opts, user_uuid, bytes, format) do
    with :ok <- not_abandoned(opts[:deadline]),
         {:ok, ^user_uuid, endpoint} <- verify(session_ref, opts) do
      ask(endpoint, user_uuid, bytes, format)
    else
      {:ok, _other_user, _endpoint} -> {:error, :session_gone}
      refusal -> refusal
    end
  end

  defp not_abandoned(nil), do: :ok

  defp not_abandoned(deadline),
    do: if(System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :abandoned})

  defp chosen(nil), do: {:error, :speech_off}
  defp chosen(endpoint), do: {:ok, endpoint}

  defp within_limits(user_uuid, endpoint) do
    case Limits.check(UserConfig.effective(user_uuid), endpoint, use: :speech) do
      :ok -> :ok
      {:error, {:limit_reached, status}} -> {:error, {:limit_reached, status.kind}}
    end
  end

  defp ask(endpoint, user_uuid, bytes, format) do
    result =
      Config.speech_ai().transcribe(endpoint, audio(bytes, format),
        user_uuid: user_uuid,
        source: "agent",
        task: "agent.speech",
        max_audio_bytes: @max_bytes,
        timeout: @timeout_ms,
        capture_request_content: false,
        # Never answered from, nor put into, a cache the other users share.
        cache: false
      )

    outcome(result)
  rescue
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] speech recognition failed: #{inspect(exception.__struct__)}"
      )

      {:error, :failed}
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAgent] speech recognition failed: #{kind}")
      {:error, :failed}
  end

  defp audio(bytes, nil), do: %{data: bytes}
  defp audio(bytes, format), do: %{data: bytes, format: format}

  defp outcome({:ok, %{text: text}}) when is_binary(text) do
    case text |> Message.strip_nul() |> String.trim() do
      "" -> {:error, :no_speech}
      words -> {:ok, words}
    end
  end

  defp outcome({:error, :empty_input}), do: {:error, :no_speech}
  defp outcome({:error, {:audio_too_large, _bytes, _max}}), do: {:error, :too_long}
  defp outcome({:error, {:model_unfit, _needs}}), do: {:error, :unfit}
  defp outcome({:error, {:model_unverified, _needs}}), do: {:error, :unverified}
  defp outcome({:error, {:no_provider_for_params, _params}}), do: {:error, :no_provider}
  defp outcome({:error, {:budget_exceeded, _scope}}), do: {:error, :budget_exceeded}

  defp outcome({:error, reason}) when is_tuple(reason) and elem(reason, 0) in @guard_refusals,
    do: {:error, elem(reason, 0)}

  defp outcome({:error, reason}) when reason in @guard_refusals, do: {:error, reason}

  defp outcome({:error, reason}) when reason in @unsupported_format,
    do: {:error, :unsupported_format}

  defp outcome({:error, :insufficient_credits}), do: {:error, :insufficient_credits}
  defp outcome({:error, :rate_limited}), do: {:error, :rate_limited}

  # The errors only an administrator can end, as the chat's turn knows them.
  defp outcome({:error, reason}) when is_atom(reason) do
    if reason in Runner.endpoint_unusable(),
      do: {:error, :endpoint_unusable},
      else: {:error, :failed}
  end

  # The provider answered (and billed) but not in the shape asked for.
  defp outcome({:error, {tag, _text}}) when tag in [:no_json_in_response, :output_truncated],
    do: {:error, :bad_answer}

  defp outcome(_failed), do: {:error, :failed}
end
