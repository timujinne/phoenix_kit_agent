defmodule PhoenixKitAgent.Telegram.Turn do
  @moduledoc """
  One message of a linked chat, carried through the agent: the person's
  current Telegram conversation (or a new one), the turn, and the answer in
  the chat. The turn is the person's own: their model, limits, instructions
  and spending (`PhoenixKitAgent.Turns.start/6` with the chat reference).

  The reaction tells how it went: 👀 while the agent works (with "typing…"
  every 4 seconds), then 👍 with the answer, or 🤷 with a short explanation
  when the turn was refused, ended in a notice, asked for a change the chat
  may not make (a tool of the turn was denied) or when the answer could not
  be sent. The topic of the
  conversation is subscribed **before** the turn starts, so its end cannot be
  missed; the wait is the turn's deadline plus a minute. If this process dies
  mid-turn (a deploy), the message keeps its 👀 and is not answered.

  The job holds the text of the message only while it runs; nothing of it
  is logged.
  """

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAgent.{Config, Conversations, Turns}
  alias PhoenixKitAgent.Telegram.{Bridge, Client, Format, Texts}

  @typing_every_ms 4_000
  @grace_ms 60_000

  @doc "Runs `job` (see `PhoenixKitAgent.Telegram.Bridge`) for the chat `ref` of the bot."
  @spec run(String.t(), Bridge.ref(), map()) :: :ok
  def run(connection_uuid, {:telegram_link, user_uuid, _connection, chat_id} = ref, job) do
    Bridge.safely(fn ->
      Bridge.in_locale(user_uuid, fn locale ->
        case job.kind do
          :new -> new_conversation(connection_uuid, ref, job, user_uuid, chat_id)
          :turn -> converse(connection_uuid, ref, job, user_uuid, chat_id, locale)
        end
      end)
    end)
  end

  defp new_conversation(connection_uuid, ref, job, user_uuid, chat_id) do
    case start_conversation(user_uuid, ref) do
      {:ok, _conversation} ->
        reply(connection_uuid, chat_id, job.message_id, Texts.static(:new_started))

      {:error, _changeset} ->
        refuse(connection_uuid, chat_id, job.message_id, :not_found)
    end
  end

  defp converse(connection_uuid, ref, job, user_uuid, chat_id, locale) do
    case current_conversation(user_uuid, ref) do
      {:ok, conversation} ->
        topic = Conversations.topic(conversation.uuid)
        :ok = PubSub.subscribe(topic)

        try do
          Bridge.react(connection_uuid, chat_id, job.message_id, "👀")
          start = Turns.start(ref, false, conversation.uuid, job.text, [], options(locale))
          outcome(connection_uuid, chat_id, job.message_id, conversation, start)
        after
          PubSub.unsubscribe(topic)
        end

      {:error, _changeset} ->
        refuse(connection_uuid, chat_id, job.message_id, :not_found)
    end
  end

  defp options(locale) do
    [locale: locale, request_context: [language: locale, base_url: Routes.base_url()]]
  end

  defp current_conversation(user_uuid, ref) do
    case Conversations.latest_telegram_conversation(user_uuid) do
      nil -> start_conversation(user_uuid, ref)
      conversation -> {:ok, conversation}
    end
  end

  defp start_conversation(user_uuid, {:telegram_link, _user, _connection, chat_id}) do
    Conversations.create_conversation_for(user_uuid,
      metadata: %{"source" => "telegram", "chat_id" => chat_id}
    )
  end

  defp outcome(connection_uuid, chat_id, message_id, conversation, {:ok, turn_ref}) do
    await(connection_uuid, chat_id, conversation.uuid, turn_ref)

    case Conversations.turn_result(conversation.uuid, turn_ref) do
      {:answer, text} ->
        answer(
          connection_uuid,
          chat_id,
          message_id,
          text,
          not Conversations.turn_denied?(conversation.uuid, turn_ref)
        )

      {:notice, code} ->
        refuse_with(connection_uuid, chat_id, message_id, Texts.notice(code))

      :none ->
        refuse_with(connection_uuid, chat_id, message_id, Texts.notice("deadline"))
    end
  end

  defp outcome(connection_uuid, chat_id, message_id, _conversation, {:error, reason}),
    do: refuse(connection_uuid, chat_id, message_id, reason)

  # "Typing…" every 4 seconds until the turn says it is over, or gives up
  # one minute after the turn's own deadline.
  defp await(connection_uuid, chat_id, conversation_uuid, turn_ref) do
    deadline = System.monotonic_time(:millisecond) + wait_ms()
    wait(connection_uuid, chat_id, conversation_uuid, turn_ref, deadline)
  end

  defp wait(connection_uuid, chat_id, conversation_uuid, turn_ref, deadline) do
    _ = Client.impl().typing(connection_uuid, chat_id)
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {:agent_turn_finished, ^conversation_uuid, ^turn_ref} ->
          :finished
      after
        min(typing_every_ms(), remaining) ->
          wait(connection_uuid, chat_id, conversation_uuid, turn_ref, deadline)
      end
    else
      :timeout
    end
  end

  # 👍 only for an answer that was sent, and that is not "I cannot do that
  # here" (the turn asked for a change the chat is not allowed): that is 🤷,
  # with the text the model said (it points to the site).
  defp answer(connection_uuid, chat_id, message_id, text, fulfilled?) do
    case Format.plain(text) do
      "" -> refuse_with(connection_uuid, chat_id, message_id, Texts.notice("empty_answer"))
      plain -> reply(connection_uuid, chat_id, message_id, plain, fulfilled?)
    end
  end

  defp reply(connection_uuid, chat_id, message_id, text, fulfilled? \\ true) do
    emoji =
      if Bridge.say(connection_uuid, chat_id, text) == :ok and fulfilled?, do: "👍", else: "🤷"

    Bridge.react(connection_uuid, chat_id, message_id, emoji)
  end

  defp refuse(connection_uuid, chat_id, message_id, reason),
    do: refuse_with(connection_uuid, chat_id, message_id, Texts.refusal(reason))

  defp refuse_with(connection_uuid, chat_id, message_id, text),
    do: reply(connection_uuid, chat_id, message_id, text, false)

  # The turn's own deadline and a minute more; `:telegram_turn_wait_ms` stands
  # in for it in tests.
  defp wait_ms do
    Application.get_env(:phoenix_kit_agent, :telegram_turn_wait_ms) ||
      Config.turn_deadline_s() * 1_000 + @grace_ms
  end

  defp typing_every_ms,
    do: Application.get_env(:phoenix_kit_agent, :telegram_typing_every_ms, @typing_every_ms)
end
