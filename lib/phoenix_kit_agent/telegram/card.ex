defmodule PhoenixKitAgent.Telegram.Card do
  @moduledoc """
  The card of a held change as the bot shows it in a chat: plain text made of
  core's preview of the change (`PhoenixKit.API.Approvals.View.preview/1`: a
  summary, the rows with "field: was → becomes", warnings, "and N more") and
  the buttons under it, ✅ and ❌.

  `build/3` reads the preview with the chat's own reference
  (`PhoenixKit.API.Confirm.get_for_user/2`, live: the link, the account and
  the right to the tool are checked again) and says what the message is to
  show now (`mode`):

    * `:open` — the change waits: the preview and both buttons. When the
      preview does not fit (core's `technical` remainder is cut at 1500
      characters), only ❌ is offered, with "confirm on the site";
    * `{:note, text}` — the same, with a line under it (the press that could
      not be carried out);
    * `{:outcome, outcome}` — what became of it (`confirmed`, `rejected`,
      `expired`, `changed`, `failed`), without buttons, with the preview's
      summary when it can be read;
    * `:expired`, `:processed`, `:unavailable` — the refusals of a press, the
      same without buttons.

  When the user may no longer use the tool of an open card (`:forbidden`)
  the card says so and offers ❌ alone; a row of another origin or one that
  cannot be read says the change cannot be confirmed here. The text is at
  most 4096 characters. The button data is `"c:"` or `"x:"` and the
  confirmation's uuid, 38 bytes: no tool name, no arguments, no user.
  """

  use Gettext, backend: PhoenixKitAgent.Gettext

  alias PhoenixKit.API.Approvals.View
  alias PhoenixKitAgent.Config
  alias PhoenixKitAgent.Telegram.Format

  # Telegram's limit is 4096 UTF-16 units; a little room is left.
  @max_units 4_000
  @rows_budget 3_000
  @technical_chars 1_500

  @type mode ::
          :open
          | {:note, String.t()}
          | {:outcome, String.t()}
          | :expired
          | :processed
          | :unavailable

  @type built :: %{text: String.t(), markup: map() | nil}

  @doc "The text and the buttons of the card `confirmation_uuid` for `ref` in `mode`."
  @spec build(PhoenixKitAgent.Telegram.Bridge.ref(), String.t(), mode()) :: built()
  def build(_ref, confirmation_uuid, mode) when mode in [:processed, :unavailable],
    do: render(nil, confirmation_uuid, mode)

  def build(ref, confirmation_uuid, mode) do
    read = Config.core(:confirm).get_for_user(confirmation_uuid, ref)
    render(read, confirmation_uuid, mode)
  end

  @doc false
  # `build/3` for a read of the row that was done already.
  @spec render(term(), String.t(), mode()) :: built()
  def render(read, confirmation_uuid, :open), do: open(read, confirmation_uuid, nil)
  def render(read, confirmation_uuid, {:note, note}), do: open(read, confirmation_uuid, note)

  def render(read, _confirmation_uuid, {:outcome, outcome}),
    do: closed(outcome_text(outcome), read)

  def render(read, _confirmation_uuid, :expired), do: closed(outcome_text("expired"), read)
  def render(_read, _confirmation_uuid, :processed), do: closed(gettext("Already handled."), nil)

  def render(_read, _confirmation_uuid, :unavailable),
    do: closed(gettext("This change is no longer available."), nil)

  @doc "The inline keyboard of a card: `:both` or `:reject` (❌ alone)."
  @spec buttons(String.t(), :both | :reject) :: map()
  def buttons(confirmation_uuid, :both) do
    %{
      "inline_keyboard" => [
        [
          %{"text" => gettext("✅ Confirm"), "callback_data" => "c:" <> confirmation_uuid},
          %{"text" => gettext("❌ Cancel"), "callback_data" => "x:" <> confirmation_uuid}
        ]
      ]
    }
  end

  def buttons(confirmation_uuid, :reject) do
    %{
      "inline_keyboard" => [
        [%{"text" => gettext("❌ Cancel"), "callback_data" => "x:" <> confirmation_uuid}]
      ]
    }
  end

  @doc "The headline of a card by its outcome."
  @spec outcome_text(String.t()) :: String.t()
  def outcome_text("confirmed"), do: gettext("✅ Done")
  def outcome_text("rejected"), do: gettext("❌ Cancelled")
  def outcome_text("expired"), do: gettext("⌛ The time to confirm ran out. Ask again.")
  def outcome_text("changed"), do: gettext("The data changed under the preview.")
  def outcome_text("failed"), do: gettext("The change could not be made.")
  def outcome_text(_other), do: gettext("Already handled.")

  # ── an open card ──────────────────────────────────────────────────

  # A card whose preview does not fit whole is never offered for ✅: the person
  # would confirm what they cannot read. It shows what fits and sends them to
  # the site, with ❌ alone.
  defp open({:ok, %{status: "unused", preview: preview}}, confirmation_uuid, note) do
    %{summary: summary, lines: lines, technical_cut?: cut?} = body(preview)
    head = gettext("Confirm this change:")
    whole = Enum.join([head | lines] ++ note_lines(note), "\n")

    if cut? or Format.units(whole) > @max_units do
      too_large = gettext("This change is too large to confirm here. Confirm it on the site.")
      text = fit([head | summary] ++ [too_large] ++ note_lines(note))
      %{text: text, markup: buttons(confirmation_uuid, :reject)}
    else
      %{text: whole, markup: buttons(confirmation_uuid, :both)}
    end
  end

  defp open({:ok, %{status: status}}, _confirmation_uuid, _note) when status != "unused",
    do: %{text: gettext("Already handled."), markup: nil}

  defp open({:error, :forbidden}, confirmation_uuid, note) do
    text =
      fit([gettext("Not allowed: you have no right to make this change.")] ++ note_lines(note))

    %{text: text, markup: buttons(confirmation_uuid, :reject)}
  end

  defp open(_unreadable, _confirmation_uuid, _note) do
    %{text: gettext("This change cannot be confirmed here. Open the site."), markup: nil}
  end

  defp note_lines(nil), do: []
  defp note_lines(note), do: ["", note]

  # ── a closed card ─────────────────────────────────────────────────

  defp closed(headline, {:ok, %{preview: preview}}) when is_map(preview) do
    %{lines: lines} = body(preview, summary_only: true)
    %{text: fit([headline | lines]), markup: nil}
  end

  defp closed(headline, _unreadable), do: %{text: fit([headline]), markup: nil}

  # ── the preview as text ───────────────────────────────────────────

  defp body(preview, opts \\ []) do
    view = View.preview(preview)
    summary = Enum.map(view.summary, fn {label, value} -> "#{label}: #{value_text(value)}" end)

    if opts[:summary_only] do
      %{summary: summary, lines: summary, technical_cut?: false}
    else
      {rows, hidden} = rows(view)
      {technical, cut?} = technical(view.technical)

      lines =
        summary ++
          rows ++
          hidden_line(hidden) ++
          Enum.map(view.warnings, &("⚠ " <> &1)) ++ technical

      %{summary: summary, lines: lines, technical_cut?: cut?}
    end
  end

  # As many rows as fit; the rest are counted.
  defp rows(view) do
    {lines, _used, shown} =
      Enum.reduce_while(view.rows, {[], 0, 0}, fn row, {acc, used, count} ->
        text = row_text(row)
        size = Format.units(text) + 1

        if used + size > @rows_budget and count > 0,
          do: {:halt, {acc, used, count}},
          else: {:cont, {[text | acc], used + size, count + 1}}
      end)

    {Enum.reverse(lines), view.hidden + (length(view.rows) - shown)}
  end

  defp hidden_line(0), do: []
  defp hidden_line(count), do: [gettext("…and %{count} more", count: count)]

  defp row_text(row) do
    head = "• " <> row.label <> if(row.sub, do: " (#{row.sub})", else: "")
    head = if row.action, do: head <> " — " <> row.action, else: head

    changes =
      for change <- row.changes do
        pct = if change.pct, do: " (#{change.pct}%)", else: ""
        "  #{change.field}: #{value_text(change.from)} → #{value_text(change.to)}#{pct}"
      end

    problems =
      Enum.map(row.warnings, &("  ⚠ " <> &1)) ++
        if(row.error, do: ["  ✖ " <> row.error], else: []) ++
        Enum.map(row.error_reasons, &("  ✖ " <> &1))

    Enum.join([head | changes ++ problems], "\n")
  end

  defp technical(nil), do: {[], false}

  defp technical(map) do
    json = Jason.encode!(map, pretty: true)

    if String.length(json) > @technical_chars,
      do: {[gettext("Technical details:"), String.slice(json, 0, @technical_chars) <> "…"], true},
      else: {[gettext("Technical details:"), json], false}
  rescue
    _unencodable -> {[gettext("Technical details:"), "…"], true}
  end

  defp value_text(nil), do: "—"
  defp value_text(value) when is_binary(value), do: value
  defp value_text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp value_text(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp value_text(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> "…"
    end
  end

  # At most @max_units UTF-16 units, cut on a character boundary.
  defp fit(lines) do
    text = Enum.join(lines, "\n")

    if Format.units(text) > @max_units,
      do: take_units(text, @max_units - 1) <> "…",
      else: text
  end

  defp take_units(text, limit) do
    {kept, _used} =
      text
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn grapheme, {acc, used} ->
        size = Format.units(grapheme)

        if used + size > limit,
          do: {:halt, {acc, used}},
          else: {:cont, {[grapheme | acc], used + size}}
      end)

    kept |> Enum.reverse() |> Enum.join()
  end
end
