defmodule PhoenixKitAgent.TranslationsTest do
  @moduledoc """
  The catalogues of `priv/gettext`: every message of the template is
  translated in every language of the set (et, ru, uk, fr, de) and in `en`,
  with the placeholders of the source text and the plural forms of the language.
  """

  use ExUnit.Case, async: true

  alias Expo.Message
  alias Expo.Messages
  alias Expo.PO
  alias PhoenixKitAgent.Web.Dock.Texts

  @root Path.expand("../../priv/gettext", __DIR__)
  @languages ~w(en et ru uk fr de)
  @plurals %{"en" => 2, "et" => 2, "ru" => 3, "uk" => 3, "fr" => 2, "de" => 2}

  defp parse!(path) do
    {:ok, %Messages{messages: messages}} = PO.parse_file(path)
    Enum.reject(messages, &(Message.key(&1) == {"", nil} or &1.msgid == [""]))
  end

  defp template, do: parse!(Path.join(@root, "default.pot"))
  defp catalogue(language), do: parse!(Path.join([@root, language, "LC_MESSAGES", "default.po"]))

  defp text(parts), do: IO.iodata_to_binary(parts)

  defp placeholders(string),
    do:
      ~r/%\{(\w+)\}/
      |> Regex.scan(string, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()
      |> Enum.uniq()

  test "the set of languages is exactly the one of the catalogue module" do
    dirs = @root |> File.ls!() |> Enum.reject(&String.ends_with?(&1, ".pot")) |> Enum.sort()
    assert dirs == Enum.sort(@languages)
  end

  # Texts that read the same in a language: a unit, a name.
  @same %{
    "et" => ["MB", "s"],
    "de" => ["MB", "s", "Limits"],
    "fr" => ["s", "Message", "Assistant"]
  }

  test "the template has messages" do
    assert length(template()) > 150
  end

  for language <- @languages do
    describe "#{language}" do
      test "has every message of the template, translated" do
        translated = Map.new(catalogue(unquote(language)), &{text(&1.msgid), &1})
        template_ids = template() |> Enum.map(&text(&1.msgid)) |> MapSet.new()

        assert MapSet.new(Map.keys(translated)) == template_ids

        for %Message.Singular{msgid: id} <- template() do
          msgstr = translated |> Map.fetch!(text(id)) |> Map.fetch!(:msgstr) |> text()
          assert msgstr != "", "#{unquote(language)}: empty translation of #{inspect(text(id))}"
        end
      end

      test "has no message left in English" do
        same = Map.get(@same, unquote(language), [])

        for %Message.Singular{msgid: id, msgstr: msgstr} <- catalogue(unquote(language)),
            unquote(language) != "en",
            text(id) == text(msgstr) do
          assert text(id) in same, "#{unquote(language)}: #{inspect(text(id))} is not translated"
        end
      end

      test "keeps the placeholders of the source text, and the plural forms of the language" do
        for message <- catalogue(unquote(language)) do
          id = text(message.msgid)

          case message do
            %Message.Singular{msgstr: msgstr} ->
              assert placeholders(text(msgstr)) == placeholders(id),
                     "#{unquote(language)}: placeholders of #{inspect(id)}"

            %Message.Plural{msgstr: forms} ->
              allowed = placeholders(id) ++ placeholders(text(message.msgid_plural))
              assert map_size(forms) == @plurals[unquote(language)]

              for {n, form} <- forms do
                assert text(form) != "", "#{unquote(language)}: empty form #{n} of #{inspect(id)}"
                assert placeholders(text(form)) -- allowed == []
              end
          end
        end
      end
    end
  end

  test "the texts of the refusals and notices come out in the language of the panel" do
    texts = fn locale ->
      Gettext.with_locale(PhoenixKitAgent.Gettext, locale, fn ->
        {Texts.refusal(:empty_message), Texts.notice("deadline")}
      end)
    end

    assert {"Write a message first.", _} = texts.("en")
    assert {"Kirjuta esmalt sõnum.", _} = texts.("et")
    assert {"Сначала напишите сообщение.", _} = texts.("ru")
    assert {"Спочатку напишіть повідомлення.", _} = texts.("uk")
    assert {"Écrivez d'abord un message.", _} = texts.("fr")
    assert {"Schreiben Sie zuerst eine Nachricht.", _} = texts.("de")
  end

  test "the AI guard's notices, refusals and attachment codes have their own texts, in every language" do
    codes =
      ~w(task_blocked task_limit_exceeded model_unfit model_unverified no_provider_for_params)

    general = Texts.refusal(:something_unknown)
    unread = Texts.attachment_error("something_unknown")

    texts = fn locale ->
      Gettext.with_locale(PhoenixKitAgent.Gettext, locale, fn ->
        Enum.map(codes, &Texts.notice/1) ++
          Enum.map(codes, &Texts.attachment_error/1) ++
          [
            Texts.refusal(:task_blocked),
            Texts.refusal(:task_limit_exceeded),
            Texts.refusal({:task_blocked, "free_text"}),
            Texts.refusal({:task_limit_exceeded, :task, :requests, :day})
          ]
      end)
    end

    english = texts.("en")
    assert Enum.all?(english, &is_binary/1)
    refute general in english
    refute unread in english

    for locale <- @languages -- ["en"] do
      translated = texts.(locale)
      assert Enum.all?(translated, &is_binary/1), locale

      for {mine, en} <- Enum.zip(translated, english),
          do: assert(mine != en, "#{locale}: #{inspect(en)} is in English")
    end
  end

  test "an account out of credit is told in every language, without a provider or a retry" do
    texts =
      Map.new(@languages, fn locale ->
        {locale,
         Gettext.with_locale(PhoenixKitAgent.Gettext, locale, fn ->
           Texts.notice("insufficient_credits")
         end)}
      end)

    assert texts["en"] ==
             "The AI account behind the assistant has run out of credit. " <>
               "An administrator has to top it up or choose another model."

    assert texts["ru"] =~ "закончились средства"
    assert texts["et"] =~ "krediit on otsas"
    assert texts["uk"] =~ "закінчилися кошти"
    assert texts["fr"] =~ "n'a plus de crédit"
    assert texts["de"] =~ "kein Guthaben mehr"

    for {locale, text} <- texts do
      refute text =~ ~r/Z\.ai|OpenAI|Anthropic|OpenRouter|try again/i,
             "#{locale}: #{inspect(text)}"

      rate_limited =
        Gettext.with_locale(PhoenixKitAgent.Gettext, locale, fn ->
          Texts.notice("rate_limited")
        end)

      assert text != rate_limited
    end
  end

  test "the labels of the permission and of the tabs are in the catalogues" do
    meta = PhoenixKitAgent.permission_metadata()

    labels = [
      meta.label,
      meta.description | Enum.flat_map(meta.sub_permissions, &[&1.label, &1.description])
    ]

    tabs = PhoenixKitAgent.admin_tabs() ++ PhoenixKitAgent.settings_tabs()
    ids = template() |> Enum.map(&text(&1.msgid)) |> MapSet.new()

    for label <- labels ++ Enum.map(tabs, & &1.label) do
      assert label in ids, "no message for #{inspect(label)}"
    end

    et =
      Gettext.with_locale(PhoenixKitAgent.Gettext, "et", fn ->
        Gettext.dgettext(PhoenixKitAgent.Gettext, "default", "Spending")
      end)

    assert et == "Kulud"
  end

  test "the type of the limit notification is translated where it is read" do
    for {locale, expected} <- [{"et", "AI-assistendi limiidid"}, {"ru", "Лимиты AI-ассистента"}] do
      label =
        Gettext.with_locale(PhoenixKitAgent.Gettext, locale, fn ->
          [%{label: label}] = PhoenixKitAgent.notification_types()
          label
        end)

      assert label == expected
    end
  end
end
