defmodule PhoenixKitAgent.Telegram.Turn do
  @moduledoc """
  One message of a linked chat, carried through the agent: the person's
  current Telegram conversation (or a new one), the turn, and the answer in
  the chat. The turn is the person's own: their model, limits, instructions
  and spending (`PhoenixKitAgent.Turns.start/6` with the chat reference).

  The reaction tells how it went: 👀 while the agent works (with "typing…"
  every 4 seconds), then 👍 with the answer, or 🤷 with a short explanation
  when the turn was refused or ended in a notice. The topic of the
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
        Bridge.say(connection_uuid, chat_id, Texts.static(:new_started))
        Bridge.react(connection_uuid, chat_id, job.message_id, "👍")

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

    answer(
      connection_uuid,
      chat_id,
      message_id,
      Conversations.turn_result(conversation.uuid, turn_ref)
    )
  end

  defp outcome(connection_uuid, chat_id, message_id, _conversation, {:error, reason}),
    do: refuse(connection_uuid, chat_id, message_id, reason)

  # "Typing…" every 4 seconds until the turn says it is over, or gives up
  # one minute after the turn's own deadline.
  defp await(connection_uuid, chat_id, conversation_uuid, turn_ref) do
    deadline = System.monotonic_time(:millisecond) + Config.turn_deadline_s() * 1_000 + @grace_ms
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

  defp answer(connection_uuid, chat_id, message_id, {:answer, text}) do
    case Format.plain(text) do
      "" ->
        refuse_with(connection_uuid, chat_id, message_id, Texts.notice("empty_answer"))

      plain ->
        Bridge.say(connection_uuid, chat_id, plain)
        Bridge.react(connection_uuid, chat_id, message_id, "👍")
    end
  end

  defp answer(connection_uuid, chat_id, message_id, {:notice, code}),
    do: refuse_with(connection_uuid, chat_id, message_id, Texts.notice(code))

  defp answer(connection_uuid, chat_id, message_id, :none),
    do: refuse_with(connection_uuid, chat_id, message_id, Texts.notice("deadline"))

  defp refuse(connection_uuid, chat_id, message_id, reason),
    do: refuse_with(connection_uuid, chat_id, message_id, Texts.refusal(reason))

  defp refuse_with(connection_uuid, chat_id, message_id, text) do
    Bridge.say(connection_uuid, chat_id, text)
    Bridge.react(connection_uuid, chat_id, message_id, "🤷")
  end

  defp typing_every_ms,
    do: Application.get_env(:phoenix_kit_agent, :telegram_typing_every_ms, @typing_every_ms)
end
