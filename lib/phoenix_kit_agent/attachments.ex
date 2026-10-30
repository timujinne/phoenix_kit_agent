defmodule PhoenixKitAgent.Attachments do
  @moduledoc """
  Files attached to a chat (spec §5.3, §9).

  Like `PhoenixKitAgent.Conversations`, every function acts for a **live
  browser session**: the `{session_token_uuid, user_uuid}` reference and, in
  the options, `impersonated: boolean` (`PhoenixKitAgent.Conversations` has the
  checks that come first and their refusals: an impersonated or revoked
  session, a user without `agent`, a chat that is not the user's). The owner
  is the only one who adds a file to a chat, reads its row, discards it or is
  given the address of its bytes; an Owner or an Admin of the site is no
  exception here.

  ## Adding a file

  `add/4` takes the file the Dock got from `allow_upload` (its temporary
  path and the name and type the browser gave), checks it, keeps it and starts
  its processing, and returns the row as `pending`. In order:

    1. the chat is the session user's; the upload is a readable, non-empty
       file no larger than `max_attachment_mb` (the size is read from the file,
       not believed from the caller);
    2. the **content** tells the kind (`PhoenixKitAgent.Attachments.Detect`):
       png/jpg/webp/heic, pdf, xlsx/csv, txt/md; anything else is
       `:unsupported_type`. A picture for a user whose model is not known to
       take images, while the module has no vision model to describe it, is
       `:no_vision_model` here, before anything is stored (see the processor);
    3. the chat has room: no more than `max_attachments_per_message` files that
       are not part of a message yet (a failed one takes no room there), and
       the user has no more than `unsent_files` (`Attachments.Bounds`) files of
       any status waiting in all their chats that are not deleted — a failed one stays until it is
       discarded, and counts here. The count and the row are made under a lock
       on the chat, so parallel uploads cannot pass it;
    4. the bytes are stored in the module's hidden Storage library, in the
       user's folder (`PhoenixKitAgent.Library`), uploaded by the user — a
       Manager with `media.view_all` neither sees nor reads them, and the
       permanent file token is refused; the file is not in Media. The same
       bytes of the same user are one Storage file, as in any library. Storage
       is given a neutral name for the file (the row keeps the user's), since
       Storage writes the name to its own log lines and job arguments;
    5. `PhoenixKitAgent.Attachments.Processor` works on the file in a task.

  `add/4` writes to Storage and may take long: call it off the LiveView
  process. The row's `status` goes `pending` → `ready` | `failed`; when it
  does the chat's topic (`PhoenixKitAgent.Conversations.topic/1`) hears
  `{:agent_attachment_processed, conversation_uuid, attachment_uuid}`, and the
  listener reads the row with `get/3`. `error` of a failed row is a code (see
  the processor), never text of the file.

  The row `add/4` returns is `pending` as it was when processing started, and
  a small file can be processed — and its message sent — before the caller has
  that return value. So a listener must not let it replace a row it already
  read as `ready` or `failed`: after `add/4` returns, read the row again with
  `get/3` (or keep whichever of the two is settled).

  ## Sending

  A `ready` attachment that belongs to the user and to the chat is passed to
  `PhoenixKitAgent.Turns.start/6` by uuid; the turn links it to the user
  message it stores. Its extracted text goes with the message and stays in the
  history, the attachments of one message sharing `agent_history_chars`
  between them; a picture's pixels go only in the turn of that message (and,
  for a model that sees, are not described afterwards: later turns carry a line
  that names the picture and the assistant's own answer). When the provider
  refuses the first model call of a turn that carries pictures, the turn takes
  its files off the message again (`PhoenixKitAgent.Turns.Runner`) — only a
  refusal of the request itself (400, 413, 415, 422), not a missing model or
  a failure of the provider. So does a turn whose model is no longer known to
  take images: the pixels are not sent, the model is not called, and a notice
  (`pictures_not_seen`) says to attach the files again, to be described. After
  a turn has ended, `list_unsent/3` is the list to show.

  ## The bytes

  Nobody but the owner gets at them, and only through `url/3`: an expiring
  address of the file in Storage, minted for the session's own scope.

  ## Refusals

  Those of `PhoenixKitAgent.Conversations`, and `:file_unreadable`,
  `:empty_file`, `:too_large`, `:unsupported_type`, `:unsupported_encoding` (a
  text, CSV or Markdown file that is not UTF-8: save it as UTF-8),
  `:no_vision_model`, `:too_many`, `:storage_unavailable`, `:already_sent`.

  A row that is still `pending` after the processing deadline and a margin (the
  node was restarted, the task was lost) is settled as `failed`/`timeout` the
  next time the user's rows are read, so it neither blocks a message nor holds
  a place; the Dock offers to discard it like any failed one.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.FileHash
  alias PhoenixKitAgent.Attachments.{Bounds, Detect, Extract, Processor, Work}
  alias PhoenixKitAgent.{Conversations, Library, Models, UserConfig, UserDeletion}
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation}

  @mb 1_048_576
  @name_chars 200
  # A `pending` row older than the processing deadline by this much is lost.
  @stale_margin_ms 60_000

  @typedoc """
  The file as the Dock got it from `allow_upload`. A `content_type` the browser
  claims may be there; it is not looked at, the content tells what the file is.

  **`path` is trusted.** It must be the temporary file of LiveView's upload
  (`consume_uploaded_entries/3`) and nothing a client sent: whatever regular
  file it names is read and stored in the user's chat. The `filename` is the
  client's and is only kept as a label.
  """
  @type upload :: %{
          required(:path) => Path.t(),
          required(:filename) => String.t(),
          optional(:content_type) => String.t() | nil
        }

  @typedoc "Why a call was refused."
  @type refusal ::
          Conversations.refusal()
          | :file_unreadable
          | :empty_file
          | :too_large
          | :unsupported_type
          | :unsupported_encoding
          | :no_vision_model
          | :too_many
          | :storage_unavailable
          | :already_sent

  # ── adding ──────────────────────────────────────────────────────────

  @doc """
  Adds `upload` to the session user's chat (see the moduledoc). Returns the
  `pending` row; the file's processing has started. Read the row again with
  `get/3` afterwards: it may be settled already (see "Adding a file").
  """
  @spec add(Conversations.session_ref(), term(), upload(), keyword()) ::
          {:ok, Attachment.t()} | {:error, refusal()}
  def add(session_ref, conversation_uuid, upload, opts) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid, opts),
         {:ok, source} <- readable(upload),
         settings = UserConfig.effective(conversation.user_uuid),
         :ok <- size_allowed(source.size, settings),
         {:ok, detected} <- Detect.detect(source.path, source.filename),
         :ok <- can_be_shown(detected, settings),
         :ok <- settle_stale(conversation.user_uuid),
         {:ok, attachment} <- reserve(conversation, source, detected, settings),
         {:ok, attachment} <- store(attachment, source, detected) do
      :ok = Processor.start(attachment.uuid, attachment.user_uuid, session_ref)
      {:ok, attachment}
    end
  end

  defp readable(%{path: path, filename: filename}) when is_binary(path) and is_binary(filename) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: 0}} ->
        {:error, :empty_file}

      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:ok, %{path: path, filename: clean_name(filename), size: size}}

      _not_a_file ->
        {:error, :file_unreadable}
    end
  end

  defp readable(_not_an_upload), do: {:error, :file_unreadable}

  # A picture the user's model would not see and nothing could describe.
  defp can_be_shown(%{kind: "image"}, settings) do
    case Processor.picture_mode(settings) do
      {:ok, _mode} -> :ok
      {:error, :no_vision_model} = refusal -> refusal
    end
  end

  defp can_be_shown(_not_a_picture, _settings), do: :ok

  defp size_allowed(size, settings) do
    if size <= settings.max_attachment_mb * @mb, do: :ok, else: {:error, :too_large}
  end

  # A plain name: the last path segment of either kind, no control characters
  # and no bidirectional overrides (they make `fdp.exe` read as `exe.pdf`).
  defp clean_name(filename) do
    name =
      filename
      |> String.split(["/", "\\"])
      |> List.last()
      |> String.replace(
        ~r/[[:cntrl:]]|[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u,
        ""
      )
      |> String.trim()
      |> String.slice(0, @name_chars)

    if name in ["", ".", ".."], do: "file", else: name
  end

  # The row, made under a lock on the chat so that the count of files waiting
  # for a message and the new row are one step.
  defp reserve(conversation, source, detected, settings) do
    result =
      repo().transaction(fn ->
        locked =
          repo().one(
            from(c in Conversation,
              where: c.uuid == ^conversation.uuid and c.status != "deleted",
              lock: "FOR UPDATE"
            )
          )

        waiting =
          repo().aggregate(
            from(a in Attachment,
              where:
                a.conversation_uuid == ^conversation.uuid and is_nil(a.message_uuid) and
                  a.status in ["pending", "ready"]
            ),
            :count
          )

        unsent =
          repo().aggregate(
            from(a in Attachment,
              join: c in Conversation,
              on: c.uuid == a.conversation_uuid,
              where:
                a.user_uuid == ^conversation.user_uuid and is_nil(a.message_uuid) and
                  c.status != "deleted"
            ),
            :count
          )

        cond do
          is_nil(locked) -> repo().rollback(:not_found)
          waiting >= settings.max_attachments_per_message -> repo().rollback(:too_many)
          unsent >= Bounds.get(:unsent_files) -> repo().rollback(:too_many)
          true -> insert_row(conversation, source, detected)
        end
      end)

    case result do
      {:ok, attachment} -> {:ok, attachment}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  # `log: false`: Ecto would print the bound values, and the file's name is the
  # user's (spec §8.2, the log rule of AGENTS.md).
  defp insert_row(conversation, source, detected) do
    %Attachment{conversation_uuid: conversation.uuid, user_uuid: conversation.user_uuid}
    |> Attachment.changeset(%{
      filename: source.filename,
      content_type: detected.content_type,
      size_bytes: source.size,
      kind: detected.kind,
      status: "pending"
    })
    |> repo().insert!(log: false)
  end

  # The bytes go to Storage; a row whose file could not be kept is removed, and
  # so are the bytes, if they got as far as Storage.
  defp store(attachment, source, detected) do
    with {:ok, folder} <- Library.ensure_user_folder(attachment.user_uuid),
         {:ok, checksum} <- FileHash.sha256(source.path) do
      case put_file(attachment, source, detected, folder, checksum) do
        {:ok, file} -> link(attachment, file, folder)
        {:error, stored_uuid} -> abandon(attachment, stored_uuid)
      end
    else
      _failed -> abandon(attachment, nil)
    end
  rescue
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] an attachment could not be stored: #{inspect(exception.__struct__)}"
      )

      abandon(attachment, nil)
  end

  defp link(attachment, file, folder) do
    with {:ok, _file} <- Storage.attach_file_to_folder(file, folder.uuid),
         {1, _} <- link_file(attachment, file) do
      {:ok, %{attachment | file_uuid: file.uuid}}
    else
      _failed -> abandon(attachment, file.uuid)
    end
  rescue
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] an attachment could not be stored: #{inspect(exception.__struct__)}"
      )

      abandon(attachment, file.uuid)
  end

  defp abandon(attachment, file_uuid) do
    remove_row(attachment)
    if file_uuid, do: UserDeletion.release_file(file_uuid)
    {:error, :storage_unavailable}
  end

  # Storage is given a neutral name: it logs the name of a file it processes
  # and keeps it in its job arguments, and the user's file names are theirs
  # (the row keeps the real one).
  defp put_file(attachment, source, detected, folder, checksum) do
    result =
      Storage.store_file_in_buckets(
        source.path,
        Storage.determine_file_type(detected.content_type, "file." <> detected.ext),
        attachment.user_uuid,
        checksum,
        detected.ext,
        attachment.uuid <> "." <> detected.ext,
        library_uuid: folder.library_uuid,
        mime_type: detected.content_type
      )

    case result do
      {:ok, %Storage.File{} = file} -> {:ok, file}
      {:ok, %Storage.File{} = file, _duplicate} -> {:ok, file}
      _failed -> {:error, nil}
    end
  rescue
    # Storage may have kept the file before it raised: it is found by the key
    # Storage keeps it under (this user, these bytes, this library), to be
    # released — unless another attachment still uses it.
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] an attachment could not be stored: #{inspect(exception.__struct__)}"
      )

      {:error, stored_file_uuid(attachment.user_uuid, checksum, folder.library_uuid)}
  end

  defp stored_file_uuid(user_uuid, checksum, library_uuid) do
    user_uuid
    |> Storage.calculate_user_file_checksum(checksum, library_uuid)
    |> Storage.get_file_by_user_checksum()
    |> case do
      %Storage.File{uuid: uuid} -> uuid
      _none -> nil
    end
  rescue
    _ -> nil
  end

  defp link_file(attachment, file) do
    repo().update_all(from(a in Attachment, where: a.uuid == ^attachment.uuid),
      set: [file_uuid: file.uuid]
    )
  end

  defp remove_row(attachment) do
    repo().delete_all(from(a in Attachment, where: a.uuid == ^attachment.uuid))
  rescue
    _ -> :ok
  end

  # A `pending` row that nothing is working on any more.
  defp settle_stale(user_uuid) do
    cutoff =
      DateTime.add(
        DateTime.utc_now(),
        -(Bounds.get(:queue_wait_ms) + Bounds.get(:process_deadline_ms) + @stale_margin_ms),
        :millisecond
      )

    repo().update_all(
      from(a in Attachment,
        where: a.user_uuid == ^user_uuid and a.status == "pending" and a.inserted_at < ^cutoff
      ),
      [set: [status: "failed", error: "timeout"]],
      log: false
    )

    :ok
  end

  # ── reading ─────────────────────────────────────────────────────────

  @doc "The session user's attachment `attachment_uuid`."
  @spec get(Conversations.session_ref(), term(), keyword()) ::
          {:ok, Attachment.t()} | {:error, refusal()}
  def get(session_ref, attachment_uuid, opts) do
    with {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts),
         :ok <- settle_stale(user_uuid) do
      fetch(user_uuid, attachment_uuid)
    end
  end

  @doc """
  The user's latest `ready` attachment of the Storage file `file_uuid`, in a
  chat that is not deleted: `{:ok, %{filename: name_the_user_gave,
  attachment_uuid: uuid}}`, or `:error` when there is none — the file is not
  the user's, it is not ready, its chat is deleted, or `file_uuid` is not a
  uuid. For a host that copies a chat attachment by its Storage uuid: it is
  how it checks the file is the user's own and names the copy. It acts for
  the user uuid it is given and checks no session: the caller has done that.
  A uuid in the model's text is not proof of ownership: the host checks it
  with this function.
  """
  @spec file_for_user(term(), term()) ::
          {:ok, %{filename: String.t(), attachment_uuid: Ecto.UUID.t()}} | :error
  def file_for_user(user_uuid, file_uuid) do
    with {:ok, user_uuid} <- Ecto.UUID.cast(user_uuid),
         {:ok, file_uuid} <- Ecto.UUID.cast(file_uuid),
         %{} = found <-
           repo().one(
             from(a in Attachment,
               join: c in Conversation,
               on: c.uuid == a.conversation_uuid,
               where:
                 a.user_uuid == ^user_uuid and a.file_uuid == ^file_uuid and
                   a.status == "ready" and c.status != "deleted",
               order_by: [desc: a.inserted_at, desc: a.uuid],
               limit: 1,
               select: %{filename: a.filename, attachment_uuid: a.uuid}
             )
           ) do
      {:ok, found}
    else
      _none -> :error
    end
  end

  @doc """
  The files of the chat that wait for a message, oldest first, whatever their
  status (a failed one is there to be seen and discarded).
  """
  @spec list_unsent(Conversations.session_ref(), term(), keyword()) ::
          {:ok, [Attachment.t()]} | {:error, refusal()}
  def list_unsent(session_ref, conversation_uuid, opts) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid, opts),
         :ok <- settle_stale(conversation.user_uuid) do
      {:ok,
       repo().all(
         from(a in Attachment,
           where: a.conversation_uuid == ^conversation.uuid and is_nil(a.message_uuid),
           order_by: [asc: a.inserted_at, asc: a.uuid]
         )
       )}
    end
  end

  @doc """
  Removes a file that has not been sent yet from the chat, and its bytes from
  Storage unless another attachment (or anything else) still uses them; a file
  that is part of a message is `{:error, :already_sent}`.
  """
  @spec discard(Conversations.session_ref(), term(), keyword()) :: :ok | {:error, refusal()}
  def discard(session_ref, attachment_uuid, opts) do
    with {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts),
         {:ok, attachment} <- fetch(user_uuid, attachment_uuid) do
      {count, _} =
        repo().delete_all(
          from(a in Attachment,
            where:
              a.uuid == ^attachment.uuid and a.user_uuid == ^user_uuid and is_nil(a.message_uuid)
          )
        )

      if count == 1 do
        if attachment.file_uuid, do: UserDeletion.release_file(attachment.file_uuid)
        :ok
      else
        {:error, :already_sent}
      end
    end
  end

  @doc """
  An expiring address of the bytes of the user's attachment, minted for the
  session's own scope (`variant`: `"original"` by default, or a Storage
  variant such as `"thumbnail"` of a picture).
  """
  @spec url(Conversations.session_ref(), term(), keyword()) ::
          {:ok, String.t()} | {:error, refusal()}
  def url(session_ref, attachment_uuid, opts) do
    variant = if is_binary(opts[:variant]), do: opts[:variant], else: "original"

    with {:ok, scope} <- Conversations.authorized_scope(session_ref, opts),
         {:ok, %Attachment{file_uuid: file_uuid}} when is_binary(file_uuid) <-
           fetch(Scope.user_uuid(scope), attachment_uuid),
         %Storage.File{} = file <- repo().get(Storage.File, file_uuid),
         url when is_binary(url) <- Storage.authorized_url(scope, file, variant) do
      {:ok, url}
    else
      {:error, _refusal} = error -> error
      _no_file_or_no_right -> {:error, :not_found}
    end
  end

  defp fetch(user_uuid, attachment_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(attachment_uuid),
         %Attachment{} = attachment <-
           repo().one(
             from(a in Attachment,
               join: c in Conversation,
               on: c.uuid == a.conversation_uuid,
               where: a.uuid == ^uuid and a.user_uuid == ^user_uuid and c.status != "deleted"
             )
           ) do
      {:ok, attachment}
    else
      _unknown_or_not_theirs -> {:error, :not_found}
    end
  end

  # ── what the model is given ─────────────────────────────────────────

  @doc """
  Whether the model is shown this attachment as pixels: a `ready` picture, or
  a scanned PDF, that has no text.
  """
  @spec pixels?(Attachment.t()) :: boolean()
  def pixels?(%Attachment{status: "ready", kind: kind, extracted_text: nil}),
    do: kind in ["image", "pdf"]

  def pixels?(_attachment), do: false

  @doc false
  # The pictures of a pixel attachment as data URLs for a model: a picture as a
  # JPEG of at most 1600 px on its long side without its metadata, a scan as
  # PNGs of its first pages. `{:ok, []}` for any other attachment. It trusts
  # its caller (`model_parts/3`, for a turn that checked the attachment is the
  # user's): the bytes of an attachment reach nobody else, and the owner only
  # through `url/3`.
  @spec pictures(Attachment.t()) ::
          {:ok, [String.t()]} | {:error, :unreadable | :image_tools_missing | :pdf_tools_missing}
  def pictures(%Attachment{kind: "image", file_uuid: file_uuid}) when is_binary(file_uuid) do
    Work.with_file(file_uuid, fn path ->
      with {:ok, jpeg} <- Extract.picture(path), do: {:ok, [data_url("image/jpeg", jpeg)]}
    end)
  end

  def pictures(%Attachment{kind: "pdf", file_uuid: file_uuid}) when is_binary(file_uuid) do
    Work.with_file(file_uuid, fn path ->
      with {:ok, pngs, _pages} <- Extract.pdf_pages(path),
           do: {:ok, Enum.map(pngs, &data_url("image/png", &1))}
    end)
  end

  def pictures(%Attachment{}), do: {:ok, []}

  defp data_url(type, bytes), do: "data:" <> type <> ";base64," <> Base.encode64(bytes)

  @doc false
  # What the turn adds to the user's message after its text, for the pixel
  # attachments among `uuids` (the user's own): the pictures as `image_url`
  # parts, and a note for a picture that cannot be made; `{:ok, []}` when there
  # are none. The model is asked again as the turn starts: one that is not
  # known to take images now (it was changed since the upload, or its listing
  # says nothing) is never sent pixels — `{:error, :not_seen}`.
  @spec model_parts([String.t()], String.t(), String.t() | nil) ::
          {:ok, [map()]} | {:error, :not_seen}
  def model_parts(uuids, user_uuid, endpoint_uuid) do
    rows =
      repo().all(
        from(a in Attachment,
          where: a.uuid in ^uuids and a.user_uuid == ^user_uuid,
          order_by: [asc: a.inserted_at, asc: a.uuid]
        )
      )
      |> Enum.filter(&pixels?/1)

    cond do
      rows == [] -> {:ok, []}
      Models.image_input(endpoint_uuid) != :supported -> {:error, :not_seen}
      true -> {:ok, Enum.flat_map(rows, &parts_of/1)}
    end
  end

  defp parts_of(attachment) do
    case pictures(attachment) do
      {:ok, urls} ->
        Enum.map(urls, &%{"type" => "image_url", "image_url" => %{"url" => &1}})

      {:error, _code} ->
        [note("The attachment #{attachment.filename} could not be shown.")]
    end
  end

  defp note(text), do: %{"type" => "text", "text" => "[" <> text <> "]"}

  defp repo, do: RepoHelper.repo()
end
