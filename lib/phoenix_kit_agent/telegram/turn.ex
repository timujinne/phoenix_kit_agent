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
  be sent. A turn that ended with a change held for the user's confirmation
  says what the assistant said (if it said anything), then sends the card
  (`PhoenixKitAgent.Telegram.Cards`): 👍; when the card could not be sent, one
  message that sends the person to the site, and 🤷. The topic of the
  conversation is subscribed **before** the turn starts, so its end cannot be
  missed; the wait is the turn's deadline plus a minute. If this process dies
  mid-turn (a deploy), the message keeps its 👀 and is not answered.

  A voice message (`:voice` job) is written down first
  (`PhoenixKitAgent.Speech`), before any download: the speech model must be
  set, the chat's link and rights are checked as a text turn's are, and a
  recording of more than two minutes or ten megabytes is refused. The words
  are sent back as "🎙 Recognised: …", and then the turn runs on them exactly as
  on a typed message. When it cannot be written down, the person is told why
  (🤷) and no turn is started.

  A picture (`:photo` job: a photo, or a document that is a jpeg, png or webp)
  is added to the person's Telegram conversation as the chat panel's upload is
  (`PhoenixKitAgent.Attachments.add_picture_for_telegram/3`: the same checks,
  storage, processing and limits; the model sees pixels or a description as
  `Processor.picture_mode/1` says, and a person whose model cannot see and who
  has no vision model is told so). The turn waits, for a bounded time, for the
  picture to be read, and then runs on the caption (or "What is in this
  picture?") with the picture. The pictures of one album are one question: the
  first one waits a moment, takes the others (`ChatQueue.take_siblings/3`), and
  all that could be read go in one message with the first caption there is. A
  picture that is not read, or a turn that is refused, leaves no file behind.

  The job holds the text of the message (the caption, the recording) only
  while it runs; nothing of it is logged.
  """

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Utils.Routes
  use Gettext, backend: PhoenixKitAgent.Gettext

  require Logger

  alias PhoenixKitAgent.{Attachments, Config, Conversations, Speech, Turns, UserConfig}
  alias PhoenixKitAgent.Attachments.Bounds
  alias PhoenixKitAgent.Telegram.{Bridge, Cards, ChatQueue, Client, Format, Texts}

  @typing_every_ms 4_000
  # A file this much older than the longest wait for one is nobody's turn any more.
  @sweep_margin_ms 5_000
  # Keys of the turn's process: the pictures added so far, the last "typing".
  @added :pk_agent_tg_added
  @typed :pk_agent_tg_typed
  @grace_ms 60_000

  @doc "Runs `job` (see `PhoenixKitAgent.Telegram.Bridge`) for the chat `ref` of the bot."
  @spec run(String.t(), Bridge.ref(), map()) :: :ok
  def run(connection_uuid, {:telegram_link, user_uuid, _connection, chat_id} = ref, job) do
    Bridge.safely(fn ->
      Bridge.in_locale(user_uuid, fn locale ->
        case job.kind do
          :new -> new_conversation(connection_uuid, ref, job, user_uuid, chat_id)
          :turn -> converse(connection_uuid, ref, job, user_uuid, chat_id, locale)
          :voice -> voice(connection_uuid, ref, job, user_uuid, chat_id, locale)
          :photo -> photo(connection_uuid, ref, job, user_uuid, chat_id, locale)
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

  # A voice message: written down, shown, and then the turn of what it said.
  # "Typing…" goes on every few seconds while the file is fetched and written
  # down, which may take a minute.
  defp voice(connection_uuid, ref, job, user_uuid, chat_id, locale) do
    Bridge.react(connection_uuid, chat_id, job.message_id, "👀")

    recognised =
      while_typing(connection_uuid, chat_id, fn ->
        with {:ok, bytes} <- recording(connection_uuid, ref, job.voice),
             do: Speech.transcribe(ref, bytes, job.voice.format, impersonated: false)
      end)

    case recognised do
      {:ok, text} ->
        Bridge.say(connection_uuid, chat_id, Texts.recognised(text))

        converse(
          connection_uuid,
          ref,
          %{job | kind: :turn, text: text},
          user_uuid,
          chat_id,
          locale
        )

      {:error, reason} ->
        refuse_with(connection_uuid, chat_id, job.message_id, Texts.speech(reason))
    end
  end

  # Runs `fun` in a task of its own and sends "typing…" every few seconds until
  # it answers. An exception in it is an error of the recognition.
  defp while_typing(connection_uuid, chat_id, fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          exception ->
            Logger.warning(
              "[PhoenixKitAgent] telegram recognition failed: #{inspect(exception.__struct__)}"
            )

            {:error, :failed}
        catch
          kind, _reason ->
            Logger.warning("[PhoenixKitAgent] telegram recognition failed: #{kind}")
            {:error, :failed}
        end
      end)

    await_typing(task, connection_uuid, chat_id)
  end

  defp await_typing(task, connection_uuid, chat_id) do
    _ = Client.impl().typing(connection_uuid, chat_id)

    case Task.yield(task, typing_every_ms()) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :failed}
      nil -> await_typing(task, connection_uuid, chat_id)
    end
  end

  # The recording, once the person is known to be allowed to ask for it, to be
  # within their limits, and it is no longer or larger than a recognition takes:
  # the download is the expensive step. A voice message that names no length is
  # held to the size alone (`Speech.max_bytes/0`).
  defp recording(connection_uuid, ref, voice) do
    with {:ok, _user_uuid} <- Speech.check(ref, impersonated: false),
         :ok <- within_bounds(voice) do
      download(connection_uuid, voice.file_id)
    end
  end

  defp within_bounds(%{duration: duration, size: size}) do
    if too?(duration, Speech.max_seconds()) or too?(size, Speech.max_bytes()),
      do: {:error, :too_long},
      else: :ok
  end

  defp too?(value, max), do: is_integer(value) and value > max

  defp download(connection_uuid, file_id) do
    case fetch(connection_uuid, file_id, Speech.max_bytes()) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :too_large} -> {:error, :too_long}
      {:error, :unavailable} -> {:error, :voice_unavailable}
      {:error, :failed} -> {:error, :download_failed}
    end
  end

  # The file from Telegram, within `max_bytes`.
  defp fetch(connection_uuid, file_id, max_bytes) do
    case Client.impl().download_file(connection_uuid, file_id,
           max_bytes: max_bytes,
           deadline_ms: download_deadline_ms()
         ) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:error, {:file_too_large, _size, _max}} -> {:error, :too_large}
      {:error, :unavailable} -> {:error, :unavailable}
      _failed -> {:error, :failed}
    end
  end

  defp download_deadline_ms,
    do: Application.get_env(:phoenix_kit_agent, :telegram_download_deadline_ms, 30_000)

  defp converse(connection_uuid, ref, job, user_uuid, chat_id, locale) do
    case current_conversation(user_uuid, ref) do
      {:ok, conversation} ->
        with_topic(conversation, fn ->
          Bridge.react(connection_uuid, chat_id, job.message_id, "👀")
          start_turn(connection_uuid, ref, job.message_id, conversation, job.text, [], locale)
        end)

      {:error, _changeset} ->
        refuse(connection_uuid, chat_id, job.message_id, :not_found)
    end
  end

  # The conversation's topic is subscribed **before** anything starts, so the
  # end of its turn cannot be missed.
  defp with_topic(conversation, fun) do
    topic = Conversations.topic(conversation.uuid)
    :ok = PubSub.subscribe(topic)

    try do
      fun.()
    after
      PubSub.unsubscribe(topic)
    end
  end

  # The turn, and its answer in the chat. A turn that is refused leaves the
  # pictures it was to carry nowhere (`attachments`, uuids).
  defp start_turn(connection_uuid, ref, message_id, conversation, text, attachments, locale) do
    start = Turns.start(ref, false, conversation.uuid, text, attachments, options(locale))
    if match?({:error, _reason}, start), do: discard(ref, attachments)
    outcome(connection_uuid, ref, message_id, conversation, start)
  end

  # ── pictures ────────────────────────────────────────────────────────

  # The leader of an album waits a moment for the rest of it. The chat is
  # checked first (before "👀"); a refusal is told once for the whole album.
  defp photo(connection_uuid, ref, job, user_uuid, chat_id, locale) do
    with {:ok, _user_uuid} <- Conversations.authorize_session(ref, impersonated: false),
         {:ok, conversation} <- current_conversation(user_uuid, ref) do
      Bridge.react(connection_uuid, chat_id, job.message_id, "👀")
      _ = Client.impl().typing(connection_uuid, chat_id)
      jobs = [job | siblings(connection_uuid, chat_id, job)]

      with_topic(conversation, fn ->
        picture_turn(connection_uuid, ref, job.message_id, conversation, jobs, locale)
      end)
    else
      {:error, reason} ->
        _ = siblings(connection_uuid, chat_id, job)
        refuse_with(connection_uuid, chat_id, job.message_id, picture_text(reason))
    end
  end

  defp siblings(connection_uuid, chat_id, %{group: group}) when is_binary(group) do
    Process.sleep(album_settle_ms())
    for {_ref, sibling} <- ChatQueue.take_siblings(connection_uuid, chat_id, group), do: sibling
  end

  defp siblings(_connection_uuid, _chat_id, _job), do: []

  # The pictures, one at a time (each read before the next is added, so the
  # places for describing them are free in turn), up to what a message takes;
  # what is left out is told once. Whatever was added and no message took is
  # removed, whatever ends the turn (a turn that is killed outright is swept by
  # the next picture of the chat).
  defp picture_turn(connection_uuid, ref, message_id, conversation, jobs, locale) do
    chat_id = elem(ref, 3)
    {taken, over} = Enum.split(jobs, max_pictures(ref))

    _ =
      Attachments.sweep_unsent_for_telegram(
        ref,
        conversation.uuid,
        attachment_wait_ms() + @sweep_margin_ms
      )

    Process.put(@added, [])

    try do
      {ready, errors} = attach_all(connection_uuid, ref, conversation, taken)

      case ready do
        [] ->
          reason = if taken == [], do: :too_many, else: first_error(errors)
          refuse_with(connection_uuid, chat_id, message_id, picture_text(reason))

        ready ->
          unless over == [] and errors == [] do
            Bridge.say(
              connection_uuid,
              chat_id,
              left_out(length(jobs), length(ready), over, taken)
            )
          end

          text = caption(taken) || default_prompt(length(ready))
          start_turn(connection_uuid, ref, message_id, conversation, text, ready, locale)
      end
    after
      discard(ref, Process.delete(@added) || [])
    end
  end

  defp max_pictures(ref) do
    {:telegram_link, user_uuid, _connection, _chat} = ref
    UserConfig.effective(user_uuid).max_attachments_per_message
  end

  # One short message: how many pictures were taken, and how many could not be.
  defp left_out(total, taken_count, over, taken) do
    unread = length(taken) - taken_count

    [
      if(over != [],
        do:
          gettext(
            "Pictures taken: %{taken} of %{total} (a message takes at most %{max}).",
            taken: taken_count,
            total: total,
            max: length(taken)
          )
      ),
      if(unread > 0, do: gettext("Pictures that could not be read: %{count}.", count: unread))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # Every picture, one by one, added and read before the next: `{uuids of the
  # ones ready, error codes of the others}`. The wait for all of them together
  # is bounded; the ones the bound cuts off are errors.
  defp attach_all(connection_uuid, ref, conversation, jobs) do
    deadline = System.monotonic_time(:millisecond) + attachment_wait_ms()

    {ready, errors} =
      Enum.reduce(jobs, {[], []}, fn job, {ready, errors} ->
        case one_picture(connection_uuid, ref, conversation, job.photo, deadline) do
          {:ok, uuid} -> {[uuid | ready], errors}
          {:error, reason} -> {ready, [reason | errors]}
        end
      end)

    {Enum.reverse(ready), Enum.reverse(errors)}
  end

  defp one_picture(connection_uuid, ref, conversation, photo, deadline) do
    keep_typing(connection_uuid, elem(ref, 3))

    if System.monotonic_time(:millisecond) >= deadline do
      {:error, "timeout"}
    else
      with {:ok, attachment} <- attach(connection_uuid, ref, conversation, photo) do
        Process.put(@added, [attachment.uuid | Process.get(@added, [])])

        case settle(connection_uuid, ref, [attachment.uuid], deadline) do
          {[uuid], _errors} ->
            {:ok, uuid}

          {[], [error | _]} ->
            discard(ref, [attachment.uuid])
            {:error, error}
        end
      end
    end
  end

  # What can be known without the file is asked before it is downloaded.
  defp attach(connection_uuid, ref, conversation, photo) do
    max = Bridge.max_picture_bytes()

    with :ok <- if(too?(photo.size, max), do: {:error, :too_large}, else: :ok),
         :ok <- Attachments.precheck_picture_for_telegram(ref, conversation.uuid, photo.size),
         {:ok, bytes} <- fetch(connection_uuid, photo.file_id, max) |> picture_error(),
         do: Attachments.add_picture_for_telegram(ref, conversation.uuid, bytes)
  end

  defp picture_error({:error, :failed}), do: {:error, :download_failed}
  defp picture_error(other), do: other

  # Until the pictures are read or have failed, or the deadline is past (one
  # still unread then has failed). `{ready uuids, error codes of the others}`.
  defp settle(connection_uuid, ref, uuids, deadline) do
    rows =
      Enum.map(uuids, fn uuid ->
        case Attachments.get_for_telegram(ref, uuid) do
          {:ok, row} -> row
          {:error, _gone} -> %{uuid: uuid, status: "failed", error: "unreadable"}
        end
      end)

    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      Enum.all?(rows, &(&1.status in ["ready", "failed"])) -> split(rows)
      remaining <= 0 -> split(Enum.map(rows, &timed_out/1))
      true -> wait_for_reading(connection_uuid, ref, uuids, deadline, min(remaining, tick_ms()))
    end
  end

  defp wait_for_reading(connection_uuid, ref, uuids, deadline, ms) do
    keep_typing(connection_uuid, elem(ref, 3))

    receive do
      {:agent_attachment_processed, _conversation_uuid, _attachment_uuid} ->
        settle(connection_uuid, ref, uuids, deadline)
    after
      ms -> settle(connection_uuid, ref, uuids, deadline)
    end
  end

  # How often a picture still being read is looked at.
  defp tick_ms, do: min(1_000, typing_every_ms())

  # "Typing…" again once the last one is old enough.
  defp keep_typing(connection_uuid, chat_id) do
    now = System.monotonic_time(:millisecond)

    if now - Process.get(@typed, now - typing_every_ms()) >= typing_every_ms() do
      Process.put(@typed, now)
      _ = Client.impl().typing(connection_uuid, chat_id)
    end

    :ok
  end

  defp timed_out(%{status: "pending"} = row), do: %{row | status: "failed", error: "timeout"}
  defp timed_out(row), do: row

  defp split(rows) do
    {for(%{status: "ready"} = row <- rows, do: row.uuid),
     for(%{status: "failed"} = row <- rows, do: row.error || "unreadable")}
  end

  defp discard(ref, uuids), do: Enum.each(uuids, &Attachments.discard_for_telegram(ref, &1))

  defp caption(jobs) do
    Enum.find_value(jobs, fn job ->
      text = job.text
      if is_binary(text) and String.trim(text) != "", do: text
    end)
  end

  defp default_prompt(1), do: gettext("What is in this picture?")
  defp default_prompt(_several), do: gettext("What is in these pictures?")

  defp first_error([reason | _rest]), do: reason
  defp first_error([]), do: :file_unreadable

  # An error code of a row, or the refusal of `Attachments` / `Conversations`.
  defp picture_text(code) when is_binary(code), do: Texts.attachment_error(code)
  defp picture_text(reason), do: Texts.picture(reason)

  defp attachment_wait_ms do
    Application.get_env(:phoenix_kit_agent, :telegram_attachment_wait_ms) ||
      Bounds.get(:queue_wait_ms) + Bounds.get(:process_deadline_ms) + 10_000
  end

  defp album_settle_ms,
    do: Application.get_env(:phoenix_kit_agent, :telegram_album_settle_ms, 1_000)

  defp options(locale) do
    [locale: locale, request_context: [language: locale, base_url: Routes.base_url()]]
  end

  defp current_conversation(user_uuid, ref) do
    case Conversations.latest_telegram_conversation(user_uuid) do
      %{metadata: %{"chat_id" => stored}} = conversation ->
        if to_string(stored) == to_string(elem(ref, 3)),
          do: {:ok, conversation},
          else: start_conversation(user_uuid, ref)

      _none_or_unmarked ->
        start_conversation(user_uuid, ref)
    end
  end

  defp start_conversation(user_uuid, {:telegram_link, _user, _connection, chat_id}) do
    Conversations.create_conversation_for(user_uuid,
      metadata: %{"source" => "telegram", "chat_id" => chat_id}
    )
  end

  defp outcome(
         connection_uuid,
         {:telegram_link, _user, _connection, chat_id} = ref,
         message_id,
         conversation,
         {:ok, turn_ref}
       ) do
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

      {:needs_confirmation, text, card} ->
        held(connection_uuid, ref, message_id, conversation, turn_ref, {text, card})

      {:notice, code} ->
        refuse_with(connection_uuid, chat_id, message_id, Texts.notice(code))

      :none ->
        refuse_with(connection_uuid, chat_id, message_id, Texts.notice("deadline"))
    end
  end

  defp outcome(
         connection_uuid,
         {:telegram_link, _user, _connection, chat_id},
         message_id,
         _conversation,
         {:error, reason}
       ),
       do: refuse(connection_uuid, chat_id, message_id, reason)

  # The turn ended with a change held for the user: what the assistant said,
  # then the card with its buttons, and 👍. A card Telegram would not take is
  # one message that sends the person to the site (🤷); the change waits there.
  # An error that ended the turn after the hold is told in a message of its own.
  defp held(connection_uuid, ref, message_id, conversation, turn_ref, {text, card}) do
    {:telegram_link, _user, _connection, chat_id} = ref
    if text, do: say_plain(connection_uuid, chat_id, text)

    emoji =
      case Cards.deliver(connection_uuid, ref, conversation.uuid, card) do
        :ok ->
          "👍"

        :error ->
          Bridge.say(connection_uuid, chat_id, Texts.static(:card_not_shown))
          "🤷"
      end

    case Conversations.turn_error(conversation.uuid, turn_ref) do
      nil -> :ok
      code -> Bridge.say(connection_uuid, chat_id, Texts.notice(code))
    end

    Bridge.react(connection_uuid, chat_id, message_id, emoji)
  end

  defp say_plain(connection_uuid, chat_id, text) do
    case Format.plain(text) do
      "" -> :ok
      plain -> Bridge.say(connection_uuid, chat_id, plain)
    end
  end

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
