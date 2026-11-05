defmodule PhoenixKitAgent.Telegram.ConversationsCardsTest do
  @moduledoc """
  What `PhoenixKitAgent.Conversations` keeps and says for the cards of a chat
  from Telegram: how a turn that held a change is read (`turn_result/2`,
  `turn_error/2`) and where each card was sent (`put_telegram_card/6`,
  `telegram_card/2`).
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKitAgent.Conversations
  alias PhoenixKitAgent.Schemas.{Conversation, Message}

  @connection "0192f3a4-7b1c-7d2e-8f3a-000000000001"
  @chat 428_897_538

  setup do
    user = user_fixture("cards")
    chat = conversation_fixture(user, %{metadata: %{"source" => "telegram", "chat_id" => @chat}})
    %{user: user, chat: chat}
  end

  defp insert(chat, attrs) do
    Repo.insert!(
      struct!(Message, Map.merge(%{conversation_uuid: chat.uuid, content: "x"}, attrs))
    )
  end

  describe "turn_result/2" do
    test "a turn that held a change: the last text the assistant said, and the card", ctx do
      uuid = UUIDv7.generate()
      insert(ctx.chat, %{role: "user", turn_ref: "t1", content: "Rename"})
      insert(ctx.chat, %{role: "assistant", turn_ref: "t1", content: "First thought."})

      insert(ctx.chat, %{
        role: "assistant",
        turn_ref: "t1",
        content: "I will rename it.",
        tool_calls: [%{"id" => "w1", "name" => "x"}]
      })

      insert(ctx.chat, %{
        role: "tool",
        turn_ref: "t1",
        tool_name: "x",
        tool_call_id: "w1",
        tool_outcome: "needs_confirmation",
        confirmation_uuid: uuid
      })

      assert {:needs_confirmation, "I will rename it.",
              %Message{confirmation_uuid: ^uuid, tool_name: "x"}} =
               Conversations.turn_result(ctx.chat.uuid, "t1")
    end

    test "without any text the assistant said there is only the card", ctx do
      uuid = UUIDv7.generate()

      insert(ctx.chat, %{
        role: "assistant",
        turn_ref: "t1",
        content: nil,
        tool_calls: [%{"id" => "w1"}]
      })

      insert(ctx.chat, %{
        role: "tool",
        turn_ref: "t1",
        tool_outcome: "needs_confirmation",
        confirmation_uuid: uuid
      })

      assert {:needs_confirmation, nil, %Message{confirmation_uuid: ^uuid}} =
               Conversations.turn_result(ctx.chat.uuid, "t1")
    end

    test "only the card of this turn counts, and a settled turn without one is as before", ctx do
      insert(ctx.chat, %{
        role: "tool",
        turn_ref: "t0",
        tool_outcome: "needs_confirmation",
        confirmation_uuid: UUIDv7.generate()
      })

      insert(ctx.chat, %{role: "assistant", turn_ref: "t1", content: "Plain answer."})

      assert {:answer, "Plain answer."} = Conversations.turn_result(ctx.chat.uuid, "t1")
    end

    test "an error notice after the hold is told apart by turn_error/2", ctx do
      insert(ctx.chat, %{
        role: "tool",
        turn_ref: "t1",
        tool_outcome: "needs_confirmation",
        confirmation_uuid: UUIDv7.generate()
      })

      insert(ctx.chat, %{role: "notice", turn_ref: "t1", error: "model_error"})

      assert {:needs_confirmation, nil, _card} = Conversations.turn_result(ctx.chat.uuid, "t1")
      assert Conversations.turn_error(ctx.chat.uuid, "t1") == "model_error"
      assert Conversations.turn_error(ctx.chat.uuid, "t2") == nil
      assert Conversations.turn_error("junk", "t1") == nil
    end
  end

  describe "the place of a card" do
    defp card_uuid, do: UUIDv7.generate()

    test "is kept and read back as {bot, chat, message}", ctx do
      uuid = card_uuid()
      assert :ok = Conversations.put_telegram_card(ctx.chat.uuid, uuid, @connection, @chat, 77)

      chat = Repo.get!(Conversation, ctx.chat.uuid)
      assert Conversations.telegram_card(chat, uuid) == {@connection, @chat, 77}
      assert Conversations.telegram_card(chat, card_uuid()) == nil
      # What else the metadata holds stays.
      assert chat.metadata["source"] == "telegram"
      assert chat.metadata["chat_id"] == @chat
    end

    test "with keep: true a place that is kept stays; without it the newer one replaces it",
         ctx do
      uuid = card_uuid()
      :ok = Conversations.put_telegram_card(ctx.chat.uuid, uuid, @connection, @chat, 1)

      :ok =
        Conversations.put_telegram_card(ctx.chat.uuid, uuid, @connection, @chat, 2, keep: true)

      assert Conversations.telegram_card(Repo.get!(Conversation, ctx.chat.uuid), uuid) ==
               {@connection, @chat, 1}

      :ok = Conversations.put_telegram_card(ctx.chat.uuid, uuid, @connection, @chat, 3)

      assert Conversations.telegram_card(Repo.get!(Conversation, ctx.chat.uuid), uuid) ==
               {@connection, @chat, 3}
    end

    test "only the newest fifty are kept", ctx do
      uuids = for _ <- 1..55, do: card_uuid()

      for {uuid, n} <- Enum.with_index(uuids) do
        :ok = Conversations.put_telegram_card(ctx.chat.uuid, uuid, @connection, @chat, n)
        Process.sleep(2)
      end

      chat = Repo.get!(Conversation, ctx.chat.uuid)
      assert map_size(chat.metadata["telegram_cards"]) == 50
      assert Conversations.telegram_card(chat, List.last(uuids)) != nil
      assert Conversations.telegram_card(chat, hd(uuids)) == nil
    end

    test "cards stored at the same moment do not lose one another", ctx do
      uuids = for _ <- 1..20, do: card_uuid()

      uuids
      |> Enum.with_index()
      |> Task.async_stream(
        fn {uuid, n} ->
          Conversations.put_telegram_card(ctx.chat.uuid, uuid, @connection, @chat, n)
        end,
        max_concurrency: 10
      )
      |> Enum.each(fn {:ok, result} -> assert result == :ok end)

      chat = Repo.get!(Conversation, ctx.chat.uuid)
      assert Enum.all?(uuids, &Conversations.telegram_card(chat, &1))
    end

    test "a chat that is not there, or a bad uuid, is not found", ctx do
      assert {:error, :not_found} =
               Conversations.put_telegram_card(
                 UUIDv7.generate(),
                 card_uuid(),
                 @connection,
                 @chat,
                 1
               )

      assert {:error, :not_found} =
               Conversations.put_telegram_card("junk", card_uuid(), @connection, @chat, 1)

      assert {:error, :not_found} =
               Conversations.put_telegram_card(ctx.chat.uuid, "junk", @connection, @chat, 1)
    end
  end
end
