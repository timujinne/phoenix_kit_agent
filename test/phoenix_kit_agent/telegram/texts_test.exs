defmodule PhoenixKitAgent.Telegram.TextsTest do
  @moduledoc "What the bot says in place of a code: no word of the chat panel's buttons."

  use ExUnit.Case, async: true

  alias PhoenixKitAgent.Telegram.Texts
  alias PhoenixKitAgent.Web.Dock.Texts, as: Panel

  test "a message that is too long is not told to be sent as a file" do
    text = Texts.refusal(:message_too_long)

    refute text =~ ~r/file/i
    refute text == Panel.refusal(:message_too_long)
  end

  test "a change being confirmed is a change confirmed on the site" do
    assert Texts.refusal(:click_in_flight) =~ "on the site"
    refute Texts.refusal(:click_in_flight) == Panel.refusal(:click_in_flight)
  end

  test "a chat busy with an answer is told to wait, not to press Stop" do
    refute Texts.refusal(:conversation_busy) =~ "Stop"
  end

  test "both are told in every language of the module" do
    for locale <- ~w(et ru uk fr de) do
      Gettext.with_locale(PhoenixKitAgent.Gettext, locale, fn ->
        refute Texts.refusal(:message_too_long) ==
                 "That message is too long for me. Write a shorter one."

        refute Texts.refusal(:click_in_flight) ==
                 "A change is being confirmed on the site. Write again in a moment."
      end)
    end
  end
end
