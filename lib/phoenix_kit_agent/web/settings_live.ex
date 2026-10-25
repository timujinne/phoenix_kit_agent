defmodule PhoenixKitAgent.Web.SettingsLive do
  @moduledoc """
  Settings → AI Agent: the module defaults (`PhoenixKitAgent.Config`, spec
  §5.6, §7) — the model the assistant uses and the one that describes
  pictures, the per-user limits a user without settings of their own gets,
  the limits of one turn, the module's system prompt and who is told when
  someone reaches a limit.

  The models are chosen among the AI endpoints that chat
  (`PhoenixKitAgent.Models.list_endpoints/1`); the default model's list marks
  the ones known not to take tools, the vision model's the ones known not to
  take pictures (both fetched off the page process after it opens). A model
  the page did not offer is refused, and `Config` takes only an existing
  endpoint that chats. A newly chosen model must also fit its AI task
  (`PhoenixKitAI.Tasks.check_selection/2`): the default model `agent.chat`
  (tools), the vision model `agent.attachment` (pictures). One known not to
  have what the task needs is refused, and so is one nobody knows about
  until an admin marks what it can do on its AI endpoint. The watchers are chosen among the people who hold
  `agent.manage`, the Owners and the watchers there are; nobody chosen means
  every Owner. The prompt's change is recorded in the Activity log as a field
  name, never its text (`Config.put_system_prompt/2`); the other values go to
  the settings history with who changed them.

  Needs `agent.manage`. The tab is registered under that key; the page checks
  it again on mount and before every save, against the socket's scope and
  against the scope of the session as it is now — the role it acts as, not the
  user's default one (`PhoenixKitAgent.Web.Access`): a right taken away, a
  switch to another role or a logout while the page is open stops the next
  save.

  Each form is saved on its own; every save checks the permission again.

  The last card shows what the assistant can use now, for the role the
  viewer's session acts as (`PhoenixKitAgent.Web.ToolAvailability`): the
  modules' read and write tools, available or closed and why. It is read when
  the page opens.

  When the default model does not report what a call costs
  (`PhoenixKitAgent.Models.reports_cost?/2`), the limits say that money is not
  counted for it and only the turn limit applies.

  One setting is not for every manager: `agent_capture_ai_content` (whether the
  bodies of the assistant's requests go to the AI journal, where every holder of
  `ai` reads them on `/admin/ai/usage`) is switched by an Owner only. The check
  is `Scope.owner?/1` in the `save_capture` handler, on every event — the tab is
  only gated by `agent.manage`, which an Admin holds — and the switch is not
  rendered for anyone else, who sees the state.
  """

  # `log: false`: LiveView would log every event with its parameters —
  # the module's prompt among them.
  use Phoenix.LiveView, log: false
  use Gettext, backend: PhoenixKitAgent.Gettext

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Checkbox, only: [checkbox: 1]
  import PhoenixKitWeb.Components.Core.DecimalInput, only: [decimal_input: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.Textarea, only: [textarea: 1]
  import PhoenixKitAgent.Web.ToolAvailability, only: [assistant_tools: 1]

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAgent.{Config, Models, UserConfig}
  alias PhoenixKitAgent.Web.{Access, ToolAvailability}

  # The fields of the models form.
  @model_fields ~w(default_endpoint_uuid vision_endpoint_uuid)

  @impl true
  def mount(_params, session, socket) do
    socket = Access.assign_session(socket, session)

    if Access.may_manage?(socket) do
      {:ok,
       socket
       |> assign(
         page_title: gettext("AI Agent"),
         page_subtitle: gettext("Defaults of the AI assistant"),
         page_section: gettext("Settings"),
         page_section_path: Routes.path("/admin/settings")
       )
       |> assign(money_off?: money_off?())
       |> assign_capture()
       |> assign_form(Config.defaults_changeset(%{}) |> Map.put(:action, nil))
       |> assign_models()
       |> assign_prompt(Config.system_prompt() || "", [])
       |> assign_watchers()
       |> assign(:assistant_tools, ToolAvailability.for_scope(Access.session_scope(socket)))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to the AI assistant settings."))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) when is_map(params) do
    {:noreply, assign_form(socket, Config.defaults_changeset(params))}
  end

  def handle_event("save", %{"settings" => params}, socket) when is_map(params) do
    if Access.may_manage?(socket), do: save(socket, params), else: {:noreply, denied(socket)}
  end

  def handle_event("save_capture", %{"capture" => %{"enabled" => enabled}}, socket)
      when enabled in ["true", "false"] do
    if Access.owner?(socket) and Access.may_manage?(socket) do
      save_capture(socket, enabled == "true")
    else
      {:noreply,
       socket
       |> assign_capture()
       |> put_flash(:error, gettext("Only an Owner can change this setting."))}
    end
  end

  def handle_event("save_models", %{"models" => params}, socket) when is_map(params) do
    if Access.may_manage?(socket),
      do: {:noreply, save_models(socket, params)},
      else: {:noreply, denied(socket)}
  end

  def handle_event("save_prompt", %{"prompt" => %{"text" => text}}, socket)
      when is_binary(text) do
    if Access.may_manage?(socket),
      do: {:noreply, save_prompt(socket, text)},
      else: {:noreply, denied(socket)}
  end

  def handle_event("save_watchers", %{"watchers" => %{"uuids" => uuids}}, socket)
      when is_list(uuids) do
    if Access.may_manage?(socket),
      do: {:noreply, save_watchers(socket, uuids)},
      else: {:noreply, denied(socket)}
  end

  # A crafted event without the form's fields.
  def handle_event(event, _params, socket)
      when event in [
             "validate",
             "save",
             "save_capture",
             "save_models",
             "save_prompt",
             "save_watchers"
           ],
      do: {:noreply, socket}

  @impl true
  def handle_async(:capabilities, {:ok, {tools, images}}, socket),
    do:
      {:noreply, update(socket, :models, &%{&1 | tools: tools, images: images, loading?: false})}

  def handle_async(:capabilities, {:exit, _reason}, socket) do
    unknown = Map.new(socket.assigns.models.endpoints, &{&1.uuid, :unknown})

    {:noreply, update(socket, :models, &%{&1 | tools: unknown, images: unknown, loading?: false})}
  end

  defp denied(socket),
    do: put_flash(socket, :error, gettext("You do not have access to the AI assistant settings."))

  # ── the models ────────────────────────────────────────────────────────

  # The endpoints the page offers, and what their models take, fetched off the
  # page process (the endpoints are read again there, so neither the page nor
  # the closure holds their keys).
  defp assign_models(socket) do
    current = current_models()

    endpoints =
      [include: Map.values(current)]
      |> Models.list_endpoints()
      |> Enum.map(&Models.summary/1)

    uuids = Enum.map(endpoints, & &1.uuid)

    socket =
      assign(socket,
        models: %{
          endpoints: endpoints,
          params: Map.new(current, fn {field, uuid} -> {field, uuid || ""} end),
          errors: %{},
          tools: %{},
          images: %{},
          loading?: endpoints != [] and connected?(socket)
        }
      )

    if endpoints != [] and connected?(socket),
      do:
        start_async(socket, :capabilities, fn ->
          {Models.tools_support_of(uuids), Models.image_input_support_of(uuids)}
        end),
      else: socket
  end

  defp current_models do
    %{
      "default_endpoint_uuid" => Config.default_endpoint_uuid(),
      "vision_endpoint_uuid" => Config.vision_endpoint_uuid()
    }
  end

  # Each field present must name a model the page offered (blank: none); only
  # a value that changed is written.
  defp save_models(socket, params) do
    models = socket.assigns.models
    offered = MapSet.new(models.endpoints, & &1.uuid)
    current = current_models()

    {chosen, errors} =
      Enum.reduce(@model_fields, {%{}, %{}}, fn field, {chosen, errors} ->
        case Map.fetch(params, field) do
          :error -> {chosen, errors}
          {:ok, ""} -> {Map.put(chosen, field, nil), errors}
          {:ok, uuid} when is_binary(uuid) -> offered_model(field, uuid, offered, chosen, errors)
          {:ok, _not_text} -> {chosen, Map.put(errors, field, [gettext("is not available")])}
        end
      end)

    shown = Map.merge(models.params, Map.new(params, fn {k, v} -> {k, text_or_blank(v)} end))

    if errors == %{} do
      chosen
      |> Enum.reject(fn {field, uuid} -> Map.fetch!(current, field) == uuid end)
      |> write_models(socket)
    else
      socket
      |> update(:models, &%{&1 | params: Map.take(shown, @model_fields), errors: errors})
      |> put_flash(:error, gettext("Nothing was saved: check the highlighted fields."))
    end
  end

  # The model kept as it is is not checked again: the form saves both fields.
  defp offered_model(field, uuid, offered, chosen, errors) do
    with true <- MapSet.member?(offered, uuid),
         :ok <- fits(field, uuid) do
      {Map.put(chosen, field, uuid), errors}
    else
      refusal -> {chosen, Map.put(errors, field, [unfit_text(field, refusal)])}
    end
  end

  defp fits(field, uuid) do
    if Map.fetch!(current_models(), field) == uuid,
      do: :ok,
      else: PhoenixKitAI.Tasks.check_selection(task_of(field), uuid)
  end

  defp task_of("default_endpoint_uuid"), do: "agent.chat"
  defp task_of("vision_endpoint_uuid"), do: "agent.attachment"

  defp unfit_text("default_endpoint_uuid", {:error, {:model_unfit, _missing}}),
    do: gettext("cannot be used: its model does not take tools, which the assistant needs")

  defp unfit_text("default_endpoint_uuid", {:error, {:model_unverified, _unclear}}),
    do:
      gettext(
        "cannot be used yet: nobody knows whether its model takes tools. Mark what it can do on its AI endpoint first"
      )

  defp unfit_text("vision_endpoint_uuid", {:error, {:model_unfit, _missing}}),
    do: gettext("cannot be used: its model does not take pictures")

  defp unfit_text("vision_endpoint_uuid", {:error, {:model_unverified, _unclear}}),
    do:
      gettext(
        "cannot be used yet: nobody knows whether its model takes pictures. Mark what it can do on its AI endpoint first"
      )

  defp unfit_text(_field, _not_offered), do: gettext("is not available")

  defp text_or_blank(value) when is_binary(value), do: value
  defp text_or_blank(_other), do: ""

  defp write_models(changes, socket) do
    opts = [actor_uuid: Access.user_uuid(socket), source: "settings"]

    failed =
      Enum.reject(changes, fn {field, uuid} ->
        match?({:ok, _}, write_model(field, uuid, opts))
      end)

    socket = socket |> assign(money_off?: money_off?()) |> assign_models()

    if failed == [],
      do: put_flash(socket, :info, gettext("AI assistant models saved.")),
      else:
        put_flash(
          socket,
          :error,
          gettext("A model could not be saved: it is no longer available. Choose again.")
        )
  end

  defp write_model("default_endpoint_uuid", uuid, opts),
    do: Config.put_default_endpoint(uuid, opts)

  defp write_model("vision_endpoint_uuid", uuid, opts), do: Config.put_vision_endpoint(uuid, opts)

  defp model_label(endpoint, support, unsupported, unknown) do
    base = "#{endpoint.name} (#{endpoint.model})"

    case Map.get(support, endpoint.uuid) do
      :unsupported -> base <> " — " <> unsupported
      :unknown -> base <> " — " <> unknown
      _supported_or_not_yet_known -> base
    end
  end

  defp default_options(models) do
    [
      {gettext("None"), ""}
      | Enum.map(models.endpoints, fn endpoint ->
          {model_label(endpoint, models.tools, gettext("no tools"), gettext("tools unknown")),
           endpoint.uuid}
        end)
    ]
  end

  defp vision_options(models) do
    [
      {gettext("None"), ""}
      | Enum.map(models.endpoints, fn endpoint ->
          {model_label(
             endpoint,
             models.images,
             gettext("does not take pictures"),
             gettext("pictures unknown")
           ), endpoint.uuid}
        end)
    ]
  end

  # ── the module prompt ─────────────────────────────────────────────────

  defp assign_prompt(socket, text, errors),
    do: assign(socket, prompt_text: text, prompt_errors: errors)

  defp save_prompt(socket, text) do
    case Config.put_system_prompt(text, actor_uuid: Access.user_uuid(socket)) do
      {:ok, _setting} ->
        socket
        |> assign_prompt(Config.system_prompt() || "", [])
        |> put_flash(:info, gettext("The assistant's prompt saved."))

      {:error, changeset} ->
        errors = Enum.map(changeset.errors, fn {_field, error} -> translate_error(error) end)

        socket
        |> assign_prompt(text, errors)
        |> put_flash(:error, gettext("Nothing was saved: check the highlighted fields."))
    end
  end

  # ── the limit watchers ────────────────────────────────────────────────

  defp assign_watchers(socket) do
    candidates =
      Enum.map(UserConfig.watcher_candidates(), &%{uuid: &1.uuid, email: &1.email})

    assign(socket, watchers: Config.limit_watchers(), watcher_candidates: candidates)
  end

  # Only people the page offered; a blank value is the form's empty choice.
  defp save_watchers(socket, uuids) do
    offered = MapSet.new(socket.assigns.watcher_candidates, & &1.uuid)
    chosen = Enum.reject(uuids, &(&1 == ""))

    if Enum.all?(chosen, &(is_binary(&1) and MapSet.member?(offered, &1))) do
      case Config.put_limit_watchers(chosen,
             actor_uuid: Access.user_uuid(socket),
             source: "settings"
           ) do
        {:ok, _setting} ->
          socket
          |> assign_watchers()
          |> put_flash(:info, gettext("Who is told about limits saved."))

        {:error, _reason} ->
          put_flash(socket, :error, gettext("Nothing was saved. Choose again."))
      end
    else
      socket
      |> assign_watchers()
      |> put_flash(:error, gettext("Nothing was saved: someone chosen is not on the list."))
    end
  end

  # ── the defaults form ─────────────────────────────────────────────────

  defp save(socket, params) do
    case Config.save_defaults(params, actor_uuid: Access.user_uuid(socket), source: "settings") do
      {:ok, _keys} ->
        {:noreply,
         socket
         |> assign_form(Config.defaults_changeset(%{}) |> Map.put(:action, nil))
         |> put_flash(:info, gettext("AI assistant defaults saved."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_form(changeset)
         |> put_flash(:error, gettext("Nothing was saved: check the highlighted fields."))}

      {:error, :not_saved} ->
        {:noreply,
         socket
         |> assign_form(Config.defaults_changeset(params))
         |> put_flash(:error, gettext("The defaults could not be saved. Nothing was changed."))}
    end
  end

  defp save_capture(socket, value) do
    case Config.put_capture_ai_content(value,
           actor_uuid: Access.user_uuid(socket),
           source: "settings"
         ) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> assign_capture()
         |> put_flash(:info, gettext("AI request journal setting saved."))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign_capture()
         |> put_flash(:error, gettext("The setting could not be saved. Nothing was changed."))}
    end
  end

  # What the capture section shows: the stored state, and whether this person
  # may change it.
  defp assign_capture(socket) do
    assign(socket, capture?: Config.capture_ai_content?(), owner?: Access.owner?(socket))
  end

  # Whether the default model leaves money uncounted (no default: nothing to say).
  defp money_off? do
    with uuid when is_binary(uuid) <- Config.default_endpoint_uuid(),
         %{} = endpoint <- PhoenixKitAI.get_endpoint(uuid) do
      not Models.reports_cost?(endpoint)
    else
      _none -> false
    end
  end

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(changeset, as: :settings))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full max-w-3xl gap-6 px-4 py-6">
      <section id="agent-models" class="card bg-base-100 shadow-sm">
        <.form for={%{}} as={:models} id="agent-models-form" phx-submit="save_models">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">{gettext("Models")}</h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "The AI endpoints of the AI module. A user without a model of their own uses the default one; without it the assistant does not answer. The vision model describes pictures for a model that does not take them."
              )}
            </p>
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <.select
                id="agent-default-endpoint"
                name="models[default_endpoint_uuid]"
                label={gettext("Default model")}
                value={@models.params["default_endpoint_uuid"]}
                options={default_options(@models)}
                errors={Map.get(@models.errors, "default_endpoint_uuid", [])}
              />
              <.select
                id="agent-vision-endpoint"
                name="models[vision_endpoint_uuid]"
                label={gettext("Vision model")}
                value={@models.params["vision_endpoint_uuid"]}
                options={vision_options(@models)}
                errors={Map.get(@models.errors, "vision_endpoint_uuid", [])}
              />
            </div>
            <p :if={@models.loading?} class="text-xs text-base-content/60">
              {gettext("Checking what the models take…")}
            </p>
            <div class="flex justify-end">
              <.button type="submit" variant="primary" id="agent-models-save">
                {gettext("Save")}
              </.button>
            </div>
          </div>
        </.form>
      </section>

      <.form for={@form} id="agent-settings-form" phx-change="validate" phx-submit="save">
        <section class="card bg-base-100 shadow-sm">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">{gettext("Default limits per user")}</h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "Apply to every user without limits of their own. Money is counted from the AI request journal, in US dollars, for endpoints that report a cost."
              )}
            </p>
            <p :if={@money_off?} id="agent-settings-money-off" class="text-sm text-warning">
              {gettext(
                "The default model does not report what a call costs: money is not counted, only the turn limit applies."
              )}
            </p>
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <.decimal_input
                field={@form[:daily_cost_limit_usd]}
                label={gettext("Spending per day")}
                unit="$"
              />
              <.decimal_input
                field={@form[:monthly_cost_limit_usd]}
                label={gettext("Spending per month")}
                unit="$"
              />
              <.decimal_input field={@form[:daily_turn_limit]} label={gettext("Turns per day")} />
              <.decimal_input
                field={@form[:max_attachment_mb]}
                label={gettext("Largest attachment")}
                unit={pgettext("unit", "MB")}
              />
              <.decimal_input
                field={@form[:max_attachments_per_message]}
                label={gettext("Attachments per message")}
              />
            </div>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm mt-6">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">{gettext("One turn")}</h2>
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <.decimal_input
                field={@form[:max_tool_rounds]}
                label={gettext("Tool rounds per turn")}
              />
              <.decimal_input
                field={@form[:turn_deadline_s]}
                label={gettext("Turn deadline")}
                unit={pgettext("unit", "s")}
              />
              <.decimal_input
                field={@form[:history_chars]}
                label={gettext("History sent to the model, characters")}
              />
              <.decimal_input
                field={@form[:tool_result_chars]}
                label={gettext("One tool result, characters")}
              />
            </div>
          </div>
        </section>

        <div class="mt-6 flex justify-end">
          <.button type="submit" variant="primary" id="agent-settings-save">
            {gettext("Save")}
          </.button>
        </div>
      </.form>

      <section id="agent-prompt" class="card bg-base-100 shadow-sm">
        <.form for={%{}} as={:prompt} id="agent-prompt-form" phx-submit="save_prompt">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">{gettext("The assistant's prompt")}</h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "Goes first into every request of every user, before the site's own part, the prompt an administrator sets for a user and the user's own instructions."
              )}
            </p>
            <.textarea
              id="agent-prompt-text"
              name="prompt[text]"
              value={@prompt_text}
              errors={@prompt_errors}
              rows="8"
              maxlength="16000"
            />
            <div class="flex justify-end">
              <.button type="submit" variant="primary" id="agent-prompt-save">
                {gettext("Save")}
              </.button>
            </div>
          </div>
        </.form>
      </section>

      <section id="agent-watchers" class="card bg-base-100 shadow-sm">
        <.form for={%{}} as={:watchers} id="agent-watchers-form" phx-submit="save_watchers">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">{gettext("Who is told about limits")}</h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "When a user reaches a limit and their settings say to tell someone, and when the AI budget is used up."
              )}
            </p>
            <p :if={@watchers == []} id="agent-watchers-none" class="text-sm">
              {gettext("Nobody is chosen: every Owner is told.")}
            </p>
            <input type="hidden" name="watchers[uuids][]" value="" />
            <ul class="flex flex-col gap-2">
              <li :for={candidate <- @watcher_candidates}>
                <label class="flex items-center gap-3 text-sm cursor-pointer">
                  <input
                    type="checkbox"
                    id={"agent-watcher-#{candidate.uuid}"}
                    name="watchers[uuids][]"
                    value={candidate.uuid}
                    checked={candidate.uuid in @watchers}
                    class="checkbox checkbox-sm"
                  />
                  <span>{candidate.email}</span>
                </label>
              </li>
            </ul>
            <div class="flex justify-end">
              <.button type="submit" variant="primary" id="agent-watchers-save">
                {gettext("Save")}
              </.button>
            </div>
          </div>
        </.form>
      </section>

      <section id="agent-capture" class="card bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="card-title text-base">{gettext("Request content in the AI journal")}</h2>
          <p id="agent-capture-note" class="text-sm text-base-content/70">
            {gettext(
              "When on, the full text of the assistant's requests and answers, with the data its tools returned, is written to the AI request journal, where everyone who holds the AI permission can read it on the AI usage page (/admin/ai/usage). When off, the journal keeps only the counts and the cost."
            )}
          </p>
          <.form
            :if={@owner?}
            for={%{}}
            as={:capture}
            id="agent-capture-form"
            phx-submit="save_capture"
            class="flex items-center justify-between gap-4"
          >
            <.checkbox
              variant="toggle"
              id="agent-capture-enabled"
              name="capture[enabled]"
              checked={@capture?}
              label={gettext("Write request content to the AI journal")}
            />
            <.button type="submit" variant="primary" id="agent-capture-save">
              {gettext("Save")}
            </.button>
          </.form>
          <p :if={!@owner?} id="agent-capture-status" class="text-sm">
            <span class={["badge", if(@capture?, do: "badge-warning", else: "badge-ghost")]}>
              {if @capture?, do: gettext("On"), else: gettext("Off")}
            </span>
            {gettext("Only an Owner can change this setting.")}
          </p>
        </div>
      </section>

      <.assistant_tools id="agent-tools" modules={@assistant_tools} subject={:session} />
    </div>
    """
  end
end
