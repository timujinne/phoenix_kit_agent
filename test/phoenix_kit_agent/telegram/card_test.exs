defmodule PhoenixKitAgent.Telegram.CardTest do
  @moduledoc """
  The card of a held change as text and buttons, from what core's
  `Confirm.get_for_user/2` returned for it (`PhoenixKitAgent.Telegram.Card`).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAgent.Telegram.Card

  @uuid "0192f3a4-7b1c-7d2e-8f3a-123456789abc"

  defp held(preview), do: {:ok, %{status: "unused", preview: preview}}

  defp preview(rows, extra \\ %{}) do
    Map.merge(
      %{"rows" => rows, "totals" => %{"rows" => length(rows), "update" => length(rows)}},
      extra
    )
  end

  defp row(n, changes \\ nil) do
    %{
      "ref" => "SKU-#{n}",
      "name" => "Oak shelf #{n}",
      "action" => "update",
      "changes" => changes || %{"price" => %{"from" => "10.00", "to" => "12.50"}},
      "warnings" => ["Below cost"]
    }
  end

  describe "an open card" do
    test "the summary, the rows with was → becomes and the warnings, and both buttons" do
      %{text: text, markup: markup} =
        Card.render(
          held(preview([row(1)], %{"warnings" => ["Prices are in euro"]})),
          @uuid,
          :open
        )

      assert text =~ "Confirm this change:"
      assert text =~ "update: 1"
      assert text =~ "• Oak shelf 1 (SKU-1) — update"
      assert text =~ "price: 10.00 → 12.50 (+25.0%)"
      assert text =~ "⚠ Below cost"
      assert text =~ "⚠ Prices are in euro"

      assert [[confirm, cancel]] = markup["inline_keyboard"]
      assert confirm["callback_data"] == "c:" <> @uuid
      assert cancel["callback_data"] == "x:" <> @uuid
      assert byte_size(confirm["callback_data"]) == 38
    end

    test "many rows are counted past what fits, and the text stays within Telegram's limit" do
      rows =
        for n <- 1..25,
            do: row(n, %{"description" => %{"from" => "a", "to" => String.duplicate("x", 300)}})

      preview = preview(rows, %{"totals" => %{"rows" => 90, "update" => 90}})

      %{text: text} = Card.render(held(preview), @uuid, :open)

      assert String.length(text) <= 4096
      assert text =~ ~r/…and \d+ more/
    end

    test "a preview the common shape does not hold: the technical details, cut, and ❌ alone" do
      big = %{"rows" => [row(1)], "extra" => String.duplicate("z", 3_000)}
      %{text: text, markup: markup} = Card.render(held(big), @uuid, :open)

      assert text =~ "Technical details:"
      assert text =~ "Confirm it on the site"
      assert String.length(text) <= 4096
      assert [[%{"callback_data" => "x:" <> @uuid}]] = markup["inline_keyboard"]
    end

    test "technical details that fit keep both buttons" do
      %{markup: markup, text: text} =
        Card.render(held(%{"rows" => [row(1)], "extra" => "small"}), @uuid, :open)

      assert text =~ "Technical details:"
      assert [[_, _]] = markup["inline_keyboard"]
    end

    test "a line can be put under it" do
      %{text: text, markup: markup} =
        Card.render(held(preview([row(1)])), @uuid, {:note, "⏳ wait"})

      assert String.ends_with?(text, "⏳ wait")
      assert [[_, _]] = markup["inline_keyboard"]
    end

    test "the user may not use its tool: it says so, and only ❌ is there" do
      %{text: text, markup: markup} = Card.render({:error, :forbidden}, @uuid, :open)

      assert text =~ "no right"
      assert [[%{"callback_data" => "x:" <> @uuid}]] = markup["inline_keyboard"]
    end

    test "a row of another origin, or one that cannot be read: no buttons, the site" do
      for read <- [{:error, :foreign}, {:error, :unauthorized}, {:error, :unknown}, nil] do
        assert %{text: text, markup: nil} = Card.render(read, @uuid, :open)
        assert text =~ "Open the site"
      end
    end
  end

  describe "a closed card" do
    test "done: the headline and the summary, never the rows or the details of the call" do
      %{text: text, markup: nil} =
        Card.render(
          {:ok, %{status: "used", preview: preview([row(1)])}},
          @uuid,
          {:outcome, "confirmed"}
        )

      assert text == "✅ Done\nupdate: 1"
    end

    test "each outcome has its words, and no buttons" do
      for {outcome, words} <- [
            {"rejected", "❌ Cancelled"},
            {"expired", "ran out"},
            {"changed", "The data changed"},
            {"failed", "could not be made"}
          ] do
        assert %{text: text, markup: nil} =
                 Card.render({:error, :forbidden}, @uuid, {:outcome, outcome})

        assert text =~ words
      end
    end

    test "when the preview cannot be read, the outcome alone" do
      assert %{text: "✅ Done", markup: nil} =
               Card.render({:error, :unauthorized}, @uuid, {:outcome, "confirmed"})
    end

    test "the refusals of a press" do
      assert %{text: "Already handled.", markup: nil} = Card.render(nil, @uuid, :processed)

      assert %{text: "This change is no longer available.", markup: nil} =
               Card.render(nil, @uuid, :unavailable)

      assert %{text: "⌛" <> _, markup: nil} = Card.render(nil, @uuid, :expired)
    end
  end
end
