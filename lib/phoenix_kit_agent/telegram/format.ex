defmodule PhoenixKitAgent.Telegram.Format do
  @moduledoc """
  An answer of the model made fit for a Telegram chat, which gets plain text.

    * `plain/1` takes out the markdown the model may still use: `**` and `__`,
      heading markers at the start of a line (`# Title`; a `#` inside a line,
      as in "order #1234", stays), and turns `[text](https://…)` into
      `text https://…`;
    * `chunks/1` cuts a text into messages of at most 4096 UTF-16 units
      (what Telegram counts), by paragraph, a long paragraph by words and a
      word that is longer than a message by characters — never inside a
      surrogate pair.
  """

  @limit 4096

  @doc "The text without markdown (see the moduledoc)."
  @spec plain(String.t()) :: String.t()
  def plain(text) when is_binary(text) do
    text
    |> then(
      &Regex.replace(~r/\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/u, &1, fn _, label, url ->
        if label == url, do: label, else: label <> " " <> url
      end)
    )
    |> String.replace(["**", "__"], "")
    |> String.replace(~r/^[ \t]*\#{1,6}[ \t]+/mu, "")
    |> String.trim()
  end

  @doc "The messages of `text`, none longer than `limit` (default 4096) UTF-16 units."
  @spec chunks(String.t(), pos_integer()) :: [String.t()]
  def chunks(text, limit \\ @limit) when is_binary(text) do
    text
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.flat_map(&fit_paragraph(&1, limit))
    |> pack(limit)
  end

  @doc "The length of `text` in UTF-16 code units."
  @spec units(String.t()) :: non_neg_integer()
  def units(text) when is_binary(text) do
    for <<cp::utf8 <- text>>, reduce: 0 do
      acc -> acc + if(cp > 0xFFFF, do: 2, else: 1)
    end
  end

  # Paragraphs joined by a blank line while they fit.
  defp pack(parts, limit) do
    parts
    |> Enum.reduce([], fn part, acc ->
      case acc do
        [last | rest] ->
          if units(last) + 2 + units(part) <= limit,
            do: [last <> "\n\n" <> part | rest],
            else: [part | acc]

        [] ->
          [part]
      end
    end)
    |> Enum.reverse()
  end

  defp fit_paragraph(paragraph, limit) do
    if units(paragraph) <= limit, do: [paragraph], else: by_words(paragraph, limit)
  end

  defp by_words(paragraph, limit) do
    paragraph
    |> String.split(" ")
    |> Enum.flat_map(&split_long(&1, limit))
    |> Enum.reduce([], fn word, acc ->
      case acc do
        [last | rest] ->
          if units(last) + 1 + units(word) <= limit,
            do: [last <> " " <> word | rest],
            else: [word | acc]

        [] ->
          [word]
      end
    end)
    |> Enum.reverse()
  end

  defp split_long(word, limit) do
    if units(word) <= limit, do: [word], else: by_characters(word, limit)
  end

  defp by_characters(word, limit) do
    {parts, current, _units} =
      word
      |> String.codepoints()
      |> Enum.reduce({[], "", 0}, fn cp, {parts, current, size} ->
        width = units(cp)

        if size + width > limit,
          do: {[current | parts], cp, width},
          else: {parts, current <> cp, size + width}
      end)

    Enum.reverse([current | parts])
  end
end
