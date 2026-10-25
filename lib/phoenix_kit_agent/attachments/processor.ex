defmodule PhoenixKitAgent.Attachments.Processor do
  @moduledoc """
  The work done on an attachment before the turn that sends it (spec §9), in a
  task under `PhoenixKitAgent.Attachments.TaskSupervisor`: the row goes from
  `pending` to `ready` with what the model will read, or to `failed` with a
  code in `error`; the chat's topic then hears `{:agent_attachment_processed,
  conversation_uuid, attachment_uuid}`.

    * `text` and `sheet` — the text, or the CSV, cut to the limits of
      `PhoenixKitAgent.Attachments.Bounds`; `truncated` says it was cut;
    * `pdf` — its text (`pdftotext`); a PDF with no text is a scan and is read
      like a picture, from its first pages;
    * `image` — checked to be a picture ImageMagick can read.

  A picture (or a scan) is shown to the model in one of two ways, decided here
  by the user's model as it is now (`PhoenixKitAgent.Models.image_input/1`,
  `picture_mode/1`):

    * the model is known to take images: the row stays without text — the turn
      sends the pixels, in its own message only
      (`PhoenixKitAgent.Attachments.pictures/1`); later turns carry a line that
      names the file, and the assistant's own answer about it;
    * it is known not to, or its abilities are not known (a provider without a
      model listing, a model that declares nothing): it is taken for a blind
      one, and the vision model of the module (`agent_vision_endpoint_uuid`)
      describes the picture once, now; the description is the row's text,
      which the history keeps. With no vision model a picture is refused by
      `PhoenixKitAgent.Attachments.add/4` before it is stored, and a scan
      (known to be one only here) `failed` as `no_vision_model`. The vision
      call is paid, so right before it is made the AI module must be on
      (`ai_disabled` otherwise), the session that added the file must still
      be one that may use the assistant (`session_gone` or `forbidden`), and
      the user must be within their limits (`limit_reached`) — the money
      limits as they apply to a description on the **vision** endpoint
      (`PhoenixKitAgent.Limits.money_counted?/2` with `:vision`: priced like
      a chat call — the provider's cost, a catalogue, a manual or a list
      price): one that nothing prices is held by the turn limit only. One
      user's descriptions are made one at a time (a `:global` lock per user,
      on every connected node), so each is checked against a journal that
      holds what the one before cost. The call carries the user and
      `source: "agent"` — the spending limits count it — and its content is
      never written to the AI journal.

  ## Failing safely

  A task never lives for ever (`process_deadline_ms`, then `timeout`), is kept
  to a heap size (a file that needs more is `too_large`), and turns every
  exception into a code; the codes are `unreadable`, `too_large`,
  `pdf_tools_missing`, `image_tools_missing`, `no_vision_model`,
  `ai_disabled`, `session_gone`, `forbidden`, `limit_reached`,
  `budget_exceeded`, `model_error`, `timeout`, `crashed`,
  `unavailable` (no place within `queue_wait_ms`, see `Attachments.Slots`, or no
  scratch space), and the refusals of the AI guard for the `agent.attachment`
  task: `task_blocked`, `task_limit_exceeded`, `model_unfit`,
  `model_unverified`, `no_provider_for_params`.

  The work is two processes: a *job* under `TaskSupervisor`, which waits for
  a place (at most `concurrent_jobs` jobs hold one, `jobs_per_user` of them
  one user's), makes the scratch directory (`Attachments.Work`),
  and the *worker* under `WorkerSupervisor`, which reads the file in it. The
  job removes the directory when the worker is done or killed. The file's content, what a parser said
  about it and what the model answered never reach the log — not as a message,
  nor in a crash report.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.Attachments.{Bounds, Extract, Slots, Work}
  alias PhoenixKitAgent.{Config, Conversations, Models, UserConfig}
  alias PhoenixKitAgent.Limits, as: SpendLimits
  alias PhoenixKitAgent.Schemas.{Attachment, Message}

  @task_supervisor PhoenixKitAgent.Attachments.TaskSupervisor
  @worker_supervisor PhoenixKitAgent.Attachments.WorkerSupervisor

  # The refusals of the AI guard a description keeps as its own code
  # (`{reason, …}` is the code `reason`), never as `model_error`.
  @guard_refusals ~w(task_blocked task_limit_exceeded model_unfit model_unverified
                     no_provider_for_params)a

  @describe_picture "Describe this picture for someone who cannot see it. Transcribe every " <>
                      "piece of text, number and table in it exactly, then say what else it shows."

  @describe_scan "These are the first pages of a scanned document. Transcribe all of its " <>
                   "text, numbers and tables exactly, page by page, then say what else the pages show."

  @typedoc "What the task found: the fields of the row to store."
  @type result :: {:ok, map()} | {:error, atom()}

  @doc """
  Starts the processing of the pending attachment `uuid` of the user
  `user_uuid`, added in the browser session `session_ref` (checked again
  before a paid call), and returns at once. The task waits for a place
  (`PhoenixKitAgent.Attachments.Slots`) before it does any work.
  """
  @spec start(String.t(), String.t(), Conversations.session_ref()) :: :ok
  def start(uuid, user_uuid, session_ref) do
    job = fn -> supervise(uuid, user_uuid, session_ref) end

    case Task.Supervisor.start_child(@task_supervisor, job) do
      {:ok, _pid} -> :ok
      _not_started -> finish(uuid, {:error, :unavailable})
    end
  catch
    :exit, _supervisor_gone -> finish(uuid, {:error, :unavailable})
  end

  # The scratch directory is made, and removed, here and not in the worker:
  # a worker that is killed (the deadline, the heap) cannot clean up after itself.
  defp supervise(uuid, user_uuid, session_ref) do
    with :ok <- Slots.acquire(user_uuid),
         {:ok, dir} <- Work.create() do
      outcome =
        try do
          run_worker(uuid, dir, session_ref)
        after
          Work.remove(dir)
        end

      finish(uuid, outcome)
    else
      {:error, _reason} -> finish(uuid, {:error, :unavailable})
    end
  end

  defp run_worker(uuid, dir, session_ref) do
    worker =
      Task.Supervisor.async_nolink(@worker_supervisor, fn -> work(uuid, dir, session_ref) end)

    case Task.yield(worker, Bounds.get(:process_deadline_ms)) ||
           Task.shutdown(worker, :brutal_kill) do
      {:ok, result} -> result
      # Killed for its heap (`max_heap_size`): the file was too much to read.
      {:exit, :killed} -> {:error, :too_large}
      # The reason of any other exit can hold the heap; it is not looked at.
      {:exit, _reason} -> {:error, :crashed}
      nil -> {:error, :timeout}
    end
  catch
    # `WorkerSupervisor` is not running (being restarted): no place to read the file.
    :exit, _no_worker_supervisor -> {:error, :unavailable}
  end

  # ── the worker ──────────────────────────────────────────────────────

  defp work(uuid, dir, session_ref) do
    Process.flag(:max_heap_size, %{
      size: Bounds.get(:worker_heap_words),
      kill: true,
      error_logger: false
    })

    Work.adopt(dir)

    with %Attachment{status: "pending", file_uuid: file_uuid} = attachment
         when is_binary(file_uuid) <-
           RepoHelper.repo().get(Attachment, uuid),
         {:ok, path} <- Work.fetch(file_uuid, dir) do
      process(attachment, path, session_ref)
    else
      _gone_or_not_stored -> {:error, :unreadable}
    end
  rescue
    _exception -> {:error, :crashed}
  catch
    _kind, _reason -> {:error, :crashed}
  end

  defp process(%{kind: "text"}, path, _session_ref), do: path |> Extract.text() |> fields()

  defp process(%{kind: "sheet", content_type: "text/csv"}, path, _session_ref),
    do: path |> Extract.csv() |> fields()

  defp process(%{kind: "sheet"}, path, _session_ref), do: path |> Extract.xlsx() |> fields()

  defp process(%{kind: "pdf"} = attachment, path, session_ref) do
    case Extract.pdf(path) do
      {:ok, {:scan, pages}} -> scan(attachment, path, pages, session_ref)
      other -> fields(other)
    end
  end

  defp process(%{kind: "image"} = attachment, path, session_ref) do
    with {:ok, jpeg} <- Extract.picture(path),
         settings = UserConfig.effective(attachment.user_uuid),
         {:ok, mode} <- picture_mode(settings) do
      case mode do
        :pixels ->
          {:ok, %{extracted_text: nil, truncated: false}}

        {:describe, vision} ->
          ask = {settings, session_ref, vision}
          describe(ask, [jpeg_input(jpeg)], @describe_picture, %{}, [])
      end
    end
  end

  defp scan(attachment, path, pages, session_ref) do
    settings = UserConfig.effective(attachment.user_uuid)

    with {:ok, mode} <- picture_mode(settings),
         {:ok, pngs, ^pages} <- Extract.pdf_pages(path) do
      shown = %{pages: pages, truncated: pages > length(pngs)}

      case mode do
        :pixels ->
          {:ok, Map.put(shown, :extracted_text, nil)}

        {:describe, vision} ->
          inputs = Enum.map(pngs, &%{data: &1, content_type: "image/png"})
          not_described = pages - length(pngs)

          notes =
            if not_described > 0,
              do: [
                Extract.continues(
                  "the document continues: #{not_described} of #{Extract.count(pages, "page")} not described"
                )
              ],
              else: []

          describe({settings, session_ref, vision}, inputs, @describe_scan, shown, notes)
      end
    end
  end

  defp fields({:ok, fields}) when is_map(fields), do: {:ok, rename(fields)}
  defp fields({:error, _code} = error), do: error

  defp rename(%{text: text} = fields),
    do: fields |> Map.delete(:text) |> Map.put(:extracted_text, text)

  defp jpeg_input(jpeg), do: %{data: jpeg, content_type: "image/jpeg"}

  # ── how a picture reaches the model ─────────────────────────────────

  @doc false
  # How a picture reaches the user's model (see the moduledoc): as pixels only
  # for a model known to take images; else described by the vision model, or
  # `no_vision_model` when there is none.
  @spec picture_mode(map()) ::
          {:ok, :pixels | {:describe, String.t()}} | {:error, :no_vision_model}
  def picture_mode(settings) do
    case {Models.image_input(settings.endpoint_uuid), Config.vision_endpoint_uuid()} do
      {:supported, _vision} -> {:ok, :pixels}
      {_blind_or_unknown, nil} -> {:error, :no_vision_model}
      {_blind_or_unknown, vision} -> {:ok, {:describe, vision}}
    end
  end

  # `ask` is who asks and whom: the user's settings, the session the file was
  # added in, the vision endpoint.
  defp describe({settings, _session_ref, _vision} = ask, inputs, prompt, fields, notes) do
    with {:ok, text} <- one_at_a_time(settings.user_uuid, fn -> paid(ask, inputs, prompt) end) do
      {text, clipped?} = Extract.clip(text)

      notes =
        if clipped?,
          do: [Extract.continues("the description continues: not shown in full") | notes],
          else: notes

      {:ok,
       Map.merge(fields, %{extracted_text: Enum.join([text | notes]), truncated: notes != []})}
    end
  end

  # The checks right before the paid call (see the moduledoc), then the call.
  defp paid({settings, session_ref, vision}, inputs, prompt) do
    with :ok <- ai_enabled(),
         :ok <- session_alive(session_ref, settings.user_uuid),
         :ok <- within_limits(settings, vision),
         do: ask_vision(settings, vision, inputs, prompt)
  end

  # One description of a user at a time, on every connected node: the lock is
  # held by this worker, and freed when it returns or is killed.
  defp one_at_a_time(user_uuid, fun),
    do: :global.trans({{__MODULE__, :describe, user_uuid}, self()}, fun)

  defp ai_enabled, do: if(PhoenixKitAI.enabled?(), do: :ok, else: {:error, :ai_disabled})

  # The session that added the file may still use the assistant, as its own
  # user (it was not an impersonated one: `Attachments.add/4` refuses those).
  defp session_alive(session_ref, user_uuid) do
    case Conversations.authorize_session(session_ref, impersonated: false) do
      {:ok, ^user_uuid} -> :ok
      {:error, reason} when reason in [:forbidden, :not_found] -> {:error, :forbidden}
      _ended -> {:error, :session_gone}
    end
  end

  # The money limits as they apply to the endpoint the call is paid on.
  defp within_limits(settings, vision) do
    case SpendLimits.check(settings, vision, use: :vision) do
      :ok -> :ok
      {:error, {:limit_reached, _status}} -> {:error, :limit_reached}
    end
  end

  defp ask_vision(settings, vision, inputs, prompt) do
    result =
      PhoenixKitAI.describe_image(vision, inputs,
        prompt: prompt,
        user_uuid: settings.user_uuid,
        source: "agent",
        task: "agent.attachment",
        capture_request_content: false,
        # Never answered from, nor put into, a cache the other users share.
        cache: false
      )

    case result do
      {:ok, %{text: text}} when is_binary(text) ->
        if String.trim(text) == "",
          do: {:error, :model_error},
          else: {:ok, text |> Message.strip_nul() |> String.trim()}

      {:error, {:budget_exceeded, _scope}} ->
        {:error, :budget_exceeded}

      {:error, reason} when is_tuple(reason) and elem(reason, 0) in @guard_refusals ->
        {:error, elem(reason, 0)}

      _failed ->
        {:error, :model_error}
    end
  end

  # ── the end ─────────────────────────────────────────────────────────

  # Writes the outcome of `uuid` if it is still pending (a discarded row, or one
  # that is settled already, is left alone) and tells the chat.
  defp finish(uuid, outcome) do
    changes =
      case outcome do
        {:ok, fields} ->
          [status: "ready", error: nil, pages: nil, extracted_text: nil, truncated: false]
          |> Keyword.merge(Map.to_list(Map.take(fields, [:extracted_text, :pages, :truncated])))

        {:error, code} ->
          [status: "failed", error: Atom.to_string(code)]
      end

    update(uuid, changes)
  rescue
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] an attachment could not be settled: #{inspect(exception.__struct__)}"
      )

      fail_quietly(uuid)
  end

  defp update(uuid, changes) do
    {count, conversations} =
      from(a in Attachment,
        where: a.uuid == ^uuid and a.status == "pending",
        select: a.conversation_uuid
      )
      |> RepoHelper.repo().update_all([set: changes], log: false)

    for conversation_uuid <- conversations, count == 1 do
      PubSub.broadcast(
        Conversations.topic(conversation_uuid),
        {:agent_attachment_processed, conversation_uuid, uuid}
      )
    end

    :ok
  end

  defp fail_quietly(uuid) do
    update(uuid, status: "failed", error: "crashed")
  rescue
    _ -> :ok
  end
end
