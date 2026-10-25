defmodule PhoenixKitAgent.ConversationsTest do
  @moduledoc """
  The chat context (spec §5.1-5.2, §8, §10): every operation acts as a live
  session (`SessionRef`) and an impersonation flag, never as a bare user uuid,
  and only the owner of a chat reads or writes it.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitAgent.Conversations
  alias PhoenixKitAgent.Schemas.{Conversation, Message, UserSettings}

  @me [impersonated: false]

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    :ok
  end

  # A user who holds `agent`, with a live session.
  defp member(tag \\ "member") do
    user = user_with(["agent"], tag)
    {ref, token} = session_fixture(user)
    %{user: user, ref: ref, token: token}
  end

  defp chat_count, do: Repo.aggregate(Conversation, :count)
  defp message_count, do: Repo.aggregate(Message, :count)

  defp new_chat!(ref, attrs \\ %{}) do
    {:ok, conversation} = Conversations.create_conversation(ref, attrs, @me)
    conversation
  end

  defp say!(ref, conversation, content) do
    {:ok, message} = Conversations.add_message(ref, conversation.uuid, %{content: content}, @me)
    message
  end

  # A message the turn loop writes (any role, every field), as `Turns` does.
  defp turn_say!(conversation, attrs) do
    {:ok, message} =
      Conversations.add_turn_message(conversation.user_uuid, conversation.uuid, attrs)

    message
  end

  defp titles(ref) do
    {:ok, %{conversations: list}} = Conversations.list_conversations(ref, @me)
    Enum.map(list, & &1.title)
  end

  defp uuids(list), do: MapSet.new(list, & &1.uuid)

  defp collect(ref, cursor, acc) do
    {:ok, %{conversations: list, next_cursor: next}} =
      Conversations.list_conversations(ref, @me ++ [limit: 2, cursor: cursor])

    acc = acc ++ Enum.map(list, & &1.uuid)
    if next, do: collect(ref, next, acc), else: acc
  end

  # Every operation of the context, for the tests that must hold for all of
  # them. `chat_uuid` is the chat the operations that take one aim at.
  defp operations(chat_uuid) do
    [
      list: fn ref, opts -> Conversations.list_conversations(ref, opts) end,
      create: fn ref, opts -> Conversations.create_conversation(ref, %{}, opts) end,
      get: fn ref, opts -> Conversations.get_conversation(ref, chat_uuid, opts) end,
      get_message: fn ref, opts ->
        Conversations.get_message(ref, chat_uuid, Ecto.UUID.generate(), opts)
      end,
      list_messages: fn ref, opts -> Conversations.list_messages(ref, chat_uuid, opts) end,
      rename: fn ref, opts -> Conversations.rename_conversation(ref, chat_uuid, "New", opts) end,
      archive: fn ref, opts -> Conversations.archive_conversation(ref, chat_uuid, opts) end,
      delete: fn ref, opts -> Conversations.delete_conversation(ref, chat_uuid, opts) end,
      add_message: fn ref, opts ->
        Conversations.add_message(ref, chat_uuid, %{role: "user", content: "hi"}, opts)
      end,
      subscribe: fn ref, opts -> Conversations.subscribe(ref, chat_uuid, opts) end
    ]
  end

  describe "creating a chat" do
    test "makes an active chat owned by the session's user" do
      %{user: user, ref: ref} = member()

      assert {:ok, %Conversation{} = chat} = Conversations.create_conversation(ref, %{}, @me)

      assert chat.user_uuid == user.uuid
      assert chat.status == "active"
      assert chat.message_count == 0
      assert %DateTime{} = chat.last_message_at
    end

    test "takes a title, and cannot be told another owner or status" do
      %{user: user, ref: ref} = member()
      other = user_fixture("other")

      {:ok, chat} =
        Conversations.create_conversation(
          ref,
          %{title: "Orders", user_uuid: other.uuid, status: "deleted", message_count: 99},
          @me
        )

      assert chat.title == "Orders"
      assert chat.user_uuid == user.uuid
      assert chat.status == "active"
      assert chat.message_count == 0
    end

    test "trims the title, and takes it under a string key too" do
      %{ref: ref} = member()

      assert {:ok, %Conversation{title: "Orders"}} =
               Conversations.create_conversation(ref, %{title: "  Orders  "}, @me)

      assert {:ok, %Conversation{title: "Sofas"}} =
               Conversations.create_conversation(ref, %{"title" => " Sofas"}, @me)

      assert {:ok, %Conversation{title: "Atom"}} =
               Conversations.create_conversation(
                 ref,
                 %{:title => "Atom", "title" => "String"},
                 @me
               )

      assert {:ok, %Conversation{title: nil}} =
               Conversations.create_conversation(ref, %{title: "   "}, @me)
    end

    test "refuses a title over the limit" do
      %{ref: ref} = member()

      assert {:error, %Ecto.Changeset{}} =
               Conversations.create_conversation(ref, %{title: String.duplicate("a", 201)}, @me)
    end
  end

  describe "the list of chats" do
    test "shows the newest first, by the last message" do
      %{ref: ref} = member()
      first = new_chat!(ref, %{title: "first"})
      new_chat!(ref, %{title: "second"})
      new_chat!(ref, %{title: "third"})

      assert titles(ref) == ["third", "second", "first"]

      # a message moves a chat to the top
      say!(ref, first, "hello")
      assert titles(ref) == ["first", "third", "second"]
    end

    test "gives 20 chats and a cursor for more, then the rest" do
      %{ref: ref} = member()
      for n <- 1..25, do: new_chat!(ref, %{title: "chat #{n}"})

      assert {:ok, %{conversations: page1, next_cursor: cursor}} =
               Conversations.list_conversations(ref, @me)

      assert length(page1) == 20
      assert hd(page1).title == "chat 25"
      assert cursor

      assert {:ok, %{conversations: page2, next_cursor: nil}} =
               Conversations.list_conversations(ref, @me ++ [cursor: cursor])

      assert Enum.map(page2, & &1.title) == Enum.map(5..1//-1, &"chat #{&1}")
      assert MapSet.disjoint?(uuids(page1), uuids(page2))
    end

    test "has no cursor when the chats fit one page" do
      %{ref: ref} = member()
      for _ <- 1..20, do: new_chat!(ref)

      assert {:ok, %{conversations: list, next_cursor: nil}} =
               Conversations.list_conversations(ref, @me)

      assert length(list) == 20
    end

    test "pages through chats that share one message time without a repeat or a gap" do
      %{user: user, ref: ref} = member()
      for _ <- 1..5, do: new_chat!(ref)
      same = DateTime.utc_now()

      Repo.update_all(from(c in Conversation, where: c.user_uuid == ^user.uuid),
        set: [last_message_at: same]
      )

      seen = collect(ref, nil, [])

      assert length(seen) == 5
      assert length(Enum.uniq(seen)) == 5
    end

    test "a page can be made smaller, never larger than 50" do
      %{ref: ref} = member()
      for _ <- 1..52, do: new_chat!(ref)

      assert {:ok, %{conversations: [_, _], next_cursor: cursor}} =
               Conversations.list_conversations(ref, @me ++ [limit: 2])

      assert cursor

      assert {:ok, %{conversations: list, next_cursor: next}} =
               Conversations.list_conversations(ref, @me ++ [limit: 10_000])

      assert length(list) == 50
      assert next

      assert {:ok, %{conversations: rest, next_cursor: nil}} =
               Conversations.list_conversations(ref, @me ++ [limit: 10_000, cursor: next])

      assert length(rest) == 2
    end

    test "a chat without a message time is placed, and paged, by its creation time" do
      %{ref: ref} = member()
      oldest = new_chat!(ref, %{title: "oldest"})
      middle = new_chat!(ref, %{title: "middle"})
      newest = new_chat!(ref, %{title: "newest"})

      # `middle` has no last_message_at: it sorts by inserted_at, between the
      # other two, and a page boundary right after it neither repeats nor
      # skips a chat.
      Repo.update_all(from(c in Conversation, where: c.uuid == ^middle.uuid),
        set: [last_message_at: nil]
      )

      Repo.update_all(from(c in Conversation, where: c.uuid == ^oldest.uuid),
        set: [last_message_at: DateTime.add(oldest.inserted_at, -60, :second)]
      )

      Repo.update_all(from(c in Conversation, where: c.uuid == ^newest.uuid),
        set: [last_message_at: DateTime.add(newest.inserted_at, 60, :second)]
      )

      assert titles(ref) == ["newest", "middle", "oldest"]

      assert {:ok, %{conversations: [_, %{title: "middle"}], next_cursor: cursor}} =
               Conversations.list_conversations(ref, @me ++ [limit: 2])

      assert {:ok, %{conversations: [%{title: "oldest"}], next_cursor: nil}} =
               Conversations.list_conversations(ref, @me ++ [limit: 2, cursor: cursor])
    end

    test "leaves out archived and deleted chats" do
      %{ref: ref} = member()
      new_chat!(ref, %{title: "keep"})
      archived = new_chat!(ref, %{title: "archived"})
      deleted = new_chat!(ref, %{title: "deleted"})

      {:ok, _} = Conversations.archive_conversation(ref, archived.uuid, @me)
      {:ok, _} = Conversations.delete_conversation(ref, deleted.uuid, @me)

      assert titles(ref) == ["keep"]
    end

    test "shows only the user's own chats" do
      %{ref: mine} = member("mine")
      %{ref: theirs} = member("theirs")
      new_chat!(mine, %{title: "mine"})
      new_chat!(theirs, %{title: "theirs"})

      assert titles(mine) == ["mine"]
      assert titles(theirs) == ["theirs"]
    end

    test "a malformed cursor is refused" do
      %{ref: ref} = member()

      assert {:error, :invalid_cursor} =
               Conversations.list_conversations(ref, @me ++ [cursor: "nonsense"])
    end
  end

  describe "opening a chat" do
    test "returns it with its messages, oldest first" do
      %{ref: ref} = member()
      chat = new_chat!(ref)
      say!(ref, chat, "question")
      turn_say!(chat, %{role: "assistant", content: "answer"})

      assert {:ok, %Conversation{} = loaded} = Conversations.get_conversation(ref, chat.uuid, @me)
      assert loaded.uuid == chat.uuid
      assert Enum.map(loaded.messages, & &1.content) == ["question", "answer"]
    end

    test "an archived chat can still be opened, a deleted one cannot" do
      %{ref: ref} = member()
      archived = new_chat!(ref)
      deleted = new_chat!(ref)
      {:ok, _} = Conversations.archive_conversation(ref, archived.uuid, @me)
      {:ok, _} = Conversations.delete_conversation(ref, deleted.uuid, @me)

      assert {:ok, %Conversation{status: "archived"}} =
               Conversations.get_conversation(ref, archived.uuid, @me)

      assert {:error, :not_found} = Conversations.get_conversation(ref, deleted.uuid, @me)
    end

    test "an unknown or malformed uuid is not found" do
      %{ref: ref} = member()

      assert {:error, :not_found} =
               Conversations.get_conversation(ref, Ecto.UUID.generate(), @me)

      assert {:error, :not_found} = Conversations.get_conversation(ref, "not-a-uuid", @me)
      assert {:error, :not_found} = Conversations.get_conversation(ref, nil, @me)
    end
  end

  describe "renaming, archiving, deleting" do
    test "rename changes the title" do
      %{ref: ref} = member()
      chat = new_chat!(ref, %{title: "old"})

      assert {:ok, %Conversation{title: "new name"}} =
               Conversations.rename_conversation(ref, chat.uuid, "  new name ", @me)

      assert Repo.get!(Conversation, chat.uuid).title == "new name"
    end

    test "rename refuses a blank or over-long title" do
      %{ref: ref} = member()
      chat = new_chat!(ref, %{title: "old"})

      assert {:error, %Ecto.Changeset{}} =
               Conversations.rename_conversation(ref, chat.uuid, "   ", @me)

      assert {:error, %Ecto.Changeset{}} =
               Conversations.rename_conversation(ref, chat.uuid, String.duplicate("a", 201), @me)

      assert Repo.get!(Conversation, chat.uuid).title == "old"
    end

    test "archive and delete set the status and keep the rows" do
      %{ref: ref} = member()
      a = new_chat!(ref)
      d = new_chat!(ref)
      say!(ref, d, "kept")

      assert {:ok, %Conversation{status: "archived"}} =
               Conversations.archive_conversation(ref, a.uuid, @me)

      assert {:ok, %Conversation{status: "deleted"}} =
               Conversations.delete_conversation(ref, d.uuid, @me)

      assert Repo.get!(Conversation, a.uuid).status == "archived"
      assert Repo.get!(Conversation, d.uuid).status == "deleted"
      assert message_count() == 1
    end

    test "a deleted chat cannot be renamed, archived, written to or deleted again" do
      %{ref: ref} = member()
      chat = new_chat!(ref, %{title: "gone"})
      {:ok, _} = Conversations.delete_conversation(ref, chat.uuid, @me)

      for {name, op} <- operations(chat.uuid), name in ~w(rename archive delete add_message)a do
        assert {:error, :not_found} = op.(ref, @me), "#{name} should not find a deleted chat"
      end

      assert Repo.get!(Conversation, chat.uuid).title == "gone"
      assert message_count() == 0
    end
  end

  describe "adding a message" do
    test "several turn messages are stored together, in order, or none of them" do
      %{ref: ref} = member()
      chat = new_chat!(ref)
      :ok = Conversations.subscribe(ref, chat.uuid, @me)
      card_uuid = Ecto.UUID.generate()

      assert {:ok, [notice, card]} =
               Conversations.add_turn_messages(chat.user_uuid, chat.uuid, [
                 {%{role: "notice", content: "n", tool_name: "t", tool_outcome: "changed"},
                  [confirmation_uuid: Ecto.UUID.generate()]},
                 {%{role: "tool", tool_call_id: "w1", tool_name: "t", tool_outcome: "ok"},
                  [confirmation_uuid: card_uuid]}
               ])

      assert card.confirmation_uuid == card_uuid
      assert DateTime.compare(notice.inserted_at, card.inserted_at) == :lt
      chat_uuid = chat.uuid
      notice_uuid = notice.uuid
      card_message_uuid = card.uuid
      assert_receive {:agent_message_added, ^chat_uuid, ^notice_uuid}
      assert_receive {:agent_message_added, ^chat_uuid, ^card_message_uuid}
      assert Repo.get!(Conversation, chat.uuid).message_count == 2

      # The second is refused: the first is not stored either, and nothing is heard.
      before = message_count()

      assert {:error, %Ecto.Changeset{}} =
               Conversations.add_turn_messages(chat.user_uuid, chat.uuid, [
                 {%{role: "notice", content: "n", tool_name: "t", tool_outcome: "changed"}, []},
                 {%{role: "no such role"}, []}
               ])

      assert message_count() == before
      refute_receive {:agent_message_added, _, _}
      assert Repo.get!(Conversation, chat.uuid).message_count == 2
    end

    test "stores it and updates the chat's counters and order" do
      %{ref: ref} = member()
      chat = new_chat!(ref)

      message =
        turn_say!(chat, %{
          role: "assistant",
          content: "answer",
          input_tokens: 120,
          output_tokens: 30,
          cost_micro_usd: 1_500,
          turn_ref: "turn-1"
        })

      assert message.conversation_uuid == chat.uuid
      assert message.role == "assistant"

      turn_say!(chat, %{
        role: "assistant",
        content: "more",
        input_tokens: 5,
        output_tokens: 2,
        cost_micro_usd: 500
      })

      reloaded = Repo.get!(Conversation, chat.uuid)
      assert reloaded.message_count == 2
      assert reloaded.input_tokens == 125
      assert reloaded.output_tokens == 32
      assert reloaded.cost_micro_usd == 2_000
      assert DateTime.compare(reloaded.last_message_at, chat.last_message_at) == :gt
    end

    test "the first user message names an unnamed chat, the first 60 characters of it" do
      %{ref: ref} = member()
      chat = new_chat!(ref)
      long = String.duplicate("word ", 30)

      say!(ref, chat, "  " <> long)
      say!(ref, chat, "a second question")

      assert Repo.get!(Conversation, chat.uuid).title == String.slice(String.trim(long), 0, 60)
    end

    test "an assistant message does not name a chat, and a title already set stays" do
      %{ref: ref} = member()
      unnamed = new_chat!(ref)
      named = new_chat!(ref, %{title: "Mine"})

      turn_say!(unnamed, %{role: "assistant", content: "from the model"})
      say!(ref, named, "a question")

      assert Repo.get!(Conversation, unnamed.uuid).title == nil
      assert Repo.get!(Conversation, named.uuid).title == "Mine"
    end

    test "the turn loop keeps the tool fields of a tool message" do
      %{ref: ref} = member()
      chat = new_chat!(ref)

      message =
        turn_say!(chat, %{
          role: "tool",
          tool_call_id: "call_1",
          tool_name: "orders.list_orders",
          tool_outcome: "ok",
          tool_result: %{"count" => 12}
        })

      assert message.tool_outcome == "ok"
      assert Repo.get!(Message, message.uuid).tool_result == %{"count" => 12}
    end

    test "a session writes the user's text only: no answer, no tool row, no money" do
      %{ref: ref} = member()
      chat = new_chat!(ref)

      {:ok, message} =
        Conversations.add_message(
          ref,
          chat.uuid,
          %{
            "role" => "assistant",
            "content" => "I am the model",
            "tool_calls" => [%{"id" => "c1", "name" => "x", "arguments" => "{}"}],
            "tool_name" => "orders.list_orders",
            "tool_outcome" => "ok",
            "tool_result" => %{"fake" => true},
            "input_tokens" => 1_000,
            "cost_micro_usd" => -5_000_000,
            "ai_request_uuid" => Ecto.UUID.generate(),
            "turn_ref" => "forged"
          },
          @me
        )

      stored = Repo.get!(Message, message.uuid)
      assert stored.role == "user"
      assert stored.content == "I am the model"

      for field <-
            [:tool_calls, :tool_name, :tool_outcome, :tool_result, :input_tokens] ++
              [:cost_micro_usd, :ai_request_uuid, :turn_ref] do
        assert Map.fetch!(stored, field) == nil, "#{field} must not be written by a session"
      end

      chat = Repo.get!(Conversation, chat.uuid)
      assert chat.cost_micro_usd == 0
      assert chat.input_tokens == 0

      for role <- ~w(assistant tool notice) do
        {:ok, _} = Conversations.add_message(ref, chat.uuid, %{role: role, content: "x"}, @me)
      end

      assert Repo.all(
               from(m in Message, where: m.conversation_uuid == ^chat.uuid, select: m.role)
             )
             |> Enum.uniq() == ["user"]
    end

    test "a blank text is refused" do
      %{ref: ref} = member()
      chat = new_chat!(ref)

      assert {:error, %Ecto.Changeset{}} =
               Conversations.add_message(ref, chat.uuid, %{content: "  "}, @me)

      assert {:error, %Ecto.Changeset{}} = Conversations.add_message(ref, chat.uuid, %{}, @me)
      assert message_count() == 0
    end

    test "a text longer than the history window is refused, as a turn refuses it" do
      %{ref: ref} = member()
      chat = new_chat!(ref)
      {:ok, _} = PhoenixKit.Settings.update_setting("agent_history_chars", "1000")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Conversations.add_message(
                 ref,
                 chat.uuid,
                 %{content: String.duplicate("a", 1_001)},
                 @me
               )

      assert %{content: [_]} = errors_on(changeset)
      assert message_count() == 0

      assert {:ok, _} =
               Conversations.add_message(
                 ref,
                 chat.uuid,
                 %{content: String.duplicate("a", 1_000)},
                 @me
               )
    end

    test "the conversation is not taken from the attributes" do
      %{ref: ref} = member()
      mine = new_chat!(ref)
      %{ref: other_ref} = member("other")
      theirs = new_chat!(other_ref)

      {:ok, message} =
        Conversations.add_message(
          ref,
          mine.uuid,
          %{role: "user", content: "x", conversation_uuid: theirs.uuid},
          @me
        )

      assert message.conversation_uuid == mine.uuid
      assert Repo.get!(Conversation, theirs.uuid).message_count == 0
    end

    test "a message to an archived chat is stored" do
      %{ref: ref} = member()
      chat = new_chat!(ref)
      {:ok, _} = Conversations.archive_conversation(ref, chat.uuid, @me)

      assert {:ok, %Message{}} =
               Conversations.add_message(ref, chat.uuid, %{content: "late"}, @me)
    end
  end

  describe "reading messages" do
    setup do
      %{ref: ref} = owner = member()
      chat = new_chat!(ref)
      question = say!(ref, chat, "How many chairs?")

      call =
        turn_say!(chat, %{
          role: "assistant",
          tool_calls: [
            %{"id" => "c1", "name" => "catalogue_list", "arguments" => ~s({"q":"secret filter"})}
          ]
        })

      tool =
        turn_say!(chat, %{
          role: "tool",
          tool_call_id: "c1",
          tool_name: "catalogue.list",
          tool_outcome: "ok",
          tool_result: %{"items" => ["Customer Smith", "b", "c"], "query" => "chairs"}
        })

      cut =
        turn_say!(chat, %{
          role: "tool",
          tool_call_id: "c2",
          tool_name: "catalogue.list",
          tool_outcome: "ok",
          tool_result: %{"truncated" => true, "partial" => "{\"items\":[\"Smith", "hint" => "h"}
        })

      answer = turn_say!(chat, %{role: "assistant", content: "Three."})

      Map.merge(owner, %{
        chat: chat,
        question: question,
        call: call,
        tool: tool,
        cut: cut,
        answer: answer
      })
    end

    test "a tool result is never handed out, only its summary", ctx do
      assert {:ok, loaded} = Conversations.get_conversation(ctx.ref, ctx.chat.uuid, @me)
      assert {:ok, one} = Conversations.get_message(ctx.ref, ctx.chat.uuid, ctx.tool.uuid, @me)
      assert {:ok, listed} = Conversations.list_messages(ctx.ref, ctx.chat.uuid, @me)

      for messages <- [loaded.messages, [one], listed] do
        refute inspect(messages) =~ "Customer Smith"
        refute inspect(messages) =~ "secret filter"
      end

      tool = Enum.find(loaded.messages, &(&1.uuid == ctx.tool.uuid))
      assert tool.tool_result == nil

      assert tool.tool_summary == %{
               name: "catalogue.list",
               outcome: "ok",
               count: 3,
               truncated: false
             }

      assert one.tool_summary == tool.tool_summary

      cut = Enum.find(listed, &(&1.uuid == ctx.cut.uuid))
      assert cut.tool_result == nil

      assert cut.tool_summary == %{
               name: "catalogue.list",
               outcome: "ok",
               count: nil,
               truncated: true
             }

      call = Enum.find(listed, &(&1.uuid == ctx.call.uuid))
      assert call.tool_calls == [%{"id" => "c1", "name" => "catalogue_list"}]
      assert call.tool_summary == nil
    end

    test "get_message/4 gives one message of the chat", ctx do
      assert {:ok, %Message{content: "Three."}} =
               Conversations.get_message(ctx.ref, ctx.chat.uuid, ctx.answer.uuid, @me)

      other = new_chat!(ctx.ref)
      elsewhere = say!(ctx.ref, other, "elsewhere")

      for uuid <- [elsewhere.uuid, Ecto.UUID.generate(), "junk", nil] do
        assert {:error, :not_found} = Conversations.get_message(ctx.ref, ctx.chat.uuid, uuid, @me)
      end
    end

    test "list_messages/3 gives them oldest first, after a message, a page at a time", ctx do
      in_order = [ctx.question, ctx.call, ctx.tool, ctx.cut, ctx.answer]

      assert {:ok, all} = Conversations.list_messages(ctx.ref, ctx.chat.uuid, @me)
      assert Enum.map(all, & &1.uuid) == Enum.map(in_order, & &1.uuid)

      assert {:ok, after_tool} =
               Conversations.list_messages(ctx.ref, ctx.chat.uuid, @me ++ [after: ctx.tool.uuid])

      assert Enum.map(after_tool, & &1.uuid) == [ctx.cut.uuid, ctx.answer.uuid]

      assert {:ok, [first, second]} =
               Conversations.list_messages(ctx.ref, ctx.chat.uuid, @me ++ [limit: 2])

      assert [first.uuid, second.uuid] == [ctx.question.uuid, ctx.call.uuid]

      assert {:ok, []} =
               Conversations.list_messages(
                 ctx.ref,
                 ctx.chat.uuid,
                 @me ++ [after: ctx.answer.uuid]
               )
    end

    test "list_messages/3 gives the latest ones, and those before a message, oldest first", ctx do
      uuids = Enum.map([ctx.question, ctx.call, ctx.tool, ctx.cut, ctx.answer], & &1.uuid)

      assert {:ok, latest} =
               Conversations.list_messages(
                 ctx.ref,
                 ctx.chat.uuid,
                 @me ++ [latest: true, limit: 2]
               )

      assert Enum.map(latest, & &1.uuid) == Enum.take(uuids, -2)

      assert {:ok, earlier} =
               Conversations.list_messages(
                 ctx.ref,
                 ctx.chat.uuid,
                 @me ++ [before: ctx.cut.uuid, limit: 2]
               )

      assert Enum.map(earlier, & &1.uuid) == [ctx.call.uuid, ctx.tool.uuid]
      refute inspect(earlier) =~ "Customer Smith"

      assert {:ok, first} =
               Conversations.list_messages(
                 ctx.ref,
                 ctx.chat.uuid,
                 @me ++ [before: ctx.call.uuid, limit: 50]
               )

      assert Enum.map(first, & &1.uuid) == [ctx.question.uuid]

      other = new_chat!(ctx.ref)
      elsewhere = say!(ctx.ref, other, "elsewhere")

      for cursor <- [elsewhere.uuid, Ecto.UUID.generate(), "junk", 5] do
        assert {:error, :invalid_cursor} =
                 Conversations.list_messages(ctx.ref, ctx.chat.uuid, @me ++ [before: cursor])
      end

      assert {:error, :invalid_cursor} =
               Conversations.list_messages(
                 ctx.ref,
                 ctx.chat.uuid,
                 @me ++ [after: ctx.call.uuid, before: ctx.answer.uuid]
               )
    end

    test "list_messages/3 takes at most 200 at once", ctx do
      for n <- 1..205, do: turn_say!(ctx.chat, %{role: "notice", content: "n#{n}"})

      assert {:ok, page} =
               Conversations.list_messages(ctx.ref, ctx.chat.uuid, @me ++ [limit: 10_000])

      assert length(page) == 200
    end

    test "a cursor that is not a message of this chat is refused", ctx do
      other = new_chat!(ctx.ref)
      elsewhere = say!(ctx.ref, other, "elsewhere")

      for cursor <- [elsewhere.uuid, Ecto.UUID.generate(), "junk", 5] do
        assert {:error, :invalid_cursor} =
                 Conversations.list_messages(ctx.ref, ctx.chat.uuid, @me ++ [after: cursor])
      end
    end
  end

  describe "another user's chat" do
    setup do
      owner = member("owner")
      stranger = member("stranger")
      chat = new_chat!(owner.ref, %{title: "private"})
      say!(owner.ref, chat, "customer data")

      %{owner: owner, stranger: stranger, chat: chat}
    end

    test "is not opened, renamed, archived, deleted, written to or subscribed to", %{
      stranger: stranger,
      chat: chat
    } do
      before_messages = message_count()

      for {name, op} <- operations(chat.uuid), name not in ~w(list create)a do
        assert {:error, :not_found} = op.(stranger.ref, @me),
               "#{name} must answer :not_found for a chat of someone else"
      end

      reloaded = Repo.get!(Conversation, chat.uuid)
      assert reloaded.title == "private"
      assert reloaded.status == "active"
      assert message_count() == before_messages
    end

    test "answers the same as for a chat that does not exist", %{stranger: stranger, chat: chat} do
      missing = Ecto.UUID.generate()

      for {name, _op} <- operations(chat.uuid), name not in ~w(list create)a do
        foreign = Keyword.fetch!(operations(chat.uuid), name).(stranger.ref, @me)
        absent = Keyword.fetch!(operations(missing), name).(stranger.ref, @me)
        assert foreign == absent, "#{name} must not tell a foreign chat from a missing one"
      end
    end

    test "is not in the stranger's list", %{stranger: stranger} do
      assert titles(stranger.ref) == []
    end

    test "a message of it is not read by its uuid", %{
      owner: owner,
      stranger: stranger,
      chat: chat
    } do
      %{ref: stranger_ref} = stranger
      {:ok, %{messages: [message]}} = Conversations.get_conversation(owner.ref, chat.uuid, @me)
      own_chat = new_chat!(stranger_ref)

      assert {:error, :not_found} =
               Conversations.get_message(stranger_ref, chat.uuid, message.uuid, @me)

      assert {:error, :not_found} =
               Conversations.get_message(stranger_ref, own_chat.uuid, message.uuid, @me)
    end

    test "is untouched for its owner after the attempts", %{owner: owner, chat: chat} do
      assert {:ok, %Conversation{title: "private", messages: [%{content: "customer data"}]}} =
               Conversations.get_conversation(owner.ref, chat.uuid, @me)
    end
  end

  describe "the session gate" do
    test "a user without the agent permission is refused everywhere" do
      user = user_with(["dashboard"], "no-agent")
      {ref, _token} = session_fixture(user)
      %{ref: owner_ref} = member("owner")
      chat = new_chat!(owner_ref)

      for {name, op} <- operations(chat.uuid) do
        assert {:error, :forbidden} = op.(ref, @me), "#{name} must need the agent permission"
      end

      assert chat_count() == 1
    end

    test "nothing works while the module is disabled" do
      %{ref: ref} = member()
      chat = new_chat!(ref)
      {:ok, _} = PhoenixKitAgent.disable_system()

      for {name, op} <- operations(chat.uuid) do
        assert {:error, :forbidden} = op.(ref, @me), "#{name} must be refused while disabled"
      end
    end

    test "a user the assistant is switched off for is refused" do
      %{user: user, ref: ref} = member()
      chat = new_chat!(ref)
      Repo.insert!(%UserSettings{user_uuid: user.uuid, enabled: false})

      for {name, op} <- operations(chat.uuid) do
        assert {:error, :forbidden} = op.(ref, @me), "#{name} must respect enabled: false"
      end
    end

    test "a revoked session is refused everywhere" do
      %{ref: ref, token: token} = member()
      chat = new_chat!(ref)
      Auth.delete_user_session_token(token)

      for {name, op} <- operations(chat.uuid) do
        assert {:error, :session_gone} = op.(ref, @me), "#{name} must need a live session"
      end
    end

    test "a session of another user is a mismatch" do
      %{user: user, ref: {token_uuid, _}} = member("a")
      %{ref: {_, other_user}} = member("b")
      chat = new_chat!({token_uuid, user.uuid})

      for {name, op} <- operations(chat.uuid) do
        assert {:error, :mismatch} = op.({token_uuid, other_user}, @me),
               "#{name} must tie the session to its user"
      end
    end

    test "an unconfirmed account is refused" do
      user = user_with(["agent"], "unconfirmed")
      {ref, _token} = session_fixture(user, confirmed: false)

      for {name, op} <- operations(Ecto.UUID.generate()) do
        assert {:error, :unconfirmed} = op.(ref, @me),
               "#{name} must refuse an unconfirmed account"
      end

      assert chat_count() == 0
    end

    test "a blocked user is refused" do
      %{user: user, ref: ref} = member()
      chat = new_chat!(ref)

      Repo.update_all(from(u in Auth.User, where: u.uuid == ^user.uuid), set: [is_active: false])

      ExUnit.CaptureLog.capture_log(fn ->
        for {name, op} <- operations(chat.uuid) do
          assert {:error, :inactive} = op.(ref, @me), "#{name} must refuse a blocked user"
        end
      end)
    end

    test "a malformed reference is refused, not raised" do
      for ref <- [nil, "ref", {"only"}, {1, 2}, {nil, nil}, %{}] do
        for {_name, op} <- operations(Ecto.UUID.generate()) do
          assert {:error, :session_gone} = op.(ref, @me)
        end
      end
    end

    test "the impersonation flag is required, not defaulted" do
      %{ref: ref} = member()

      assert_raise ArgumentError, fn -> Conversations.list_conversations(ref, []) end

      assert_raise ArgumentError, fn ->
        Conversations.list_conversations(ref, impersonated: nil)
      end

      assert_raise ArgumentError, fn ->
        Conversations.create_conversation(ref, %{}, impersonated: "no")
      end
    end
  end

  describe "an impersonated session" do
    test "gets nothing and writes nothing" do
      %{ref: ref} = member()
      chat = new_chat!(ref, %{title: "private"})
      say!(ref, chat, "customer data")
      chats = chat_count()
      messages = message_count()

      for {name, op} <- operations(chat.uuid) do
        assert {:error, :impersonated} = op.(ref, impersonated: true),
               "#{name} must be refused in an impersonated session"
      end

      assert chat_count() == chats
      assert message_count() == messages
      assert Repo.get!(Conversation, chat.uuid).title == "private"
      assert Repo.get!(Conversation, chat.uuid).status == "active"
    end

    test "is refused even when the same session is fine without the flag" do
      %{ref: ref} = member()

      assert {:ok, %{conversations: []}} = Conversations.list_conversations(ref, @me)

      assert {:error, :impersonated} =
               Conversations.list_conversations(ref, impersonated: true)
    end
  end

  describe "the chat topic" do
    test "is agent:conv:<uuid>" do
      uuid = Ecto.UUID.generate()
      assert Conversations.topic(uuid) == "agent:conv:" <> uuid
    end

    test "the owner subscribes, and hears of a new message" do
      %{ref: ref} = member()
      chat = new_chat!(ref)

      assert :ok = Conversations.subscribe(ref, chat.uuid, @me)

      message = say!(ref, chat, "hello")
      chat_uuid = chat.uuid
      message_uuid = message.uuid

      assert_receive {:agent_message_added, ^chat_uuid, ^message_uuid}
    end

    test "the event carries uuids, not the message" do
      %{ref: ref} = member()
      chat = new_chat!(ref)
      :ok = Conversations.subscribe(ref, chat.uuid, @me)
      say!(ref, chat, "secret words")

      assert_receive {:agent_message_added, _, _} = event
      refute inspect(event) =~ "secret words"
    end

    test "unsubscribe/1 stops the events" do
      %{ref: ref} = member()
      chat = new_chat!(ref)
      :ok = Conversations.subscribe(ref, chat.uuid, @me)

      assert :ok = Conversations.unsubscribe(chat.uuid)
      say!(ref, chat, "hello")

      refute_receive {:agent_message_added, _, _}
    end

    test "a stranger is not subscribed, and hears nothing" do
      %{ref: owner_ref} = member("owner")
      %{ref: stranger_ref} = member("stranger")
      chat = new_chat!(owner_ref)

      assert {:error, :not_found} = Conversations.subscribe(stranger_ref, chat.uuid, @me)

      say!(owner_ref, chat, "hello")

      refute_receive {:agent_message_added, _, _}
    end

    test "an impersonated session is not subscribed" do
      %{ref: ref} = member()
      chat = new_chat!(ref)

      assert {:error, :impersonated} =
               Conversations.subscribe(ref, chat.uuid, impersonated: true)

      say!(ref, chat, "hello")
      refute_receive {:agent_message_added, _, _}
    end

    test "a message that was refused is not broadcast" do
      %{ref: owner_ref} = member("owner")
      %{ref: stranger_ref} = member("stranger")
      chat = new_chat!(owner_ref)
      :ok = Conversations.subscribe(owner_ref, chat.uuid, @me)

      assert {:error, :not_found} =
               Conversations.add_message(
                 stranger_ref,
                 chat.uuid,
                 %{role: "user", content: "x"},
                 @me
               )

      assert {:error, %Ecto.Changeset{}} =
               Conversations.add_message(owner_ref, chat.uuid, %{content: ""}, @me)

      refute_receive {:agent_message_added, _, _}
    end
  end
end
