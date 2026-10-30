defmodule PhoenixKitAgent.AttachmentsTest do
  @moduledoc """
  Files attached to a chat (spec §5.3, §9): accepted for the session's own
  chat only, kept in the module's hidden Storage library in the user's folder,
  and processed in a task before the turn — PDF and text to text, a scan and a
  picture to pixels for a model that sees or to a description for one that does
  not, a sheet to CSV.

  Real bytes go through a real local bucket; the models are `Req.Test` stubs of
  the provider behind `phoenix_kit_ai`; `pdftotext`/`pdftoppm`/ImageMagick are
  the real programs (the tests that need them are tagged `:poppler` and
  `:imagemagick`, and are excluded — loudly — where they are not installed).
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{ImageProcessor, Libraries, URLSigner}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKitAgent.{Attachments, Conversations, Library, Turns}
  alias PhoenixKitAgent.Attachments.{Processor, Slots, Work}
  alias PhoenixKitAgent.Schemas.{Attachment, Message, UserSettings}
  alias PhoenixKitAgent.Test.{Files, LogProbe}
  alias PhoenixKitAI.Request
  alias PhoenixKitWeb.FileController

  @stub __MODULE__
  @me [impersonated: false]
  @secret "SECRET-MARKER-4f7a"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    bucket = Files.local_bucket!()

    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

    chat_endpoint = endpoint_fixture(%{name: "Chat", model: "a/chat"})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", chat_endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentFiles#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("files")
    {:ok, _} = Roles.assign_role(user, role.name)

    {ref, token} = session_fixture(user)
    chat = conversation_fixture(user)
    :ok = Conversations.subscribe(ref, chat.uuid, @me)

    %{
      user: user,
      role: role,
      ref: ref,
      token: token,
      chat: chat,
      chat_endpoint: chat_endpoint,
      bucket: bucket
    }
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp add(ctx, binary, name, content_type \\ nil) do
    Attachments.add(ctx.ref, ctx.chat.uuid, Files.upload!(binary, name, content_type), @me)
  end

  defp await_done(attachment) do
    chat_uuid = attachment.conversation_uuid
    uuid = attachment.uuid
    assert_receive {:agent_attachment_processed, ^chat_uuid, ^uuid}, 10_000
    Repo.get!(Attachment, uuid)
  end

  defp add_done!(ctx, binary, name, content_type \\ nil) do
    assert {:ok, attachment} = add(ctx, binary, name, content_type)
    assert attachment.status == "pending"
    await_done(attachment)
  end

  # What the AI module knows of a model's images in: what an admin declared
  # on every endpoint of the model ("yes", "no"; nil: nothing, so unknown).
  defp declare_vision!(model, value) do
    settings =
      if value, do: %{"capabilities" => %{"model" => model, "vision" => value}}, else: %{}

    Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.model == ^model),
      set: [provider_settings: settings]
    )
  end

  # A chat model that sees or does not, a vision model that answers with
  # `description`.
  defp serve_ai(opts \\ []) do
    test = self()
    sees? = Keyword.get(opts, :main_sees, true)
    description = Keyword.get(opts, :description, "A grey square that reads SOFA 3 PCS.")
    declare_vision!("a/chat", if(sees?, do: "yes", else: "no"))
    declare_vision!("a/eyes", "yes")

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/api/v1/chat/completions" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test, {:model_request, Jason.decode!(raw)})

          Req.Test.json(conn, %{
            "model" => "a/eyes",
            "choices" => [%{"message" => %{"role" => "assistant", "content" => description}}],
            "usage" => %{"prompt_tokens" => 30, "completion_tokens" => 8, "total_tokens" => 38}
          })
      end
    end)
  end

  defp vision_endpoint!(model \\ "a/eyes") do
    endpoint = endpoint_fixture(%{name: "Eyes", model: model})
    {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", endpoint.uuid)
    endpoint
  end

  defp limits!(user, attrs) do
    %UserSettings{user_uuid: user.uuid}
    |> UserSettings.admin_changeset(attrs)
    |> Repo.insert!(on_conflict: {:replace, Map.keys(attrs)}, conflict_target: :user_uuid)
  end

  defp with_limits(opts) do
    previous = Application.get_env(:phoenix_kit_agent, :attachment_limits)
    Application.put_env(:phoenix_kit_agent, :attachment_limits, opts)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_agent, :attachment_limits, previous),
        else: Application.delete_env(:phoenix_kit_agent, :attachment_limits)
    end)
  end

  # A process that holds one of the user's places for work on files
  # (`Attachments.Slots`) until it is sent `:release`.
  defp hold_place(user) do
    test = self()

    holder =
      spawn_link(fn ->
        send(test, {:held, Slots.acquire(user.uuid)})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:held, :ok}
    holder
  end

  defp storage_file(attachment), do: Repo.get!(Storage.File, attachment.file_uuid)

  # ── what is accepted ────────────────────────────────────────────────

  describe "kinds are told by the content" do
    test "a text file is stored for the user in the module's hidden library", ctx do
      attachment = add_done!(ctx, "Sofa 3 pcs\nTable 1\n", "notes.txt", "text/plain")

      assert attachment.kind == "text"
      assert attachment.status == "ready"
      assert attachment.filename == "notes.txt"
      assert attachment.content_type == "text/plain"
      assert attachment.size_bytes == byte_size("Sofa 3 pcs\nTable 1\n")
      assert attachment.extracted_text == "Sofa 3 pcs\nTable 1\n"
      assert attachment.truncated == false
      assert attachment.user_uuid == ctx.user.uuid
      assert attachment.conversation_uuid == ctx.chat.uuid
      assert attachment.message_uuid == nil

      file = storage_file(attachment)
      {:ok, library} = Library.ensure_library()
      folder = Library.user_folder(ctx.user.uuid)

      assert Libraries.hidden?(library)
      assert file.library_uuid == library.uuid
      assert file.folder_uuid == folder.uuid
      assert folder.name == ctx.user.uuid
      assert file.user_uuid == ctx.user.uuid
    end

    test "a picture named .pdf is a picture; text named .png is no picture; an unknown binary is refused",
         ctx do
      serve_ai()

      image = add_done!(ctx, Files.png(40, 30), "scan.pdf", "application/pdf")
      assert image.kind == "image"
      assert image.content_type == "image/png"

      assert {:error, :unsupported_type} = add(ctx, "just words", "photo.png", "image/png")

      assert {:error, :unsupported_type} =
               add(ctx, <<0, 1, 2, 3, 0, 255, 254, 0>>, "notes.txt", "text/plain")
    end

    test "other documents, archives and executables are refused", ctx do
      docx = Files.zip([{"word/document.xml", "<w:document/>"}])

      for {binary, name} <- [
            {docx, "letter.docx"},
            {"MZ" <> :binary.copy(<<0>>, 64), "tool.exe"},
            {"<svg xmlns='http://www.w3.org/2000/svg'></svg>", "logo.svg"},
            {"GIF89a" <> :binary.copy(<<0>>, 20), "anim.gif"},
            {"<html></html>", "page.html"},
            {"{\"a\":1}", "data.json"},
            {"a text without extension", "README"}
          ] do
        assert {:error, :unsupported_type} = add(ctx, binary, name)
      end

      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "an empty file is refused", ctx do
      assert {:error, :empty_file} = add(ctx, "", "empty.txt")
    end

    test "webp and heic are accepted by their first bytes", ctx do
      serve_ai()
      webp = "RIFF" <> <<12::little-32>> <> "WEBP" <> :binary.copy(<<0>>, 32)
      heic = <<0, 0, 0, 24>> <> "ftypheic" <> :binary.copy(<<0>>, 32)

      for {binary, name, type} <- [
            {webp, "a.bin", "image/webp"},
            {heic, "IMG_0001.HEIC", "image/heic"}
          ] do
        assert {:ok, attachment} = add(ctx, binary, name)
        assert attachment.kind == "image"
        assert attachment.content_type == type
        # Not real pictures: the task says so (and ends), it does not crash.
        assert %{status: "failed"} = await_done(attachment)
      end
    end

    test "the file name is kept as a plain name", ctx do
      upload = %{Files.upload!("x", "a.txt") | filename: "../../etc/pa\nss\0wd.txt"}
      assert {:ok, attachment} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)
      assert await_done(attachment).filename == "passwd.txt"

      upload = %{Files.upload!("y", "b.txt") | filename: "C:\\Users\\me\\report.txt"}
      assert {:ok, attachment} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)
      assert await_done(attachment).filename == "report.txt"

      upload = %{Files.upload!("z", "c.txt") | filename: ".."}
      assert {:error, :unsupported_type} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)
    end
  end

  # ── processing: text and sheets ─────────────────────────────────────

  describe "text" do
    test "a long text is cut and says so", ctx do
      with_limits(text_chars: 100)
      text = String.duplicate("Line of an order list\n", 30)

      attachment = add_done!(ctx, text, "long.txt")

      assert attachment.status == "ready"
      assert attachment.truncated
      assert [shown, marker] = String.split(attachment.extracted_text, "\n[... ", parts: 2)
      assert String.length(shown) <= 100
      assert String.starts_with?(text, shown)

      assert marker ==
               "the file continues: about #{byte_size(text) - byte_size(shown)} more characters not shown]"
    end

    test "markdown is text; a byte order mark is dropped", ctx do
      md = add_done!(ctx, "# Title\n\n* one", "notes.md")
      assert md.kind == "text"
      assert md.content_type == "text/markdown"
      assert md.extracted_text == "# Title\n\n* one"

      bom = add_done!(ctx, "﻿hello", "bom.txt")
      assert bom.extracted_text == "hello"
    end

    test "csv is read as CSV rows, the first ones", ctx do
      with_limits(sheet_rows: 3)
      csv = "name;qty\nsofa;3\ntable;1\nchair;4\nlamp;9\n"

      attachment = add_done!(ctx, csv, "list.csv", "text/csv")

      assert attachment.kind == "sheet"
      assert attachment.content_type == "text/csv"

      assert attachment.extracted_text ==
               "name;qty\nsofa;3\ntable;1\n[... the file continues: 2 more rows not shown in full]"

      assert attachment.truncated
    end

    test "a CSV over the text limit is cut between rows, and says how many are left", ctx do
      with_limits(text_chars: 20)
      csv = "name;qty\nsofa;3\ntable;1\nchair;4\n"

      attachment = add_done!(ctx, csv, "list.csv", "text/csv")

      assert attachment.extracted_text ==
               "name;qty\nsofa;3\n[... the file continues: 2 more rows not shown in full]"
    end
  end

  describe "sheets" do
    test "an xlsx becomes CSV, the first rows of each sheet", ctx do
      with_limits(sheet_rows: 2)

      xlsx =
        Files.xlsx([
          {"Orders", [["Item", "Qty"], ["Sofa, big", 3], ["Table", 1.5]]},
          {"Notes", [["Only one"]]}
        ])

      attachment = add_done!(ctx, xlsx, "orders.xlsx")

      assert attachment.kind == "sheet"
      assert attachment.status == "ready"

      assert attachment.content_type ==
               "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

      assert attachment.extracted_text ==
               "## Orders\nItem,Qty\n\"Sofa, big\",3\n" <>
                 "[... the sheet continues: 1 of 3 rows not shown in full]\n\n" <>
                 "## Notes\nOnly one\n"

      assert attachment.truncated
    end

    test "each sheet gets its share of the text; the model is told what is not shown", ctx do
      serve_ai()
      with_limits(text_chars: 300)
      big = [["Item", "Qty"] | for(n <- 1..100, do: ["Item number #{n}", n])]
      xlsx = Files.xlsx([{"Big", big}, {"Small", [["Only", "row"]]}])

      attachment = add_done!(ctx, xlsx, "book.xlsx")
      text = attachment.extracted_text

      assert attachment.truncated
      assert text =~ "## Big\nItem,Qty\nItem number 1,1\n"
      # The big first sheet does not take the second one's place.
      assert text =~ "## Small\nOnly,row\n"

      shown = length(Regex.scan(~r/^Item number \d+,\d+$/m, text)) + 1
      assert shown < 101

      assert text =~
               "[... the sheet continues: #{101 - shown} of 101 rows not shown in full]"

      body = String.replace(text, ~r/\[\.\.\. [^\n]*\]\n?/, "")
      assert String.length(body) <= 300

      # The turn's model reads the marker with the file.
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Sum it", [attachment.uuid])
      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => content}] = chat_messages(body)
      assert content =~ "rows not shown in full]"
    end

    test "sheets beyond the bound are named, not left out silently", ctx do
      with_limits(sheets: 1)
      xlsx = Files.xlsx([{"First", [["a"]]}, {"Second", [["b"]]}, {"Third", [["c"]]}])

      attachment = add_done!(ctx, xlsx, "book.xlsx")

      assert attachment.truncated

      assert attachment.extracted_text ==
               "## First\na\n\n[... the workbook continues: 2 more sheets not shown: Second, Third]"
    end

    test "an xlsx is told by its content, not by its name", ctx do
      xlsx = Files.xlsx([{"S", [["a", 1]]}])
      attachment = add_done!(ctx, xlsx, "table.dat")
      assert attachment.kind == "sheet"
      assert attachment.extracted_text =~ "a,1"
    end

    test "a damaged xlsx fails with a code and nothing of it in the log", ctx do
      broken =
        Files.zip([
          {"[Content_Types].xml", "<Types>#{@secret}"},
          {"xl/workbook.xml", "<workbook>#{@secret}"}
        ])

      {attachment, logs} =
        LogProbe.capture(fn ->
          add_done!(ctx, broken, "broken.xlsx")
        end)

      assert attachment.status == "failed"
      assert attachment.error == "unreadable"
      assert attachment.extracted_text == nil
      refute Enum.any?(logs, &(&1 =~ @secret))
    end

    test "a zip that unpacks to far more than the file's size is not read", ctx do
      bomb = Files.zip([{"[Content_Types].xml", "x"}, {"xl/workbook.xml", "x"}])
      with_limits(sheet_unzipped_bytes: 1)

      attachment = add_done!(ctx, bomb, "bomb.xlsx")
      assert attachment.status == "failed"
      assert attachment.error == "too_large"
    end
  end

  # ── processing: PDF ─────────────────────────────────────────────────

  describe "pdf" do
    @describetag :poppler

    test "a PDF with text gives its text and its page count", ctx do
      pdf = Files.text_pdf(["Quote number 4711", "Second page: delivery on Friday"])

      attachment = add_done!(ctx, pdf, "quote.pdf", "application/pdf")

      assert attachment.kind == "pdf"
      assert attachment.status == "ready"
      assert attachment.content_type == "application/pdf"
      assert attachment.pages == 2
      assert attachment.extracted_text =~ "Quote number 4711"
      assert attachment.extracted_text =~ "delivery on Friday"
      refute attachment.truncated
    end

    test "a long PDF text is cut", ctx do
      with_limits(text_chars: 30)
      pdf = Files.text_pdf(["Quote number 4711 and a long line of words that goes on"])

      attachment = add_done!(ctx, pdf, "quote.pdf")

      assert attachment.truncated
      assert [shown, marker] = String.split(attachment.extracted_text, "\n[... ", parts: 2)
      assert String.length(shown) <= 30
      assert marker == "the document continues: 1 of 1 page not shown in full]"
    end

    test "pages past the bound are not read, and the model is told so", ctx do
      with_limits(pdf_text_pages: 1)
      pdf = Files.text_pdf(["Quote number 4711 for the sofa", "Second page: delivery on Friday"])

      attachment = add_done!(ctx, pdf, "quote.pdf")

      assert attachment.truncated
      assert attachment.extracted_text =~ "Quote number 4711"
      refute attachment.extracted_text =~ "Friday"

      assert String.ends_with?(
               attachment.extracted_text,
               "\n[... the document continues: 1 of 2 pages not shown in full]"
             )
    end

    test "a scan, for a model that sees, stays pixels: the first pages as pictures", ctx do
      serve_ai(main_sees: true)
      with_limits(scan_pages: 2)

      attachment = add_done!(ctx, Files.scan_pdf(3), "scan.pdf")

      assert attachment.kind == "pdf"
      assert attachment.status == "ready"
      assert attachment.extracted_text == nil
      assert attachment.pages == 3
      assert attachment.truncated

      assert {:ok, [first, second]} = Attachments.pictures(attachment)
      assert "data:image/png;base64," <> png = first
      assert {:ok, <<0x89, "PNG", _::binary>>} = Base.decode64(png)
      assert "data:image/png;base64," <> _ = second
    end

    test "a scan, for a model that does not see, is described by the vision model", ctx do
      serve_ai(main_sees: false, description: "A blue rectangle on white.")
      vision = vision_endpoint!()

      attachment = add_done!(ctx, Files.scan_pdf(1), "scan.pdf")

      assert attachment.status == "ready"
      assert attachment.extracted_text == "A blue rectangle on white."
      assert attachment.pages == 1

      assert_received {:model_request, body}
      assert model_request_images(body) == 1

      assert %{endpoint_uuid: endpoint_uuid} = vision_request(ctx.user)
      assert endpoint_uuid == vision.uuid
    end
  end

  describe "when the programs are not there" do
    test "a PDF is refused with a plain reason, the task does not crash", ctx do
      path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")
      on_exit(fn -> System.put_env("PATH", path) end)

      attachment = add_done!(ctx, Files.text_pdf(["Hello"]), "quote.pdf")

      assert attachment.status == "failed"
      assert attachment.error == "pdf_tools_missing"
    end

    test "a picture is refused with a plain reason", ctx do
      serve_ai()
      path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")
      on_exit(fn -> System.put_env("PATH", path) end)

      attachment = add_done!(ctx, Files.png(40, 30), "photo.png")

      assert attachment.status == "failed"
      assert attachment.error == "image_tools_missing"
    end
  end

  # ── processing: pictures ────────────────────────────────────────────

  describe "pictures" do
    @describetag :imagemagick

    test "for a model that sees, a picture stays pixels, shrunk to 1600 px", ctx do
      serve_ai(main_sees: true)

      attachment = add_done!(ctx, Files.png(2400, 1200), "wide.png", "image/png")

      assert attachment.kind == "image"
      assert attachment.status == "ready"
      assert attachment.extracted_text == nil
      refute_received {:model_request, _}

      assert {:ok, [url]} = Attachments.pictures(attachment)
      assert "data:image/jpeg;base64," <> jpeg = url
      bytes = Base.decode64!(jpeg)

      assert {:ok, {1600, 800}} =
               ImageProcessor.extract_dimensions(Files.tmp!(bytes, "out.jpg"))
    end

    test "a small picture is not enlarged", ctx do
      serve_ai(main_sees: true)
      attachment = add_done!(ctx, Files.png(300, 200), "small.png")

      assert {:ok, ["data:image/jpeg;base64," <> jpeg]} = Attachments.pictures(attachment)

      assert {:ok, {300, 200}} =
               ImageProcessor.extract_dimensions(Files.tmp!(Base.decode64!(jpeg), "out.jpg"))
    end

    test "for a model that does not see, the vision model describes it", ctx do
      serve_ai(main_sees: false, description: "A grey square that reads SOFA 3 PCS.")
      vision = vision_endpoint!()

      attachment = add_done!(ctx, Files.png(2400, 1200), "wide.png")

      assert attachment.status == "ready"
      assert attachment.extracted_text == "A grey square that reads SOFA 3 PCS."

      assert_received {:model_request, body}
      assert model_request_images(body) == 1

      request = vision_request(ctx.user)
      assert request.endpoint_uuid == vision.uuid
      assert request.request_type == "vision"
      assert request.metadata["source"] == "agent"
      assert request.metadata["task"] == "agent.attachment"
      # What the user showed is not kept in the AI journal, whatever the global setting.
      refute Map.has_key?(request.metadata, "input")
      refute Map.has_key?(request.metadata, "response")
    end

    test "an endpoint of unknown abilities with a vision model set is described too", ctx do
      serve_ai(description: "Described.")
      vision_endpoint!()
      deepseek = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})
      limits!(ctx.user, %{endpoint_uuid: deepseek.uuid})

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")
      assert attachment.extracted_text == "Described."
    end

    test "a model that does not see and no vision model: the picture is refused at once",
         ctx do
      serve_ai(main_sees: false)

      assert {:error, :no_vision_model} = add(ctx, Files.png(40, 30), "a.png")

      assert Repo.aggregate(Attachment, :count) == 0
      assert Repo.aggregate(Storage.File, :count) == 0
      refute_received {:model_request, _}
    end

    test "a picture is not described for a user over the limit, and costs nothing", ctx do
      serve_ai(main_sees: false)
      vision_endpoint!()
      limits!(ctx.user, %{daily_turn_limit: 0})

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")

      assert attachment.status == "failed"
      assert attachment.error == "limit_reached"
      refute_received {:model_request, _}
    end

    test "the money limit before a description is the vision model's, not the chat model's",
         ctx do
      serve_ai(description: "Described.")
      # The vision model reports what a call costs (OpenRouter); the chat model
      # does not, so no money limit applies to the turns themselves.
      vision_endpoint!()
      deepseek = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})
      limits!(ctx.user, %{endpoint_uuid: deepseek.uuid, daily_cost_limit_micro_usd: 0})

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")

      assert attachment.status == "failed"
      assert attachment.error == "limit_reached"
      refute_received {:model_request, _}
    end

    # An Anthropic vision model, answering like Anthropic: tokens, no cost.
    defp claude_vision!(model) do
      serve_ai(main_sees: false)
      test = self()

      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:model_request, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "model" => model,
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "Described."}}],
          "usage" => %{"prompt_tokens" => 30, "completion_tokens" => 8, "total_tokens" => 38}
        })
      end)

      claude = endpoint_fixture(%{name: "Claude", provider: "anthropic", model: model})
      declare_vision!(model, "yes")
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", claude.uuid)
      claude
    end

    test "a vision model with a list price: the money limits hold a description", ctx do
      # phoenix_kit_ai prices a description like a chat call, so Anthropic's
      # list price counts it and a money limit of 0 allows nothing.
      claude_vision!("claude-sonnet-5-5")
      limits!(ctx.user, %{daily_cost_limit_micro_usd: 0})

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")

      assert attachment.status == "failed"
      assert attachment.error == "limit_reached"
      refute_received {:model_request, _}
    end

    test "a vision model nothing prices: a money limit of 0 still lets it describe", ctx do
      # No cost would be counted there, so only the turn limit holds it.
      claude_vision!("claude-unknown-9")
      limits!(ctx.user, %{daily_cost_limit_micro_usd: 0})

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")

      assert attachment.status == "ready"
      assert attachment.extracted_text == "Described."
      assert_received {:model_request, _}
    end

    test "with the AI module switched off a picture is not described, and nothing is paid",
         ctx do
      serve_ai(main_sees: false)
      vision_endpoint!()
      {:ok, _} = PhoenixKitAI.disable_system()

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")

      assert attachment.status == "failed"
      assert attachment.error == "ai_disabled"
      refute_received {:model_request, _}
    end

    test "a session that ends while the picture waits for its turn: no description, no call",
         ctx do
      serve_ai(main_sees: false)
      vision_endpoint!()
      with_limits(jobs_per_user: 1)
      holder = hold_place(ctx.user)

      {:ok, attachment} = add(ctx, Files.png(40, 30), "a.png")
      Auth.delete_user_session_token(ctx.token)
      send(holder, :release)

      attachment = await_done(attachment)
      assert attachment.status == "failed"
      assert attachment.error == "session_gone"
      refute_received {:model_request, _}
    end

    test "one user's pictures are described one at a time, each after the cost of the last",
         ctx do
      test = self()
      vision_endpoint!()
      # The first description costs $0.001, twice the user's daily limit: the
      # second, checked only once the first is in the journal, is not made.
      limits!(ctx.user, %{daily_cost_limit_micro_usd: 500})
      declare_vision!("a/chat", "no")
      declare_vision!("a/eyes", "yes")

      Req.Test.stub(@stub, fn conn ->
        send(test, {:describing, self()})

        receive do
          :go -> :ok
        after
          5_000 -> :ok
        end

        Req.Test.json(conn, %{
          "model" => "a/eyes",
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "Described."}}],
          "usage" => %{
            "prompt_tokens" => 30,
            "completion_tokens" => 8,
            "total_tokens" => 38,
            "cost" => 0.001
          }
        })
      end)

      {:ok, first} = add(ctx, Files.png(40, 30), "a.png")
      {:ok, second} = add(ctx, Files.png(41, 30), "b.png")

      assert_receive {:describing, describing}, 5_000
      refute_receive {:describing, _}, 500
      send(describing, :go)

      outcomes =
        [first, second]
        |> Enum.map(&await_done/1)
        |> Enum.map(&{&1.status, &1.error})
        |> Enum.sort()

      assert outcomes == [{"failed", "limit_reached"}, {"ready", nil}]
      refute_received {:describing, _}
    end

    test "a failed description is a code, not the provider's text", ctx do
      serve_ai(main_sees: false)
      vision_endpoint!()

      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "boom"}}))
      end)

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")

      assert attachment.status == "failed"
      assert attachment.error == "model_error"
      assert attachment.extracted_text == nil
    end

    test "bytes that are not a picture fail, they do not crash", ctx do
      serve_ai()
      png = Files.png(40, 30)
      broken = binary_part(png, 0, 40) <> :binary.copy(<<7>>, 20)

      attachment = add_done!(ctx, broken, "broken.png")

      assert attachment.status == "failed"
      assert attachment.error == "unreadable"
    end
  end

  # ── the task ────────────────────────────────────────────────────────

  describe "the processing task" do
    test "one that takes too long ends as failed", ctx do
      with_limits(process_deadline_ms: 0)

      attachment = add_done!(ctx, "text", "a.txt")

      assert attachment.status == "failed"
      assert attachment.error == "timeout"
    end

    test "a discarded attachment is not brought back by a task that ends later", ctx do
      assert {:ok, attachment} = add(ctx, "text", "a.txt")
      assert :ok = Attachments.discard(ctx.ref, attachment.uuid, @me)

      # Whichever came first, the row is gone and stays gone.
      _ = :sys.get_state(Process.whereis(PhoenixKitAgent.Attachments.TaskSupervisor))
      wait_for_children_to_end()
      assert Repo.get(Attachment, attachment.uuid) == nil
    end

    test "a row settled before a late task ends is left as it is, and heard of once", ctx do
      settled = add_done!(ctx, "Sofa 3 pcs", "notes.txt")
      assert settled.status == "ready"

      timed_out = add!(ctx, "text", "late.txt")
      await_done(timed_out)

      Repo.update_all(from(a in Attachment, where: a.uuid == ^timed_out.uuid),
        set: [status: "failed", error: "timeout", extracted_text: nil]
      )

      # A task for each row that comes too late: one settled as ready, one as
      # failed by `settle_stale`.
      for row <- [settled, timed_out],
          do: :ok = Processor.start(row.uuid, row.user_uuid, ctx.ref)

      wait_for_children_to_end()

      assert %{status: "ready", error: nil, extracted_text: "Sofa 3 pcs"} =
               Repo.get!(Attachment, settled.uuid)

      assert %{status: "failed", error: "timeout"} = Repo.get!(Attachment, timed_out.uuid)
      refute_received {:agent_attachment_processed, _, _}
    end

    test "without the worker supervisor a file fails as unavailable at once", ctx do
      worker_sup = Process.whereis(PhoenixKitAgent.Attachments.WorkerSupervisor)
      {:dictionary, dictionary} = Process.info(worker_sup, :dictionary)
      [parent | _] = Keyword.fetch!(dictionary, :"$ancestors")
      id = PhoenixKitAgent.Attachments.WorkerSupervisor

      :ok = Supervisor.terminate_child(parent, id)
      on_exit(fn -> Supervisor.restart_child(parent, id) end)

      {attachment, logs} = LogProbe.capture(fn -> add_done!(ctx, "text", "a.txt") end)

      assert attachment.status == "failed"
      assert attachment.error == "unavailable"
      refute Enum.any?(logs, &(&1 =~ "noproc"))
      {:ok, _pid} = Supervisor.restart_child(parent, id)
    end

    test "the text of a file never reaches the log", ctx do
      {_, logs} =
        LogProbe.capture(fn ->
          add_done!(ctx, "#{@secret} order list", "list.txt")
          add_done!(ctx, Files.xlsx([{"S", [[@secret, 1]]}]), "list.xlsx")
        end)

      refute Enum.any?(logs, &(&1 =~ @secret))
    end
  end

  defp add!(ctx, binary, name) do
    assert {:ok, attachment} = add(ctx, binary, name)
    attachment
  end

  # A process that holds a processing place for `user` until it is sent the
  # returned message.
  defp hold_slot(user) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = Slots.acquire(user)
        send(test, :slot_held)

        receive do
          :release_slot -> :ok
        end
      end)

    assert_receive :slot_held, 5_000
    {pid, :release_slot}
  end

  defp wait_for_children_to_end do
    for pid <- Task.Supervisor.children(PhoenixKitAgent.Attachments.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  # ── limits ──────────────────────────────────────────────────────────

  describe "limits" do
    test "a file over max_attachment_mb is refused; nothing is stored", ctx do
      limits!(ctx.user, %{max_attachment_mb: 1})
      big = String.duplicate("a", 1_048_576 + 1)

      assert {:error, :too_large} = add(ctx, big, "big.txt")
      assert Repo.aggregate(Attachment, :count) == 0
      assert Library.user_folder(ctx.user.uuid) == nil

      ok = String.duplicate("a", 1_048_576)
      assert {:ok, attachment} = add(ctx, ok, "ok.txt")
      await_done(attachment)
    end

    test "0 MB means no files at all; the module default applies without a user value", ctx do
      limits!(ctx.user, %{max_attachment_mb: 0})
      assert {:error, :too_large} = add(ctx, "x", "a.txt")

      Repo.delete_all(from(s in UserSettings, where: s.user_uuid == ^ctx.user.uuid))
      {:ok, _} = Settings.update_setting("agent_max_attachment_mb", "1")
      assert {:error, :too_large} = add(ctx, String.duplicate("a", 1_048_577), "big.txt")
    end

    test "no more than max_attachments_per_message wait for a message", ctx do
      limits!(ctx.user, %{max_attachments_per_message: 2})

      first = add_done!(ctx, "one", "1.txt")
      _second = add_done!(ctx, "two", "2.txt")
      assert {:error, :too_many} = add(ctx, "three", "3.txt")

      # Removing one makes room.
      assert :ok = Attachments.discard(ctx.ref, first.uuid, @me)
      assert {:ok, third} = add(ctx, "three", "3.txt")
      await_done(third)
      assert {:error, :too_many} = add(ctx, "four", "4.txt")
    end

    test "a failed file takes no room; one already sent takes none either", ctx do
      serve_ai()
      limits!(ctx.user, %{max_attachments_per_message: 1})

      damaged = Files.zip([{"[Content_Types].xml", "<Types>"}, {"xl/workbook.xml", "<workbook>"}])
      assert %{status: "failed"} = add_done!(ctx, damaged, "broken.xlsx")

      sent = add_done!(ctx, "sent", "sent.txt")
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", [sent.uuid])
      await_turn(ctx, turn_ref)

      assert {:ok, next} = add(ctx, "next", "next.txt")
      await_done(next)
      assert {:error, :too_many} = add(ctx, "one more", "more.txt")
    end

    # The sandbox runs every process of a test on one connection, so these
    # uploads are in fact taken one after the other: this checks the outcome of
    # six calls at once, not the lock (see "the lock on the chat" for that).
    test "parallel uploads cannot get past the count", ctx do
      limits!(ctx.user, %{max_attachments_per_message: 2})
      uploads = for n <- 1..6, do: Files.upload!("file #{n}", "f#{n}.txt")

      results =
        uploads
        |> Task.async_stream(
          fn upload -> Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me) end,
          timeout: 20_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 2
      assert Enum.count(results, &(&1 == {:error, :too_many})) == 4

      for {:ok, attachment} <- results, do: await_done(attachment)
    end
  end

  # ── who may ─────────────────────────────────────────────────────────

  describe "the owner only" do
    test "an impersonated session, a revoked one and a user without the permission are refused",
         ctx do
      upload = Files.upload!("x", "a.txt")

      assert {:error, :impersonated} =
               Attachments.add(ctx.ref, ctx.chat.uuid, upload, impersonated: true)

      Auth.delete_user_session_token(ctx.token)
      assert {:error, :session_gone} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)

      plain = user_with([], "plain")
      {plain_ref, _} = session_fixture(plain)
      chat = conversation_fixture(plain)
      assert {:error, :forbidden} = Attachments.add(plain_ref, chat.uuid, upload, @me)

      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "a chat of someone else, a deleted chat or a bad uuid is not found", ctx do
      other = user_fixture("other")
      other_chat = conversation_fixture(other)
      upload = Files.upload!("x", "a.txt")

      for uuid <- [other_chat.uuid, Ecto.UUID.generate(), "junk", nil] do
        assert {:error, :not_found} = Attachments.add(ctx.ref, uuid, upload, @me)
      end

      assert {:ok, _} = Conversations.delete_conversation(ctx.ref, ctx.chat.uuid, @me)
      assert {:error, :not_found} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)

      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "the caller must say whether the session is impersonated", ctx do
      assert_raise ArgumentError, fn ->
        Attachments.add(ctx.ref, ctx.chat.uuid, Files.upload!("x", "a.txt"), [])
      end
    end

    test "an upload that is not a readable file is refused", ctx do
      for upload <- [
            %{path: "/nonexistent/file.txt", filename: "a.txt"},
            %{path: System.tmp_dir!(), filename: "dir.txt"},
            %{filename: "a.txt"},
            "junk"
          ] do
        assert {:error, :file_unreadable} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)
      end
    end

    test "another user does not read, list, discard or fetch the file of an attachment", ctx do
      attachment = add_done!(ctx, "mine", "mine.txt")

      other = user_with(["agent"], "other")
      {other_ref, _} = session_fixture(other)
      other_chat = conversation_fixture(other)

      assert {:error, :not_found} = Attachments.get(other_ref, attachment.uuid, @me)
      assert {:error, :not_found} = Attachments.list_unsent(other_ref, ctx.chat.uuid, @me)
      assert {:error, :not_found} = Attachments.discard(other_ref, attachment.uuid, @me)
      assert {:error, :not_found} = Attachments.url(other_ref, attachment.uuid, @me)
      assert {:error, :not_found} = Attachments.url(other_ref, "junk", @me)
      assert Repo.get(Attachment, attachment.uuid)

      # Nor into a chat of theirs.
      assert {:error, :not_found} =
               Attachments.get(other_ref, Ecto.UUID.generate(), @me)

      assert other_chat.uuid != ctx.chat.uuid
    end

    test "the owner reads, lists, and gets a temporary address of the file", ctx do
      attachment = add_done!(ctx, "mine", "mine.txt")

      assert {:ok, %Attachment{uuid: uuid}} = Attachments.get(ctx.ref, attachment.uuid, @me)
      assert uuid == attachment.uuid

      assert {:ok, [%Attachment{uuid: ^uuid}]} =
               Attachments.list_unsent(ctx.ref, ctx.chat.uuid, @me)

      assert {:ok, url} = Attachments.url(ctx.ref, attachment.uuid, @me)
      assert {:ok, %{uuid: file_uuid, variant: "original"}} = URLSigner.verify_url(url)
      assert file_uuid == attachment.file_uuid
      [token] = url |> String.split("/") |> Enum.take(-1)
      assert "w" <> _ = token
    end

    test "an Admin or Owner is no owner of an attachment through the module", ctx do
      attachment = add_done!(ctx, "mine", "mine.txt")
      owner = owner_fixture()
      {owner_ref, _} = session_fixture(owner)

      assert {:error, :not_found} = Attachments.url(owner_ref, attachment.uuid, @me)
      assert {:error, :not_found} = Attachments.get(owner_ref, attachment.uuid, @me)
    end

    test "a session ended or impersonated gets no address either", ctx do
      attachment = add_done!(ctx, "mine", "mine.txt")

      assert {:error, :impersonated} =
               Attachments.url(ctx.ref, attachment.uuid, impersonated: true)

      Auth.delete_user_session_token(ctx.token)
      assert {:error, :session_gone} = Attachments.url(ctx.ref, attachment.uuid, @me)
    end
  end

  # ── nobody else sees the file in Storage ────────────────────────────

  describe "the hidden library" do
    test "a Manager with media.view_all finds the file nowhere, and no address works for them",
         ctx do
      attachment = add_done!(ctx, "private notes", "private.txt")
      file = storage_file(attachment)
      {:ok, library} = Library.ensure_library()

      {:ok, manager_role} =
        Roles.create_role(%{name: "Managers#{System.unique_integer([:positive])}"})

      for key <- ~w(media media.view_all media.manage),
          do: {:ok, _} = Permissions.grant_permission(manager_role.uuid, key)

      manager = user_fixture("manager")
      {:ok, _} = Roles.assign_role(manager, manager_role.name)
      manager_scope = scope_of(manager)

      # The media picker and the media browser list files of no named library.
      {files, _} = Storage.list_files_in_scope(nil, per_page: 1000)
      refute file.uuid in Enum.map(files, & &1.uuid)

      refute Enum.any?(Storage.list_folders(nil, nil), &(&1.library_uuid == library.uuid))

      # /admin/media: the library switcher and its page by slug.
      refute library.uuid in Enum.map(Libraries.list_system_libraries(), & &1.uuid)
      assert Libraries.get_system_library_by_slug(library.slug) == nil
      assert Libraries.hidden?(library)

      # The file itself: no read, no address.
      refute Libraries.can?(manager_scope, file, :read)
      refute Libraries.can?(manager_scope, file, :edit)
      assert Storage.authorized_url(manager_scope, file, "original") == nil

      # The permanent token is refused; the owner's expiring one serves.
      permanent = URLSigner.generate_token(file.uuid, "original")

      denied =
        FileController.show(conn(:get, "/"), %{
          "file_uuid" => file.uuid,
          "variant" => "original",
          "token" => permanent
        })

      assert denied.status == 401

      {:ok, url} = Attachments.url(ctx.ref, attachment.uuid, @me)
      [token] = url |> String.split("/") |> Enum.take(-1)

      served =
        FileController.show(conn(:get, "/"), %{
          "file_uuid" => file.uuid,
          "variant" => "original",
          "token" => token
        })

      assert served.status == 200
    end
  end

  # ── the turn ────────────────────────────────────────────────────────

  describe "in a turn" do
    test "the text of a ready attachment goes with the message, and the row is linked", ctx do
      serve_ai()
      attachment = add_done!(ctx, "Sofa 3 pcs", "notes.txt")

      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "See file", [attachment.uuid])
      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => content}] = chat_messages(body)
      assert content =~ "See file"
      assert content =~ "Sofa 3 pcs"

      user_message =
        Repo.one(
          from(m in Message, where: m.conversation_uuid == ^ctx.chat.uuid and m.role == "user")
        )

      assert Repo.get!(Attachment, attachment.uuid).message_uuid == user_message.uuid
      assert {:ok, []} = Attachments.list_unsent(ctx.ref, ctx.chat.uuid, @me)
    end

    @tag :imagemagick
    test "a picture goes to a model that sees as pixels, in its own turn only", ctx do
      serve_ai(main_sees: true, description: "It is a sofa.")
      attachment = add_done!(ctx, Files.png(2400, 1200), "sofa.png")

      {:ok, turn_ref} =
        Turns.start(ctx.ref, false, ctx.chat.uuid, "What is this?", [attachment.uuid])

      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => parts}] = chat_messages(body)
      assert [%{"type" => "text", "text" => text}, %{"type" => "image_url"} = image] = parts
      assert text =~ "What is this?"
      assert text =~ "sofa.png"
      assert "data:image/jpeg;base64," <> _ = image["image_url"]["url"]

      # The next turn: the pixels are not sent again, the file is named.
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "And now?", [])
      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      contents = body |> chat_messages() |> Enum.map(& &1["content"])
      assert Enum.all?(contents, &is_binary/1)
      assert Enum.any?(contents, &(&1 =~ "sofa.png"))
    end

    @tag :imagemagick
    test "a turn that carries pictures stays out of the AI journal even when capture is on",
         ctx do
      {:ok, _} = PhoenixKitAgent.Config.put_capture_ai_content(true, [])
      serve_ai(main_sees: true)
      picture = add_done!(ctx, Files.png(40, 30), "sofa.png")

      {:ok, turn_ref} =
        Turns.start(ctx.ref, false, ctx.chat.uuid, "What is this?", [picture.uuid])

      await_turn(ctx, turn_ref)

      pictured = journal_row_of_last_answer(ctx)
      assert pictured.metadata["content_redacted"] == true
      refute inspect(pictured.metadata) =~ "base64"

      # The same setting does capture a turn without pictures: the check above
      # is not an effect of the setting being off.
      text = add_done!(ctx, "Sofa 3 pcs", "notes.txt")
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Read it", [text.uuid])
      await_turn(ctx, turn_ref)

      assert journal_row_of_last_answer(ctx).metadata["content_redacted"] != true
    end

    @tag :imagemagick
    test "a picture goes to a model that does not see as its description, kept in the history",
         ctx do
      serve_ai(main_sees: false, description: "A grey square that reads SOFA 3 PCS.")
      vision_endpoint!()
      attachment = add_done!(ctx, Files.png(40, 30), "sofa.png")
      assert_received {:model_request, _vision_call}

      {:ok, turn_ref} =
        Turns.start(ctx.ref, false, ctx.chat.uuid, "What is this?", [attachment.uuid])

      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => content}] = chat_messages(body)
      assert is_binary(content)
      assert content =~ "SOFA 3 PCS"

      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "And now?", [])
      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert body |> chat_messages() |> Enum.any?(&(&1["content"] =~ "SOFA 3 PCS"))
    end

    @tag :imagemagick
    test "a picture shown to a model that was changed to one that cannot see it is not sent",
         ctx do
      serve_ai(main_sees: true)
      attachment = add_done!(ctx, Files.png(40, 30), "sofa.png")

      # Between the upload and the send the user's model changes to one that is blind.
      blind = endpoint_fixture(%{name: "Blind", model: "a/blind"})
      limits!(ctx.user, %{endpoint_uuid: blind.uuid})
      declare_vision!("a/blind", "no")

      test = self()

      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:model_request, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "model" => "a/blind",
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      {:ok, turn_ref} =
        Turns.start(ctx.ref, false, ctx.chat.uuid, "What is this?", [attachment.uuid])

      await_turn(ctx, turn_ref)

      # The pixels are not sent, nor is the message without them: the model is
      # not called, the chat says why, and the file waits to be sent again.
      refute_received {:model_request, _}
      assert Repo.get!(Attachment, attachment.uuid).message_uuid == nil

      assert [%Message{role: "user"}, %Message{role: "notice", error: "pictures_not_seen"}] =
               Repo.all(
                 from(m in Message,
                   where: m.conversation_uuid == ^ctx.chat.uuid,
                   order_by: [asc: m.inserted_at, asc: m.uuid]
                 )
               )
    end

    test "an attachment of another chat of the same user, a pending one and a foreign one are refused",
         ctx do
      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)

      {:ok, in_other} =
        Attachments.add(ctx.ref, other_chat.uuid, Files.upload!("x", "x.txt"), @me)

      await_done(in_other)

      stranger = user_with(["agent"], "stranger")
      {stranger_ref, _} = session_fixture(stranger)
      stranger_chat = conversation_fixture(stranger)
      :ok = Conversations.subscribe(stranger_ref, stranger_chat.uuid, @me)

      {:ok, foreign} =
        Attachments.add(stranger_ref, stranger_chat.uuid, Files.upload!("y", "y.txt"), @me)

      await_done(foreign)

      pending = add_done!(ctx, "z", "z.txt")

      Repo.update_all(from(a in Attachment, where: a.uuid == ^pending.uuid),
        set: [status: "pending"]
      )

      for uuid <- [in_other.uuid, foreign.uuid, pending.uuid] do
        assert {:error, :invalid_attachments} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", [uuid])
      end

      assert Repo.aggregate(
               from(m in Message, where: m.conversation_uuid == ^ctx.chat.uuid),
               :count
             ) == 0

      assert Repo.get!(Attachment, foreign.uuid).message_uuid == nil
    end

    test "more attachments than the user may send in one message are refused", ctx do
      limits!(ctx.user, %{max_attachments_per_message: 5})
      ready = for n <- 1..2, do: add_done!(ctx, "file #{n}", "f#{n}.txt")

      limits!(ctx.user, %{max_attachments_per_message: 1})

      assert {:error, :too_many_attachments} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", Enum.map(ready, & &1.uuid))

      assert Repo.aggregate(
               from(m in Message, where: m.conversation_uuid == ^ctx.chat.uuid),
               :count
             ) == 0
    end
  end

  # ── review round 1 ──────────────────────────────────────────────────

  describe "a workbook with forged sizes" do
    test "is too large however its central directory reads, and is not opened", ctx do
      forged =
        Files.zip([
          {"[Content_Types].xml", "x"},
          {"xl/workbook.xml", "x"},
          {"xl/worksheets/sheet1.xml", :binary.copy(<<0>>, 5_000_000)},
          {"xl/worksheets/sheet2.xml", :binary.copy(<<0>>, 5_000_000)}
        ])
        |> Files.forge_sizes(1)

      with_limits(sheet_unzipped_bytes: 1_000)

      attachment = add_done!(ctx, forged, "forged.xlsx")

      assert attachment.status == "failed"
      assert attachment.error == "too_large"
    end
  end

  describe "the scratch space" do
    test "a copy of the file is private to the server's user and gone when the work is done",
         ctx do
      stored = add_done!(ctx, "private", "p.txt")

      seen =
        Work.with_file(stored.file_uuid, fn path ->
          {path, File.read!(path), Bitwise.band(File.stat!(path).mode, 0o777),
           Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777)}
        end)

      assert {path, "private", 0o600, 0o700} = seen
      assert Path.dirname(Path.dirname(path)) == Work.root()
      refute File.exists?(path)
      refute File.exists?(Path.dirname(path))
    end

    test "a worker killed by the deadline leaves nothing behind", ctx do
      before = File.ls!(Work.root())
      with_limits(process_deadline_ms: 0)

      assert %{error: "timeout"} = add_done!(ctx, "#{@secret} text", "a.txt")
      wait_for_children_to_end()

      assert File.ls!(Work.root()) -- before == []
    end

    test "a worker killed for its heap leaves nothing behind, and the file is too large", ctx do
      before = File.ls!(Work.root())
      with_limits(worker_heap_words: 2_000)

      attachment = add_done!(ctx, "text", "a.txt")
      wait_for_children_to_end()

      assert attachment.status == "failed"
      assert attachment.error == "too_large"
      assert File.ls!(Work.root()) -- before == []
    end

    @tag :poppler
    test "a finished scan leaves nothing behind either", ctx do
      serve_ai(main_sees: true)
      before = File.ls!(Work.root())

      assert %{status: "ready"} = add_done!(ctx, Files.scan_pdf(2), "scan.pdf")
      wait_for_children_to_end()

      assert File.ls!(Work.root()) -- before == []
    end
  end

  describe "what Storage is told of the file" do
    test "its name reaches neither Storage's rows and job arguments nor any log line", ctx do
      name = "#{@secret}-passport.txt"

      {attachment, logs} = LogProbe.capture(fn -> add_done!(ctx, "plain text", name) end)

      assert attachment.filename == name
      refute storage_file(attachment).original_file_name =~ @secret
      refute inspect(Repo.all(Oban.Job)) =~ @secret
      refute Enum.any?(logs, &(&1 =~ @secret))
    end

    test "a name made to read backwards loses its direction marks", ctx do
      assert {:ok, attachment} = add(ctx, "x", "report\u202Etxt.txt")
      assert attachment.filename == "reporttxt.txt"
      await_done(attachment)
    end
  end

  describe "a row nothing works on any more" do
    test "pending past the deadline is settled as failed when the user's rows are read", ctx do
      old = add_done!(ctx, "one", "1.txt")
      recent = add_done!(ctx, "two", "2.txt")

      for {row, age} <- [{old, -600}, {recent, 0}] do
        Repo.update_all(from(a in Attachment, where: a.uuid == ^row.uuid),
          set: [
            status: "pending",
            error: nil,
            extracted_text: nil,
            inserted_at: DateTime.add(DateTime.utc_now(), age, :second)
          ]
        )
      end

      assert {:ok, %{status: "failed", error: "timeout"}} =
               Attachments.get(ctx.ref, old.uuid, @me)

      assert {:ok, %{status: "pending"}} = Attachments.get(ctx.ref, recent.uuid, @me)
      assert {:ok, listed} = Attachments.list_unsent(ctx.ref, ctx.chat.uuid, @me)
      assert Enum.map(listed, & &1.status) |> Enum.sort() == ["failed", "pending"]
    end

    test "it holds no place when a new file is added", ctx do
      limits!(ctx.user, %{max_attachments_per_message: 1})
      lost = add_done!(ctx, "one", "1.txt")

      Repo.update_all(from(a in Attachment, where: a.uuid == ^lost.uuid),
        set: [status: "pending", inserted_at: DateTime.add(DateTime.utc_now(), -600, :second)]
      )

      assert {:ok, next} = add(ctx, "two", "2.txt")
      await_done(next)
    end
  end

  describe "the bytes of a file that is not sent" do
    test "discarding removes them unless another attachment still uses them", ctx do
      one = add_done!(ctx, "same bytes", "one.txt")
      two = add_done!(ctx, "same bytes", "two.txt")
      assert one.file_uuid == two.file_uuid

      assert :ok = Attachments.discard(ctx.ref, one.uuid, @me)
      assert Repo.get(Storage.File, two.file_uuid)

      assert :ok = Attachments.discard(ctx.ref, two.uuid, @me)
      assert Repo.get(Storage.File, two.file_uuid) == nil
    end

    test "a file already sent cannot be discarded and keeps its bytes", ctx do
      serve_ai()
      sent = add_done!(ctx, "sent", "sent.txt")
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", [sent.uuid])
      await_turn(ctx, turn_ref)

      assert {:error, :already_sent} = Attachments.discard(ctx.ref, sent.uuid, @me)
      assert Repo.get(Attachment, sent.uuid)
      assert Repo.get(Storage.File, sent.file_uuid)
    end

    test "when Storage cannot keep the file the row goes and the place is free", ctx do
      limits!(ctx.user, %{max_attachments_per_message: 1})
      Repo.update_all(Storage.Bucket, set: [enabled: false])
      :persistent_term.erase(:phoenix_kit_buckets_cache)

      assert {:error, :storage_unavailable} = add(ctx, "x", "a.txt")
      assert Repo.aggregate(Attachment, :count) == 0

      Repo.update_all(from(b in Storage.Bucket, where: b.uuid == ^ctx.bucket.uuid),
        set: [enabled: true]
      )

      :persistent_term.erase(:phoenix_kit_buckets_cache)
      assert {:ok, attachment} = add(ctx, "x", "a.txt")
      await_done(attachment)
    end

    test "a user cannot pile up failed files: they count until discarded", ctx do
      with_limits(unsent_files: 2)
      broken = Files.zip([{"[Content_Types].xml", "<Types>"}, {"xl/workbook.xml", "<workbook>"}])

      first = add_done!(ctx, broken, "1.xlsx")
      assert first.status == "failed"

      assert %{status: "failed"} =
               add_done!(ctx, String.replace(broken, "<Types>", "<Type2>"), "2.xlsx")

      assert {:error, :too_many} = add(ctx, "text", "3.txt")

      assert :ok = Attachments.discard(ctx.ref, first.uuid, @me)
      assert {:ok, third} = add(ctx, "text", "3.txt")
      await_done(third)
    end
  end

  describe "the user's cap of files waiting for a message" do
    test "files of a deleted chat, which the user can no longer see or discard, do not count",
         ctx do
      with_limits(unsent_files: 1)

      first = add_done!(ctx, "left behind", "a.txt")
      assert {:error, :too_many} = add(ctx, "again", "b.txt")

      assert {:ok, _} = Conversations.delete_conversation(ctx.ref, ctx.chat.uuid, @me)
      assert {:error, :not_found} = Attachments.discard(ctx.ref, first.uuid, @me)
      assert Repo.get(Attachment, first.uuid)

      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)
      upload = Files.upload!("fresh", "c.txt")

      assert {:ok, fresh} = Attachments.add(ctx.ref, other_chat.uuid, upload, @me)
      assert fresh.conversation_uuid == other_chat.uuid
      await_done(fresh)
    end

    test "files of an archived chat, which can be discarded, still count", ctx do
      with_limits(unsent_files: 1)

      first = add_done!(ctx, "kept", "a.txt")
      assert {:ok, _} = Conversations.archive_conversation(ctx.ref, ctx.chat.uuid, @me)

      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)
      upload = Files.upload!("fresh", "c.txt")
      assert {:error, :too_many} = Attachments.add(ctx.ref, other_chat.uuid, upload, @me)

      assert :ok = Attachments.discard(ctx.ref, first.uuid, @me)
      assert {:ok, fresh} = Attachments.add(ctx.ref, other_chat.uuid, upload, @me)
      assert fresh.status == "pending"
      await_done(fresh)
    end
  end

  describe "the processing is bounded" do
    test "files beyond what the node processes at once wait for a place and are then processed",
         ctx do
      with_limits(concurrent_jobs: 1, queue_wait_ms: 10_000)
      {blocker, release} = hold_slot("someone-else")

      waiting = add!(ctx, "text", "a.txt")
      assert waiting.status == "pending"
      refute_receive {:agent_attachment_processed, _, _}, 200
      assert Repo.get!(Attachment, waiting.uuid).status == "pending"

      send(blocker, release)
      assert %{status: "ready"} = await_done(waiting)
    end

    test "a file that finds no place within queue_wait_ms is 'unavailable'", ctx do
      with_limits(concurrent_jobs: 1, queue_wait_ms: 50)
      {blocker, release} = hold_slot("someone-else")

      refused = add_done!(ctx, "text", "a.txt")
      assert refused.status == "failed"
      assert refused.error == "unavailable"

      send(blocker, release)
      assert %{status: "ready"} = add_done!(ctx, "again", "b.txt")
    end

    test "one user's files do not take the places of everyone: jobs_per_user", ctx do
      with_limits(concurrent_jobs: 2, jobs_per_user: 1, queue_wait_ms: 10_000)
      {blocker, release} = hold_slot(ctx.user.uuid)

      mine = add!(ctx, "mine", "a.txt")
      # A place is free, but it is not this user's to take.
      refute_receive {:agent_attachment_processed, _, _}, 200
      assert Repo.get!(Attachment, mine.uuid).status == "pending"

      send(blocker, release)
      assert %{status: "ready"} = await_done(mine)
    end

    @tag :imagemagick
    test "a user over the AI budget gets a code, not a description", ctx do
      serve_ai(main_sees: false)
      vision_endpoint!()
      {:ok, _} = PhoenixKitAI.Budget.set_limit(:user_calls, 1)
      ai_request_fixture(ctx.user, ctx.chat_endpoint)

      attachment = add_done!(ctx, Files.png(40, 30), "sofa.png")

      assert attachment.status == "failed"
      assert attachment.error == "budget_exceeded"
      refute_received {:model_request, _}
    end

    test "a user the AI guard blocked gets the guard's code, not a model error", ctx do
      PhoenixKitAI.Guard.reset_caches()
      on_exit(&PhoenixKitAI.Guard.reset_caches/0)
      serve_ai(main_sees: false)
      vision_endpoint!()

      {:ok, _} =
        PhoenixKitAI.Guard.block(scope_of(owner_fixture()), "agent.chat", ctx.user.uuid, "x", nil)

      attachment = add_done!(ctx, Files.png(40, 30), "sofa.png")

      assert attachment.status == "failed"
      assert attachment.error == "task_blocked"
      refute_received {:model_request, _}
    end

    test "a vision model the guard refuses gets its own code", ctx do
      serve_ai(main_sees: false)
      vision_endpoint!()
      declare_vision!("a/eyes", "no")

      attachment = add_done!(ctx, Files.png(40, 30), "sofa.png")

      assert attachment.status == "failed"
      assert attachment.error == "model_unfit"
      refute_received {:model_request, _}

      declare_vision!("a/eyes", nil)
      {:ok, _} = Settings.update_setting("ai_guard_verified_models_only", "true")

      attachment = add_done!(ctx, Files.png(41, 30), "sofa-2.png")
      assert attachment.error == "model_unverified"
      refute_received {:model_request, _}
    end

    test "the task's own limit reached gets its own code", ctx do
      PhoenixKitAI.Guard.reset_caches()
      on_exit(&PhoenixKitAI.Guard.reset_caches/0)
      serve_ai(main_sees: false)
      vision_endpoint!()

      {:ok, _} =
        PhoenixKitAI.TaskLimits.update_settings(scope_of(owner_fixture()), "agent.attachment", %{
          "limits" => %{"task" => %{"requests" => %{"day" => "0"}}}
        })

      attachment = add_done!(ctx, Files.png(40, 30), "sofa.png")

      assert attachment.error == "task_limit_exceeded"
      refute_received {:model_request, _}
    end

    @tag :imagemagick
    test "a description is never answered from, or put into, a cache the users share", ctx do
      # The request cache runs for the whole suite (test_helper.exs).
      Application.put_env(:phoenix_kit_ai, :request_cache, default: true)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :request_cache) end)

      serve_ai(main_sees: false, description: "A grey square.")
      vision_endpoint!()
      png = Files.png(40, 30)

      assert %{extracted_text: "A grey square."} = add_done!(ctx, png, "one.png")
      assert %{extracted_text: "A grey square."} = add_done!(ctx, png, "two.png")

      assert_received {:model_request, _first}
      assert_received {:model_request, _second}
    end
  end

  describe "text in another encoding, and a text that is damaged" do
    test "a file in an 8-bit code page or in UTF-16 is refused with its own reason", ctx do
      windows_1251 = <<0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, ?;, ?1>>
      utf16 = <<0xFF, 0xFE>> <> :unicode.characters_to_binary("a;b", :utf8, {:utf16, :little})

      assert {:error, :unsupported_encoding} = add(ctx, windows_1251, "orders.csv")
      assert {:error, :unsupported_encoding} = add(ctx, windows_1251, "notes.txt")
      assert {:error, :unsupported_encoding} = add(ctx, utf16, "excel.csv")

      # Not text at all is still of a kind that is not accepted.
      assert {:error, :unsupported_type} = add(ctx, <<0, 1, 2, 3>>, "x.txt")
      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "bad bytes after the first screen show as U+FFFD, they are not dropped", ctx do
      text = String.duplicate("a", 9_000) <> <<0xFF>> <> "tail"

      attachment = add_done!(ctx, text, "long.txt")

      assert attachment.status == "ready"
      assert attachment.extracted_text == String.duplicate("a", 9_000) <> "�tail"
    end

    test "a CSV with old Mac line endings has rows", ctx do
      with_limits(sheet_rows: 2)

      attachment = add_done!(ctx, "a,b\rc,d\re,f\r", "mac.csv")

      assert attachment.extracted_text ==
               "a,b\nc,d\n[... the file continues: 1 more row not shown in full]"

      assert attachment.truncated
    end
  end

  describe "pictures: more cases" do
    @describetag :imagemagick

    test "a JPEG is a picture, and the model is not given where it was taken", ctx do
      serve_ai(main_sees: true)
      photo = Files.with_metadata(Files.jpeg(300, 200), "SECRETCAM", "SECRET-COMMENT")

      attachment = add_done!(ctx, photo, "photo.jpg")
      assert attachment.kind == "image"
      assert attachment.content_type == "image/jpeg"

      assert {:ok, ["data:image/jpeg;base64," <> jpeg]} = Attachments.pictures(attachment)
      bytes = Base.decode64!(jpeg)
      assert :binary.match(bytes, "SECRETCAM") == :nomatch
      assert :binary.match(bytes, "SECRET-COMMENT") == :nomatch
    end

    test "the description sent to a vision model is made of the picture without metadata",
         ctx do
      serve_ai(main_sees: false)
      vision_endpoint!()
      photo = Files.with_metadata(Files.jpeg(300, 200), "SECRETCAM", "SECRET-COMMENT")

      add_done!(ctx, photo, "photo.jpg")

      assert_received {:model_request, request}
      refute inspect(request) =~ "SECRETCAM"

      [%{"content" => parts}] = chat_messages(request)

      %{"image_url" => %{"url" => "data:image/jpeg;base64," <> sent}} =
        Enum.find(parts, &(&1["type"] == "image_url"))

      assert :binary.match(Base.decode64!(sent), "SECRETCAM") == :nomatch
    end

    test "a model that declares nothing of its input is taken for a blind one", ctx do
      serve_models_unknown()

      # No vision model: refused before anything is stored, no pixels are tried.
      assert {:error, :no_vision_model} = add(ctx, Files.png(40, 30), "sofa.png")
      assert Repo.aggregate(Attachment, :count) == 0

      # With a vision model the picture is described.
      vision_endpoint!()
      attachment = add_done!(ctx, Files.png(40, 30), "sofa.png")

      assert attachment.status == "ready"
      assert attachment.extracted_text == "Described."
    end

    @tag :poppler
    test "a scan for a model of unknown abilities and no vision model fails as no_vision_model",
         ctx do
      serve_models_unknown()

      attachment = add_done!(ctx, Files.scan_pdf(1), "scan.pdf")

      assert attachment.status == "failed"
      assert attachment.error == "no_vision_model"
      refute_received {:model_request, _}
    end

    test "a picture kept as pixels for a model that no longer sees is not sent: the user is told",
         ctx do
      serve_ai(main_sees: true)
      attachment = add_done!(ctx, Files.png(40, 30), "sofa.png")
      assert attachment.extracted_text == nil

      # Between the upload and the send the model changes to one that declares nothing.
      serve_models_unknown()

      {:ok, turn_ref} =
        Turns.start(ctx.ref, false, ctx.chat.uuid, "What is this?", [attachment.uuid])

      await_turn(ctx, turn_ref)

      # No model call: neither the pixels nor the message without them.
      refute_received {:model_request, _}

      assert %Message{error: "pictures_not_seen", content: notice} =
               Repo.one!(
                 from(m in Message,
                   where: m.conversation_uuid == ^ctx.chat.uuid and m.role == "notice"
                 )
               )

      assert notice =~ "attach them again"

      # The file waits to be sent again (or discarded and attached anew).
      assert Repo.get!(Attachment, attachment.uuid).message_uuid == nil
      assert {:ok, [%{uuid: uuid}]} = Attachments.list_unsent(ctx.ref, ctx.chat.uuid, @me)
      assert uuid == attachment.uuid
    end

    test "a turn whose model fails on its pictures leaves the files unsent, to be sent again",
         ctx do
      serve_ai(main_sees: true)
      picture = add_done!(ctx, Files.png(40, 30), "sofa.png")
      notes = add_done!(ctx, "Sofa 3 pcs", "notes.txt")
      uuids = [picture.uuid, notes.uuid]

      serve_models_seeing_failing()
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "What is this?", uuids)
      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert model_request_images(body) == 1

      for uuid <- uuids, do: assert(Repo.get!(Attachment, uuid).message_uuid == nil)
      assert {:ok, unsent} = Attachments.list_unsent(ctx.ref, ctx.chat.uuid, @me)
      assert Enum.sort(Enum.map(unsent, & &1.uuid)) == Enum.sort(uuids)

      assert %Message{error: error, content: notice} =
               Repo.one!(
                 from(m in Message,
                   where: m.conversation_uuid == ^ctx.chat.uuid and m.role == "notice"
                 )
               )

      assert error == "api_error"
      assert notice =~ "send them again"

      # Sent again, they go with the new message.
      serve_ai(main_sees: true)
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Again", uuids)
      await_turn(ctx, turn_ref)

      again =
        Repo.one!(
          from(m in Message,
            where:
              m.conversation_uuid == ^ctx.chat.uuid and m.role == "user" and
                m.content == "Again"
          )
        )

      for uuid <- uuids, do: assert(Repo.get!(Attachment, uuid).message_uuid == again.uuid)
    end

    test "a provider that fails for another reason than the pictures keeps them with the message",
         ctx do
      for status <- [404, 500, 503] do
        serve_ai(main_sees: true)
        picture = add_done!(ctx, Files.png(40, 30), "sofa-#{status}.png")

        serve_models_seeing_failing(status)

        {:ok, turn_ref} =
          Turns.start(ctx.ref, false, ctx.chat.uuid, "What is #{status}?", [picture.uuid])

        await_turn(ctx, turn_ref)

        refute Repo.get!(Attachment, picture.uuid).message_uuid == nil, "status #{status}"

        assert %Message{error: "api_error", content: notice} =
                 Repo.one!(
                   from(m in Message,
                     where: m.conversation_uuid == ^ctx.chat.uuid and m.role == "notice",
                     order_by: [desc: m.inserted_at, desc: m.uuid],
                     limit: 1
                   )
                 )

        refute notice =~ "send them again", "status #{status}"
      end
    end

    test "a turn without pictures that fails keeps its files with its message", ctx do
      serve_ai()
      notes = add_done!(ctx, "Sofa 3 pcs", "notes.txt")

      serve_models_seeing_failing()
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Read it", [notes.uuid])
      await_turn(ctx, turn_ref)

      refute Repo.get!(Attachment, notes.uuid).message_uuid == nil
    end
  end

  # Nothing known of what the chat model takes; a vision model that answers
  # "Described.".
  defp serve_models_unknown do
    test = self()
    declare_vision!("a/chat", nil)
    declare_vision!("a/eyes", "yes")

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Described."}}]
      })
    end)
  end

  # A chat model that sees, and whose every call is refused by the provider.
  defp serve_models_seeing_failing(status \\ 400) do
    test = self()
    declare_vision!("a/chat", "yes")

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        status,
        Jason.encode!(%{"error" => %{"message" => "no images"}})
      )
    end)
  end

  describe "the lock on the chat" do
    # The sandbox gives every process one connection, so two uploads cannot
    # race in a test; what is checked is that the count and the new row are made
    # in one step that begins by locking the chat's row, as a parallel pair of
    # uploads in production needs.
    test "the count of waiting files and the new row are made under FOR UPDATE", ctx do
      test = self()
      handler = "lock-probe-#{System.unique_integer([:positive])}"
      event = Repo.config()[:telemetry_prefix] ++ [:query]

      :telemetry.attach(
        handler,
        event,
        fn _event, _measurements, metadata, _config -> send(test, {:query, metadata.query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, attachment} = add(ctx, "locked", "a.txt")
      await_done(attachment)
      :telemetry.detach(handler)

      queries = collect_queries([])
      conversations = ~s(FROM "phoenix_kit_agent_conversations")
      attachments = ~s(FROM "phoenix_kit_agent_attachments")
      insert = ~s(INSERT INTO "phoenix_kit_agent_attachments")

      lock = Enum.find_index(queries, &(&1 =~ conversations and &1 =~ "FOR UPDATE"))
      count = Enum.find_index(queries, &(&1 =~ attachments and &1 =~ "count("))
      row = Enum.find_index(queries, &(&1 =~ insert))

      assert lock && count && row
      assert lock < count and count < row
    end
  end

  defp collect_queries(acc) do
    receive do
      {:query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "in a turn: the message and its files" do
    test "the message and the link to its files are one write", ctx do
      attachment = add_done!(ctx, "kept", "a.txt")

      assert {:error, %Ecto.Changeset{}} =
               Conversations.add_user_turn_message(
                 ctx.user.uuid,
                 ctx.chat.uuid,
                 %{role: "no-such-role", content: "x"},
                 [attachment.uuid]
               )

      assert Repo.get!(Attachment, attachment.uuid).message_uuid == nil

      assert {:ok, message} =
               Conversations.add_user_turn_message(
                 ctx.user.uuid,
                 ctx.chat.uuid,
                 %{role: "user", content: "x"},
                 [attachment.uuid]
               )

      assert Repo.get!(Attachment, attachment.uuid).message_uuid == message.uuid
    end

    test "the link takes only the chat owner's files of that chat, whoever the caller names",
         ctx do
      mine_here = add_done!(ctx, "here", "a.txt")

      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)

      mine_elsewhere =
        await_done(
          elem(Attachments.add(ctx.ref, other_chat.uuid, Files.upload!("there", "b.txt"), @me), 1)
        )

      stranger = user_fixture("stranger")
      stranger_chat = conversation_fixture(stranger)

      foreign =
        %Attachment{conversation_uuid: stranger_chat.uuid, user_uuid: stranger.uuid}
        |> Attachment.changeset(%{
          filename: "c.txt",
          content_type: "text/plain",
          size_bytes: 1,
          kind: "text",
          status: "ready"
        })
        |> Repo.insert!()

      uuids = [mine_here.uuid, mine_elsewhere.uuid, foreign.uuid]

      assert {:ok, message} =
               Conversations.add_user_turn_message(
                 ctx.user.uuid,
                 ctx.chat.uuid,
                 %{role: "user", content: "x"},
                 uuids
               )

      assert Repo.get!(Attachment, mine_here.uuid).message_uuid == message.uuid
      assert Repo.get!(Attachment, mine_elsewhere.uuid).message_uuid == nil
      assert Repo.get!(Attachment, foreign.uuid).message_uuid == nil
    end

    test "the files of one message share the history window between them", ctx do
      serve_ai()
      {:ok, _} = Settings.update_setting("agent_history_chars", "3000")
      limits!(ctx.user, %{max_attachments_per_message: 3})
      files = for n <- 1..3, do: add_done!(ctx, String.duplicate("#{n}", 5_000), "f#{n}.txt")

      {:ok, turn_ref} =
        Turns.start(ctx.ref, false, ctx.chat.uuid, "Read these", Enum.map(files, & &1.uuid))

      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => content}] = chat_messages(body)
      assert String.length(content) < 3_000 + 400

      assert length(
               String.split(content, "[... the file continues: the rest of it is not shown here]")
             ) == 4

      for n <- 1..3, do: assert(content =~ ~s|): "f#{n}.txt"]|)
    end
  end

  describe "the Storage file in the history" do
    test "a ready attachment names its file and filename in every later turn", ctx do
      serve_ai()
      file = add_done!(ctx, "Sofa 3 pcs", "notes.txt")
      assert is_binary(file.file_uuid)

      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Read it", [file.uuid])
      await_turn(ctx, turn_ref)
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "And now?", [])
      await_turn(ctx, turn_ref)

      assert_received {:model_request, first}
      assert_received {:model_request, second}

      for body <- [first, second] do
        assert [%{"content" => content} | _] = chat_messages(body)
        assert content =~ ~s|[Attachment (file_uuid: #{file.file_uuid}): "notes.txt"]|
      end
    end
  end

  describe "file_for_user/2" do
    test "the user's ready attachment of the file, by its name", ctx do
      file = add_done!(ctx, "Sofa 3 pcs", "notes.txt")

      assert {:ok, %{filename: "notes.txt", attachment_uuid: uuid}} =
               Attachments.file_for_user(ctx.user.uuid, file.file_uuid)

      assert uuid == file.uuid
    end

    test "the same bytes added twice: the latest row", ctx do
      first = add_done!(ctx, "Sofa 3 pcs", "first.txt")
      second = add_done!(ctx, "Sofa 3 pcs", "second.txt")
      assert first.file_uuid == second.file_uuid

      assert {:ok, %{filename: "second.txt"}} =
               Attachments.file_for_user(ctx.user.uuid, first.file_uuid)
    end

    test "another user's file is :error", ctx do
      file = add_done!(ctx, "Sofa 3 pcs", "notes.txt")
      other = user_fixture("other")

      assert Attachments.file_for_user(other.uuid, file.file_uuid) == :error
    end

    test "a deleted chat is :error", ctx do
      file = add_done!(ctx, "Sofa 3 pcs", "notes.txt")
      assert {:ok, _} = Conversations.delete_conversation(ctx.ref, ctx.chat.uuid, @me)

      assert Attachments.file_for_user(ctx.user.uuid, file.file_uuid) == :error
    end

    test "a row that is not ready is :error, and so is a thing that is no uuid", ctx do
      file = add_done!(ctx, "Sofa 3 pcs", "notes.txt")

      Repo.update_all(from(a in Attachment, where: a.uuid == ^file.uuid),
        set: [status: "failed"]
      )

      assert Attachments.file_for_user(ctx.user.uuid, file.file_uuid) == :error
      assert Attachments.file_for_user(ctx.user.uuid, "nope") == :error
      assert Attachments.file_for_user(nil, nil) == :error
    end
  end

  defp journal_row_of_last_answer(ctx) do
    answer =
      Repo.one!(
        from(m in Message,
          where: m.conversation_uuid == ^ctx.chat.uuid and m.role == "assistant",
          order_by: [desc: m.inserted_at, desc: m.uuid],
          limit: 1
        )
      )

    Repo.get!(Request, answer.ai_request_uuid)
  end

  defp await_turn(ctx, turn_ref) do
    chat_uuid = ctx.chat.uuid
    assert_receive {:agent_turn_finished, ^chat_uuid, ^turn_ref}, 10_000
  end

  defp chat_messages(body), do: Enum.reject(body["messages"], &(&1["role"] == "system"))

  defp model_request_images(body) do
    body["messages"]
    |> Enum.flat_map(fn message ->
      if is_list(message["content"]), do: message["content"], else: []
    end)
    |> Enum.count(&(&1["type"] == "image_url"))
  end

  defp vision_request(user) do
    Repo.one!(
      from(r in Request,
        where: r.user_uuid == ^user.uuid and r.request_type == "vision",
        order_by: [desc: r.inserted_at],
        limit: 1
      )
    )
  end
end
