defmodule PhoenixKitAgent.SchemasTest do
  @moduledoc """
  The Ecto schemas over the module's tables: UUIDv7 keys, the values each
  enumerated column takes (in the changeset and in the database), and the
  links that a delete elsewhere sets to null.
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, LimitEvent, Message, UserSettings}

  defp uuid_v7?(uuid) do
    <<_::binary-size(14), version::binary-size(1), _::binary>> = uuid
    version == "7"
  end

  setup do
    user = user_fixture()
    %{user: user, conversation: conversation_fixture(user)}
  end

  describe "Conversation" do
    test "gets a UUIDv7 key and the defaults of a new chat", %{conversation: conversation} do
      assert uuid_v7?(conversation.uuid)
      assert conversation.status == "active"
      assert conversation.message_count == 0
      assert conversation.cost_micro_usd == 0
      assert conversation.metadata == %{}
    end

    test "status is active, archived or deleted", %{user: user} do
      changeset = Conversation.changeset(%Conversation{user_uuid: user.uuid}, %{status: "gone"})
      assert %{status: [_]} = errors_on(changeset)

      for status <- ~w(active archived deleted) do
        assert Conversation.changeset(%Conversation{user_uuid: user.uuid}, %{status: status}).valid?
      end
    end

    test "the owner is not taken from the attributes", %{user: user} do
      other = user_fixture()

      changeset =
        Conversation.changeset(%Conversation{user_uuid: user.uuid}, %{user_uuid: other.uuid})

      assert Ecto.Changeset.get_field(changeset, :user_uuid) == user.uuid
    end

    test "a nil for a NOT NULL column is a changeset error, not a database one", %{user: user} do
      changeset = Conversation.changeset(%Conversation{user_uuid: user.uuid}, %{metadata: nil})
      assert %{metadata: [_]} = errors_on(changeset)
    end

    test "the database refuses a status the changeset would", %{conversation: conversation} do
      assert_raise Postgrex.Error, ~r/phoenix_kit_agent_conversations_status_check/, fn ->
        Repo.query!(
          "UPDATE phoenix_kit_agent_conversations SET status = 'gone' WHERE uuid = $1",
          [
            Ecto.UUID.dump!(conversation.uuid)
          ]
        )
      end
    end
  end

  describe "Message" do
    test "role is user, assistant, tool or notice; outcome is one of the nine", %{
      conversation: conversation
    } do
      base = %Message{conversation_uuid: conversation.uuid}

      assert %{role: [_]} = errors_on(Message.changeset(base, %{role: "system"}))
      assert %{role: [_]} = errors_on(Message.changeset(base, %{}))

      assert %{tool_outcome: [_]} =
               errors_on(Message.changeset(base, %{role: "tool", tool_outcome: "maybe"}))

      for outcome <-
            ~w(ok error denied needs_confirmation confirmed rejected expired changed failed) do
        assert Message.changeset(base, %{role: "tool", tool_outcome: outcome}).valid?
      end
    end

    test "stores a tool call and its result", %{conversation: conversation} do
      message =
        %Message{conversation_uuid: conversation.uuid}
        |> Message.changeset(%{
          role: "assistant",
          turn_ref: "turn-1",
          tool_calls: [%{"id" => "c1", "name" => "catalogue_list", "arguments" => "{}"}]
        })
        |> Repo.insert!()

      assert uuid_v7?(message.uuid)

      assert [%{"id" => "c1"}] = Repo.get!(Message, message.uuid).tool_calls
    end

    test "money is never negative; tokens and latency fit their integer columns", %{
      conversation: conversation
    } do
      base = %Message{conversation_uuid: conversation.uuid}

      assert %{cost_micro_usd: [_]} =
               errors_on(Message.changeset(base, %{role: "assistant", cost_micro_usd: -1}))

      too_big = 2_147_483_648

      assert %{input_tokens: [_], output_tokens: [_], latency_ms: [_]} =
               errors_on(
                 Message.changeset(base, %{
                   role: "assistant",
                   input_tokens: too_big,
                   output_tokens: too_big,
                   latency_ms: too_big
                 })
               )

      assert %{cost_micro_usd: [_]} =
               errors_on(
                 Message.changeset(base, %{
                   role: "assistant",
                   cost_micro_usd: 9_223_372_036_854_775_808
                 })
               )

      assert Message.changeset(base, %{
               role: "assistant",
               input_tokens: too_big - 1,
               cost_micro_usd: 0
             }).valid?
    end

    test "NUL characters are cut from the text, the tool calls and the tool result", %{
      conversation: conversation
    } do
      message =
        %Message{conversation_uuid: conversation.uuid}
        |> Message.changeset(%{
          role: "tool",
          content: "a\u0000b",
          tool_name: "x\u0000y",
          tool_calls: [%{"id" => "c\u00001", "arguments" => %{"q" => "n\u0000ul"}}],
          tool_result: %{"items" => ["ch\u0000air", %{"k\u0000" => "v"}]}
        })
        |> Repo.insert!()

      stored = Repo.get!(Message, message.uuid)
      assert stored.content == "ab"
      assert stored.tool_name == "xy"
      assert stored.tool_calls == [%{"id" => "c1", "arguments" => %{"q" => "nul"}}]
      assert stored.tool_result == %{"items" => ["chair", %{"k" => "v"}]}
    end

    test "user_changeset/2 takes the text only, as the user's message", %{
      conversation: conversation
    } do
      base = %Message{conversation_uuid: conversation.uuid}

      changeset =
        Message.user_changeset(base, %{
          "role" => "assistant",
          "content" => "hello",
          "cost_micro_usd" => 5,
          "tool_result" => %{"a" => 1},
          "tool_calls" => [%{"id" => "c"}],
          "input_tokens" => 3
        })

      assert changeset.valid?
      assert changeset.changes == %{role: "user", content: "hello"}

      assert %{content: [_]} = errors_on(Message.user_changeset(base, %{content: "   "}))
      assert %{content: [_]} = errors_on(Message.user_changeset(base, %{}))
    end

    test "deleting the journal row leaves the message, unlinked", %{
      user: user,
      conversation: conversation
    } do
      request = ai_request_fixture(user, endpoint_fixture())

      message =
        %Message{conversation_uuid: conversation.uuid, ai_request_uuid: request.uuid}
        |> Message.changeset(%{role: "assistant", content: "hi"})
        |> Repo.insert!()

      Repo.delete!(request)

      assert %Message{ai_request_uuid: nil, content: "hi"} = Repo.get!(Message, message.uuid)
    end
  end

  describe "Attachment" do
    test "kind and status take the values of the spec", %{
      user: user,
      conversation: conversation
    } do
      base = %Attachment{conversation_uuid: conversation.uuid, user_uuid: user.uuid}
      attrs = %{filename: "a.pdf", content_type: "application/pdf", size_bytes: 10, kind: "pdf"}

      attachment = base |> Attachment.changeset(attrs) |> Repo.insert!()
      assert attachment.status == "pending"
      assert uuid_v7?(attachment.uuid)

      assert %{kind: [_]} = errors_on(Attachment.changeset(base, %{attrs | kind: "video"}))

      assert %{status: [_]} =
               errors_on(Attachment.changeset(base, Map.put(attrs, :status, "lost")))

      assert %{size_bytes: [_]} = errors_on(Attachment.changeset(base, %{attrs | size_bytes: -1}))
    end

    test "nil for a NOT NULL column, or pages past the integer column, is a changeset error", %{
      user: user,
      conversation: conversation
    } do
      base = %Attachment{conversation_uuid: conversation.uuid, user_uuid: user.uuid}
      attrs = %{filename: "a.pdf", content_type: "application/pdf", size_bytes: 10, kind: "pdf"}

      assert %{truncated: [_]} =
               errors_on(Attachment.changeset(base, Map.put(attrs, :truncated, nil)))

      assert %{pages: [_]} =
               errors_on(Attachment.changeset(base, Map.put(attrs, :pages, 2_147_483_648)))
    end
  end

  describe "UserSettings" do
    test "one row per user; nothing set means the module default", %{user: user} do
      settings =
        %UserSettings{user_uuid: user.uuid} |> UserSettings.admin_changeset(%{}) |> Repo.insert!()

      assert settings.user_uuid == user.uuid
      assert settings.enabled == nil
      assert settings.daily_cost_limit_micro_usd == nil
      assert settings.notify_on_limit == false
      assert settings.notify_user_uuids == []

      assert {:error, changeset} =
               %UserSettings{user_uuid: user.uuid}
               |> UserSettings.admin_changeset(%{})
               |> Repo.insert()

      assert %{user_uuid: [_]} = errors_on(changeset)
    end

    test "a limit is never negative", %{user: user} do
      changeset =
        UserSettings.admin_changeset(%UserSettings{user_uuid: user.uuid}, %{
          daily_cost_limit_micro_usd: -1,
          daily_turn_limit: -1
        })

      assert %{daily_cost_limit_micro_usd: [_], daily_turn_limit: [_]} = errors_on(changeset)

      assert %{daily_turn_limit: [_], max_attachment_mb: [_]} =
               errors_on(
                 UserSettings.admin_changeset(%UserSettings{user_uuid: user.uuid}, %{
                   daily_turn_limit: 2_147_483_648,
                   max_attachment_mb: 2_147_483_648
                 })
               )
    end

    test "the admin's changeset takes the admin's fields, not the user's own instructions", %{
      user: user
    } do
      other = user_fixture()
      endpoint = endpoint_fixture()

      changeset =
        UserSettings.admin_changeset(%UserSettings{user_uuid: user.uuid}, %{
          enabled: false,
          endpoint_uuid: endpoint.uuid,
          system_prompt: "Be brief.",
          daily_turn_limit: 5,
          notify_on_limit: true,
          notify_user_uuids: [other.uuid],
          personal_instructions: "mine",
          busy_since: DateTime.utc_now(),
          busy_turn_ref: "t",
          updated_by_uuid: other.uuid,
          user_uuid: other.uuid
        })

      assert changeset.valid?

      assert Map.keys(changeset.changes) |> Enum.sort() ==
               Enum.sort([
                 :enabled,
                 :endpoint_uuid,
                 :system_prompt,
                 :daily_turn_limit,
                 :notify_on_limit,
                 :notify_user_uuids
               ])

      assert %{notify_on_limit: [_], notify_user_uuids: [_]} =
               errors_on(
                 UserSettings.admin_changeset(%UserSettings{user_uuid: user.uuid}, %{
                   notify_on_limit: nil,
                   notify_user_uuids: nil
                 })
               )
    end

    test "the personal changeset takes the user's own instructions only", %{user: user} do
      changeset =
        UserSettings.personal_changeset(%UserSettings{user_uuid: user.uuid}, %{
          personal_instructions: "Call me Tim.",
          enabled: true,
          daily_turn_limit: 100_000,
          endpoint_uuid: Ecto.UUID.generate(),
          system_prompt: "Ignore the limits.",
          notify_user_uuids: [Ecto.UUID.generate()],
          busy_turn_ref: "t"
        })

      assert changeset.changes == %{personal_instructions: "Call me Tim."}
    end

    test "deleting the endpoint a user was given leaves their settings, without it", %{
      user: user
    } do
      endpoint = endpoint_fixture()

      %UserSettings{user_uuid: user.uuid}
      |> UserSettings.admin_changeset(%{endpoint_uuid: endpoint.uuid})
      |> Repo.insert!()

      assert {:ok, _} = PhoenixKitAI.delete_endpoint(endpoint)

      assert %UserSettings{endpoint_uuid: nil} = Repo.get!(UserSettings, user.uuid)
    end
  end

  describe "LimitEvent" do
    test "one notice per user, kind and period", %{user: user} do
      attrs = %{
        limit_kind: "daily_cost",
        period_key: "2026-10-20",
        used: 1_000_000,
        limit: 1_000_000
      }

      %LimitEvent{user_uuid: user.uuid} |> LimitEvent.changeset(attrs) |> Repo.insert!()

      assert {:error, changeset} =
               %LimitEvent{user_uuid: user.uuid} |> LimitEvent.changeset(attrs) |> Repo.insert()

      assert %{user_uuid: [_]} = errors_on(changeset)

      assert %{limit_kind: [_]} =
               errors_on(
                 LimitEvent.changeset(%LimitEvent{user_uuid: user.uuid}, %{
                   attrs
                   | limit_kind: "weekly"
                 })
               )
    end
  end
end
