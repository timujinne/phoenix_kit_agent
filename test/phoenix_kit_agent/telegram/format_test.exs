defmodule PhoenixKitAgent.Telegram.FormatTest do
  use ExUnit.Case, async: true

  alias PhoenixKitAgent.Telegram.Format

  describe "plain/1" do
    test "takes out bold markers" do
      assert Format.plain("This is **bold** and __this__.") == "This is bold and this."
    end

    test "takes out heading markers at the start of a line only" do
      assert Format.plain("# Title\n## Sub\nOrder #1234 is paid\n#5 first") ==
               "Title\nSub\nOrder #1234 is paid\n#5 first"
    end

    test "turns a markdown link into text and address" do
      assert Format.plain("See [the order](https://shop.example/admin/orders/5) now") ==
               "See the order https://shop.example/admin/orders/5 now"
    end

    test "a link whose text is its address is written once" do
      assert Format.plain("[https://a.example/x](https://a.example/x)") == "https://a.example/x"
    end

    test "leaves plain text alone" do
      assert Format.plain("Three orders: A-1, A-2 and A-3.") == "Three orders: A-1, A-2 and A-3."
    end
  end

  describe "plain/1 and addresses" do
    test "underscores inside an address stay" do
      assert Format.plain("See https://shop.example/a__b/c now") ==
               "See https://shop.example/a__b/c now"
    end

    test "emphasis around an address goes, the address stays" do
      assert Format.plain("**https://shop.example/a__b**") == "https://shop.example/a__b"

      assert Format.plain("__bold__ and https://x.example/p__q") ==
               "bold and https://x.example/p__q"
    end

    test "the address of a link with underscores is kept" do
      assert Format.plain("[Orders](https://x.example/orders__all)") ==
               "Orders https://x.example/orders__all"
    end
  end

  describe "chunks/2 and a character longer than a message" do
    test "is cut by code points, with no empty part" do
      long = "e" <> String.duplicate("\u0301", 10)
      parts = Format.chunks(long, 4)

      assert Enum.all?(parts, &(&1 != "" and Format.units(&1) <= 4))
      assert Enum.join(parts) == long
    end
  end

  describe "chunks/2" do
    test "a character of several code points is not cut" do
      flag = "🇪🇪"
      parts = Format.chunks(String.duplicate(flag, 3), 5)

      assert parts == [flag, flag, flag]
      assert Enum.all?(parts, &(Format.units(&1) <= 5))
    end

    test "a short text is one message" do
      assert Format.chunks("Hello") == ["Hello"]
      assert Format.chunks("") == []
    end

    test "paragraphs are packed into messages that fit" do
      paragraph = String.duplicate("a", 3_000)
      assert Format.chunks(paragraph <> "\n\n" <> paragraph) == [paragraph, paragraph]
      assert Format.chunks("one\n\ntwo\n\nthree") == ["one\n\ntwo\n\nthree"]
    end

    test "a paragraph of 5000 characters is cut by words" do
      text = String.duplicate("word ", 1_000) |> String.trim()
      parts = Format.chunks(text)

      assert length(parts) == 2
      assert Enum.all?(parts, &(Format.units(&1) <= 4_096))
      assert Enum.join(parts, " ") == text
    end

    test "a word longer than a message is cut by characters" do
      text = String.duplicate("x", 5_000)
      parts = Format.chunks(text)

      assert Enum.map(parts, &Format.units/1) == [4_096, 904]
      assert Enum.join(parts) == text
    end

    test "an emoji on the boundary is never split, and counts as two units" do
      text = String.duplicate("a", 4_095) <> "😀" <> String.duplicate("b", 10)
      parts = Format.chunks(text)

      assert Enum.all?(parts, &String.valid?/1)
      assert Enum.all?(parts, &(Format.units(&1) <= 4_096))
      assert Enum.join(parts) == text
      assert hd(parts) == String.duplicate("a", 4_095)
    end

    test "units/1 counts UTF-16 code units" do
      assert Format.units("abc") == 3
      assert Format.units("é") == 1
      assert Format.units("😀") == 2
    end
  end
end
