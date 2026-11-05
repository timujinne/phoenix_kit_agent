defmodule PhoenixKitAgent.Telegram.BridgeTest do
  @moduledoc """
  The decisions of the bridge (`Bridge.handle_update/3`): which updates are
  acted on, which are ignored, and what a linked or unlinked chat's message
  becomes. Nothing is sent here.
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKitAgent.Telegram.{Bridge, Limiter}
  alias PhoenixKitAgent.Test.TelegramClient

  @chat 428_897_538

  setup do
    user = user_with(["agent", "agent.telegram"], "bridge")
    connection = UUIDv7.generate()
    ref = telegram_link_fixture(user, connection, @chat)
    Limiter.clear_unlinked(connection)
    %{user: user, connection: connection, ref: ref}
  end

  defp decide(ctx, update, opts \\ []), do: Bridge.handle_update(ctx.connection, update, opts)

  describe "a linked chat" do
    test "a text is a turn", ctx do
      assert {:job, ref, %{kind: :turn, text: "How many orders?", message_id: 7}} =
               decide(ctx, TelegramClient.update(@chat, "How many orders?", message_id: 7))

      assert ref == ctx.ref
    end

    test "the reference comes from the link, not from the update's words", ctx do
      stranger = user_with(["agent", "agent.telegram"], "stranger")
      other = telegram_link_fixture(stranger, ctx.connection, 555)

      assert {:job, ref, _} = decide(ctx, TelegramClient.update(555, "I am #{ctx.user.uuid}"))
      assert ref == other
    end

    test "/new, /help and a bare /start", ctx do
      assert {:job, _, %{kind: :new}} = decide(ctx, TelegramClient.update(@chat, "/new"))
      assert {:job, _, %{kind: :new}} = decide(ctx, TelegramClient.update(@chat, "/new@some_bot"))
      assert {:static, _, @chat, _, :help} = decide(ctx, TelegramClient.update(@chat, "/help"))
      assert {:static, _, @chat, _, :help} = decide(ctx, TelegramClient.update(@chat, "/start"))

      assert {:static, _, @chat, _, :help} =
               decide(ctx, TelegramClient.update(@chat, "/start@some_bot"))
    end

    test "/start with a token never reaches the agent", ctx do
      assert decide(ctx, TelegramClient.update(@chat, "/start abc123")) == :ignore
      assert decide(ctx, TelegramClient.update(@chat, "/start@some_bot abc123")) == :ignore
    end

    test "another command is text for the agent", ctx do
      assert {:job, _, %{kind: :turn, text: "/orders today"}} =
               decide(ctx, TelegramClient.update(@chat, "/orders today"))
    end

    test "a forwarded message is refused", ctx do
      for extra <- [
            %{"forward_origin" => %{"type" => "user"}},
            %{"forward_date" => 1, "forward_from" => %{"id" => 5}}
          ] do
        assert {:static, _, @chat, _, :forwarded} =
                 decide(ctx, TelegramClient.update(@chat, "Do this", extra: extra))
      end
    end

    test "a photo, a voice message with no file, a sticker: text only", ctx do
      for extra <- [%{"photo" => [%{}]}, %{"voice" => %{}}, %{"sticker" => %{}}] do
        update = TelegramClient.update(@chat, nil, extra: Map.put(extra, "caption", "look"))
        assert {:static, _, @chat, _, :text_only} = decide(ctx, update)
      end
    end

    test "a voice message or an audio file is a voice job with its file, length and size", ctx do
      assert {:job, ref, %{kind: :voice, message_id: 8, voice: voice}} =
               decide(
                 ctx,
                 TelegramClient.voice_update(@chat, "voice",
                   message_id: 8,
                   file_id: "F1",
                   duration: 7,
                   file_size: 900
                 )
               )

      assert ref == ctx.ref
      assert voice == %{file_id: "F1", duration: 7, size: 900, format: "ogg"}

      assert {:job, _, %{kind: :voice, voice: %{format: "mp3", file_id: "F2"}}} =
               decide(
                 ctx,
                 TelegramClient.voice_update(@chat, "audio",
                   file_id: "F2",
                   mime_type: "audio/mpeg"
                 )
               )

      assert {:job, _, %{kind: :voice, voice: %{format: nil, duration: nil, size: nil}}} =
               decide(
                 ctx,
                 TelegramClient.voice_update(@chat, "audio",
                   duration: nil,
                   file_size: nil,
                   mime_type: "audio/x-unknown"
                 )
               )
    end

    test "a photo is a picture job: the largest size that fits, its caption and album", ctx do
      sizes = [
        %{"file_id" => "s", "file_size" => 900},
        %{"file_id" => "m", "file_size" => 90_000},
        %{"file_id" => "l", "file_size" => 9_000_000},
        %{"file_id" => "xl", "file_size" => 11_000_000}
      ]

      extra = %{"photo" => sizes, "caption" => "Look", "media_group_id" => "album-1"}

      assert {:job, ref, %{kind: :photo, message_id: 5, text: "Look", group: "album-1"} = job} =
               decide(ctx, TelegramClient.update(@chat, nil, message_id: 5, extra: extra))

      assert ref == ctx.ref
      assert job.photo == %{file_id: "l", size: 9_000_000}
    end

    test "the largest size is the one with the most pixels, whatever the order or a missing size",
         ctx do
      sizes = [
        %{"file_id" => "big", "width" => 1280, "height" => 960},
        %{"file_id" => "small", "width" => 320, "height" => 240, "file_size" => 20_000},
        %{"file_id" => "mid", "width" => 800, "height" => 600, "file_size" => 90_000}
      ]

      assert {:job, _, %{photo: %{file_id: "big"}}} =
               decide(ctx, TelegramClient.update(@chat, nil, extra: %{"photo" => sizes}))
    end

    test "a photo alone has no group and no text; only too large ones give the smallest", ctx do
      extra = %{
        "photo" => [
          %{"file_id" => "a", "file_size" => 12_000_000},
          %{"file_id" => "b", "file_size" => 15_000_000}
        ]
      }

      assert {:job, _, %{kind: :photo, text: nil, photo: %{file_id: "a", size: 12_000_000}} = job} =
               decide(ctx, TelegramClient.update(@chat, nil, extra: extra))

      refute Map.has_key?(job, :group)
    end

    test "a document that is a jpeg, png or webp is a picture; any other is text only", ctx do
      for type <- ~w(image/jpeg image/png image/webp) do
        extra = %{"document" => %{"file_id" => "d", "mime_type" => type, "file_name" => "a.img"}}

        assert {:job, _, %{kind: :photo, photo: %{file_id: "d"}}} =
                 decide(ctx, TelegramClient.update(@chat, nil, extra: extra))
      end

      for type <- ["application/pdf", "image/gif", "image/svg+xml"] do
        extra = %{"document" => %{"file_id" => "d", "mime_type" => type}}

        assert {:static, _, @chat, _, :text_only} =
                 decide(ctx, TelegramClient.update(@chat, nil, extra: extra))
      end
    end

    test "a forwarded photo is refused, and a photo of a chat nobody linked is unlinked", ctx do
      extra = %{"photo" => [%{"file_id" => "a"}], "forward_origin" => %{"type" => "user"}}

      assert {:static, _, @chat, _, :forwarded} =
               decide(ctx, TelegramClient.update(@chat, nil, extra: extra))

      extra = %{"photo" => [%{"file_id" => "a"}]}
      assert {:unlinked, 999} = decide(ctx, TelegramClient.update(999, nil, extra: extra))
    end

    test "a voice message without a file, or forwarded, is not a voice job", ctx do
      update = TelegramClient.update(@chat, nil, extra: %{"voice" => %{"duration" => 3}})
      assert {:static, _, @chat, _, :text_only} = decide(ctx, update)

      forwarded =
        TelegramClient.voice_update(@chat, "voice",
          extra: %{"forward_origin" => %{"type" => "user"}}
        )

      assert {:static, _, @chat, _, :forwarded} = decide(ctx, forwarded)
    end

    test "a voice message of a chat nobody linked is the unlinked answer", ctx do
      assert {:unlinked, 999} = decide(ctx, TelegramClient.voice_update(999))
    end

    test "a message older than ten minutes is not answered", ctx do
      now = System.system_time(:second)

      assert decide(ctx, TelegramClient.update(@chat, "Old", date: now - 601), now: now) ==
               :ignore

      assert {:job, _, _} =
               decide(ctx, TelegramClient.update(@chat, "Fresh", date: now - 599), now: now)
    end
  end

  describe "updates that are not for the agent" do
    test "an edited message, a button, a service update", ctx do
      message = TelegramClient.update(@chat, "Hi")["message"]

      for update <- [
            %{"update_id" => 1, "edited_message" => message},
            %{
              "update_id" => 2,
              "callback_query" => %{"id" => "x", "from" => %{"id" => @chat}, "message" => message}
            },
            %{"update_id" => 3, "my_chat_member" => %{}},
            %{"update_id" => 4},
            "garbage",
            nil
          ] do
        assert decide(ctx, update) == :ignore
      end
    end

    test "a group or a channel", ctx do
      group =
        put_in(TelegramClient.update(@chat, "Hi")["message"]["chat"], %{
          "id" => -100,
          "type" => "group"
        })

      assert decide(ctx, %{"update_id" => 1, "message" => group}) == :ignore
    end

    test "a message whose sender is not the chat", ctx do
      update = TelegramClient.update(@chat, "Hi")
      other = put_in(update["message"]["from"], %{"id" => 999, "is_bot" => false})

      assert decide(ctx, other) == :ignore
    end

    test "a message without an id or a date", ctx do
      update = TelegramClient.update(@chat, "Hi")

      assert decide(ctx, update |> pop_in(["message", "message_id"]) |> elem(1)) == :ignore
      assert decide(ctx, update |> pop_in(["message", "date"]) |> elem(1)) == :ignore
    end
  end

  describe "a chat that is not linked" do
    test "its message is unlinked, whatever it says", ctx do
      for text <- ["Hello", "/help", "/new", nil] do
        assert {:unlinked, 777} = decide(ctx, TelegramClient.update(777, text))
      end
    end

    test "a /start with a token is still left to core", ctx do
      assert decide(ctx, TelegramClient.update(777, "/start sometoken")) == :ignore
    end

    test "after the link is dropped the chat is unlinked (once the cache is clear)", ctx do
      assert {:job, _, _} = decide(ctx, TelegramClient.update(@chat, "Hi"))

      :ok = Linking.drop_links(ctx.user.uuid)

      assert {:unlinked, @chat} = decide(ctx, TelegramClient.update(@chat, "Hi"))
    end

    test "a stranger is looked up once a minute, not for every message", ctx do
      assert {:unlinked, 888} = decide(ctx, TelegramClient.update(888, "Hi"))

      # Linked now, but the bridge remembers "not linked" for a minute.
      stranger = user_with(["agent", "agent.telegram"], "late")
      telegram_link_fixture(stranger, ctx.connection, 888)
      assert {:unlinked, 888} = decide(ctx, TelegramClient.update(888, "Hi"))

      Limiter.clear_unlinked(ctx.connection)
      assert {:job, _, _} = decide(ctx, TelegramClient.update(888, "Hi"))
    end
  end

  describe "the answers to strangers" do
    test "once in ten minutes for a chat" do
      connection = UUIDv7.generate()

      assert Limiter.allow_unlinked_reply?(connection, 1)
      refute Limiter.allow_unlinked_reply?(connection, 1)
      assert Limiter.allow_unlinked_reply?(connection, 2)
    end

    test "twenty a minute for the bot, and a new minute starts again" do
      # A clock that stands still, so that the minute cannot change in the middle.
      minute_start = div(System.system_time(:millisecond), 60_000) * 60_000
      Application.put_env(:phoenix_kit_agent, :telegram_now_ms, minute_start)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :telegram_now_ms) end)

      connection = UUIDv7.generate()
      allowed = for chat <- 1..30, do: Limiter.allow_unlinked_reply?(connection, chat)

      assert Enum.count(allowed, & &1) == 20
      assert Limiter.allow_unlinked_reply?(UUIDv7.generate(), 1)

      Application.put_env(:phoenix_kit_agent, :telegram_now_ms, minute_start + 60_000)
      assert Limiter.allow_unlinked_reply?(connection, 31)
    end

    test "ten presses of buttons a minute for a chat, and the table is cleaned of old minutes" do
      minute_start = div(System.system_time(:millisecond), 60_000) * 60_000
      Application.put_env(:phoenix_kit_agent, :telegram_now_ms, minute_start)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :telegram_now_ms) end)

      connection = UUIDv7.generate()
      allowed = for _ <- 1..15, do: Limiter.allow_press?(connection, 1)

      assert Enum.count(allowed, & &1) == 10
      assert Limiter.allow_press?(connection, 2)
      assert Limiter.allow_press?(UUIDv7.generate(), 1)

      Application.put_env(:phoenix_kit_agent, :telegram_now_ms, minute_start + 60_000)
      assert Limiter.allow_press?(connection, 1)

      send(Process.whereis(Limiter), :sweep)
      _ = :sys.get_state(Limiter)

      old =
        :ets.select(Limiter, [
          {{{:press, connection, :"$1", :"$2"}, :_}, [], [{{:"$1", :"$2"}}]}
        ])

      assert old == [{1, div(minute_start + 60_000, 60_000)}]
    end

    test "a linked chat gets an answer without a turn once in a while" do
      connection = UUIDv7.generate()
      Application.put_env(:phoenix_kit_agent, :telegram_quick_reply_ms, 3_000)
      on_exit(fn -> Application.put_env(:phoenix_kit_agent, :telegram_quick_reply_ms, 0) end)

      now = System.system_time(:millisecond)
      Application.put_env(:phoenix_kit_agent, :telegram_now_ms, now)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :telegram_now_ms) end)

      assert Limiter.allow_quick_reply?(connection, 1, :help)
      refute Limiter.allow_quick_reply?(connection, 1, :help)
      assert Limiter.allow_quick_reply?(connection, 2, :help)
      # A refusal right after the help is still told.
      assert Limiter.allow_quick_reply?(connection, 1, :wait)

      Application.put_env(:phoenix_kit_agent, :telegram_now_ms, now + 3_001)
      assert Limiter.allow_quick_reply?(connection, 1, :help)
    end
  end
end
