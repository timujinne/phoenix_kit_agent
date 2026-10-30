defmodule PhoenixKitAgent.Turns.HistoryTest do
  @moduledoc """
  What the model reads of attachments and of the outcome of a confirmation:
  a ready attachment names its Storage file, a confirmed write that counted
  its rows says the numbers.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAgent.Schemas.{Attachment, Message}
  alias PhoenixKitAgent.Turns.History

  @file_uuid "0192b1c0-aaaa-7000-8000-000000000001"
  @message_uuid "0192b1c0-bbbb-7000-8000-000000000002"
  @card_uuid "0192b1c0-cccc-7000-8000-000000000003"

  defp attachment(attrs) do
    struct(
      Attachment,
      Map.merge(
        %{
          filename: "kitchen.jpg",
          kind: "image",
          status: "ready",
          file_uuid: @file_uuid,
          message_uuid: @message_uuid,
          extracted_text: nil,
          truncated: false
        },
        attrs
      )
    )
  end

  defp notice(tool_result) do
    %Message{
      role: "notice",
      confirmation_uuid: @card_uuid,
      tool_outcome: "confirmed",
      tool_name: "agenttest.write_item",
      content: "The change was made.",
      tool_result: tool_result
    }
  end

  defp contents(messages),
    do:
      messages
      |> History.build([], %{role: "user", content: "next"}, 10_000)
      |> Enum.map(& &1.content)

  describe "attachments" do
    test "a ready picture names its file and the original name" do
      content = History.user_content("Look", [attachment(%{})], 10_000)

      assert content =~ "[Attachment: kitchen.jpg - a picture"
      assert content =~ "(file_uuid: #{@file_uuid})"
    end

    test "a ready text names its file too, before the text" do
      text = attachment(%{kind: "text", filename: "notes.txt", extracted_text: "Sofa 3 pcs"})
      content = History.user_content("Read", [text], 10_000)

      assert content =~ "[Attachment: notes.txt] (file_uuid: #{@file_uuid})\nSofa 3 pcs"
    end

    test "it is there in a later turn: the history of the earlier message carries it" do
      earlier = %Message{uuid: @message_uuid, role: "user", content: "Look"}

      history =
        History.build([earlier], [attachment(%{})], %{role: "user", content: "And now?"}, 10_000)

      assert [%{content: first}, %{content: "And now?"}] = history
      assert first =~ "(file_uuid: #{@file_uuid})"
    end

    test "a failed or pending one names no file" do
      for status <- ["failed", "pending"] do
        content =
          History.user_content("Look", [attachment(%{status: status})], 10_000)

        refute content =~ "file_uuid"
      end
    end
  end

  describe "the outcome of a confirmed write" do
    test "with counts, says the numbers" do
      assert ["[confirmation] done: agenttest_write_item (7 of 10 succeeded, 3 failed)", "next"] =
               contents([notice(%{"ok" => 7, "failed" => 3})])
    end

    test "with no counts, is as it was" do
      assert ["[confirmation] done: agenttest_write_item", "next"] = contents([notice(nil)])
    end

    test "counts that are not two integers are not told" do
      for bad <- [%{"ok" => "7", "failed" => 3}, %{"ok" => 7}, %{"ok" => -1, "failed" => 0}] do
        assert ["[confirmation] done: agenttest_write_item", "next"] = contents([notice(bad)])
      end
    end

    test "a notice of another outcome never carries them" do
      rejected = %{notice(%{"ok" => 1, "failed" => 0}) | tool_outcome: "rejected"}
      assert ["[confirmation] cancelled: agenttest_write_item", "next"] = contents([rejected])
    end
  end
end
