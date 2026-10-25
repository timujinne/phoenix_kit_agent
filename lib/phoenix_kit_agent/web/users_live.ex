defmodule PhoenixKitAgent.Web.UsersLive do
  @moduledoc """
  Admin → Agent → Users: the people who hold the `agent` permission, each with
  the model they use, their limits, what they spent today and this month and
  whether a limit being hit is reported — and a form to set one user's
  settings (the switch, the model, the admin's prompt, the limits, the notice
  flag; `PhoenixKitAgent.UserConfig.admin_update/4`).

  Needs `agent.manage`. The tab is registered under that key; the page checks
  it again on mount and on every event that opens or saves a form, against the
  socket's scope and the scope of the session as it is now, narrowed to the
  role the session acts as (`PhoenixKitAgent.Web.Access`), and the context
  function checks it a third time against that session scope. An Owner's
  settings are opened and saved by an Owner only. The user being edited is the
  one the server opened the form for — a `user` in a submit is never read —
  and only the fields the form offers are taken from it, so a forged submit
  cannot reach the lock columns, the user's own instructions or the notice
  list. A model that the form did not offer (one that cannot chat, or does not
  exist) is refused, and so is a newly chosen one that does not fit the
  `agent.chat` AI task (`PhoenixKitAI.Tasks.check_selection/2`): known not
  to take tools, or not known to. A save after someone else changed the same user's
  settings since the form opened is refused (`expected:` of
  `UserConfig.admin_update/4`), not written over their change.

  A user whose model does not report what a call costs
  (`PhoenixKitAgent.Models.reports_cost?/2`) is marked: money is not counted
  for them and only the turn limit applies — in the list, and in the form for
  the model chosen there.

  Under the open form, what the user's assistant can use now
  (`PhoenixKitAgent.Web.ToolAvailability`): the modules' read and write tools
  by every role the user holds, which the role of a session can narrow; read
  when the form opens.

  Who changed what for whom goes to the core Activity log, field names only.
  The model list marks the endpoints whose model is known not to take tools, and
  those where that is unknown (`PhoenixKitAgent.Models`); that listing is
  fetched off the page process after the form opens. The page keeps endpoints
  as `PhoenixKitAgent.Models.summary/1` — never the endpoint row with its key.

  A user blocked from the AI guard's `free_text` group (the assistant and
  the AI Playground, `PhoenixKitAI.GuardBlocks`) is marked, with the
  block's reason only for a viewer who may see it (`GuardBlocks.active/3`
  with the session's scope: `ai.manage` or an Owner). "Lift" calls
  `PhoenixKitAI.Guard.unblock/3` with that scope for the block the server
  finds for the row's user, after `agent.manage` is checked again; the
  guard refuses one's own block and an Owner's (unless the viewer is an
  Owner), and the button is shown only where it would not refuse.
  """

  # `log: false`: LiveView would log every event with its parameters —
  # the prompt an admin writes for a user among them.
  use Phoenix.LiveView, log: false
  use Gettext, backend: PhoenixKitAgent.Gettext

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Checkbox, only: [checkbox: 1]
  import PhoenixKitWeb.Components.Core.DecimalInput, only: [decimal_input: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.Textarea, only: [textarea: 1]
  import PhoenixKitAgent.Web.ToolAvailability, only: [assistant_tools: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.{Number, Routes}
  alias PhoenixKitAgent.{Config, Models, Spend, UserConfig}
  alias PhoenixKitAgent.Web.{Access, ToolAvailability}
  alias PhoenixKitAI.GuardBlocks

  # The fields of the form, as they are named in its submit, and the fields of
  # `UserSettings.admin_changeset/2` they are for. Money is typed in dollars and
  # kept as micro-dollars.
  @plain_fields %{
    "enabled" => :enabled,
    "system_prompt" => :system_prompt,
    "notify_on_limit" => :notify_on_limit,
    "daily_turn_limit" => :daily_turn_limit,
    "max_attachment_mb" => :max_attachment_mb,
    "max_attachments_per_message" => :max_attachments_per_message
  }
  @money_fields %{
    "daily_cost_limit_usd" => :daily_cost_limit_micro_usd,
    "monthly_cost_limit_usd" => :monthly_cost_limit_micro_usd
  }
  # The plain fields that hold a whole number.
  @whole_fields ~w(daily_turn_limit max_attachment_mb max_attachments_per_message)

  # The stored fields the form shows: a save is refused when one of them
  # changed since the form opened.
  @shown_fields [:endpoint_uuid | Map.values(@plain_fields) ++ Map.values(@money_fields)]

  @impl true
  def mount(_params, session, socket) do
    socket = Access.assign_session(socket, session)

    if Access.may_manage?(socket) do
      {:ok,
       socket
       |> assign(
         page_title: gettext("Users"),
         page_subtitle: gettext("Who uses the AI assistant, and with which limits"),
         page_section: gettext("AI Agent"),
         page_section_path: Routes.path("/admin/agent/users"),
         editing: nil
       )
       |> load_rows()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to the AI assistant users."))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  # ── events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("configure", %{"user" => user_uuid}, socket) do
    cond do
      not Access.may_manage?(socket) ->
        {:noreply, denied(socket)}

      not UserConfig.agent_user?(user_uuid) ->
        {:noreply, put_flash(socket, :error, gettext("This user does not use the assistant."))}

      not UserConfig.may_configure?(Access.session_scope(socket), user_uuid) ->
        {:noreply, owner_only(socket)}

      true ->
        {:noreply, open_form(socket, user_uuid)}
    end
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("lift_block", %{"user" => user_uuid}, socket) when is_binary(user_uuid) do
    if Access.may_manage?(socket),
      do: {:noreply, lift_block(socket, user_uuid)},
      else: {:noreply, denied(socket)}
  end

  def handle_event("validate_user", %{"user_settings" => params}, socket)
      when is_map(params) do
    {:noreply, update_editing(socket, &%{&1 | params: Map.merge(&1.params, text_params(params))})}
  end

  def handle_event("save_user", %{"user_settings" => params}, socket) when is_map(params) do
    case socket.assigns.editing do
      nil -> {:noreply, socket}
      editing -> {:noreply, save(socket, editing, params)}
    end
  end

  # A crafted event without the form's fields.
  def handle_event(event, _params, socket)
      when event in ["configure", "validate_user", "save_user", "lift_block"],
      do: {:noreply, socket}

  @impl true
  def handle_async(:tools, {:ok, {user_uuid, support}}, socket) do
    {:noreply, update_editing(socket, user_uuid, &%{&1 | tools: support, tools_loading?: false})}
  end

  def handle_async(:tools, {:exit, _reason}, socket) do
    {:noreply,
     update_editing(socket, fn editing ->
       unknown = Map.new(editing.endpoints, &{&1.uuid, :unknown})
       %{editing | tools: unknown, tools_loading?: false}
     end)}
  end

  # ── the list ──────────────────────────────────────────────────────────

  defp load_rows(socket) do
    users = UserConfig.agent_users()
    uuids = Enum.map(users, & &1.uuid)
    effective = UserConfig.effective_many(uuids)
    spend = Spend.for_users(uuids)

    endpoints =
      effective |> Map.values() |> Enum.map(& &1.endpoint_uuid) |> Enum.reject(&is_nil/1)

    endpoints = Models.summaries(endpoints)
    owners = "Owner" |> Roles.users_with_role() |> MapSet.new(& &1.uuid)
    viewer = Access.session_scope(socket)

    rows =
      Enum.map(users, fn user ->
        settings = Map.fetch!(effective, user.uuid)
        endpoint = Map.get(endpoints, settings.endpoint_uuid)

        %{
          user: user,
          owner?: MapSet.member?(owners, user.uuid),
          settings: settings,
          spend: Map.fetch!(spend, user.uuid),
          endpoint: endpoint,
          money_off?: endpoint != nil and not Models.reports_cost?(endpoint),
          own_endpoint?: :endpoint_uuid in settings.own,
          block: block_of(user.uuid, viewer)
        }
      end)

    assign(socket, rows: rows, owner?: Access.owner?(socket))
  end

  # The user's active block of the assistant's group as the viewer may see
  # it, and whether the viewer may lift it.
  defp block_of(user_uuid, viewer) do
    case GuardBlocks.active("agent.chat", user_uuid, viewer) do
      nil -> nil
      block -> %{reason: block.reason, liftable?: GuardBlocks.may_lift?(viewer, block)}
    end
  end

  # ── a block ───────────────────────────────────────────────────────────

  # The block is the one the server finds for the user now, never one the
  # browser names.
  defp lift_block(socket, user_uuid) do
    with {:ok, user_uuid} <- Ecto.UUID.cast(user_uuid),
         %{} = block <- GuardBlocks.active("agent.chat", user_uuid),
         {:ok, _lifted} <- PhoenixKitAI.Guard.unblock(Access.session_scope(socket), block, nil) do
      socket |> load_rows() |> put_flash(:info, gettext("The block is lifted."))
    else
      {:error, :own_block} ->
        put_flash(socket, :error, gettext("Nobody but an Owner lifts their own block."))

      {:error, :owner_only} ->
        put_flash(socket, :error, gettext("Only an Owner can lift an Owner's block."))

      {:error, :forbidden} ->
        denied(socket)

      _gone ->
        socket |> load_rows() |> put_flash(:error, gettext("This user is not blocked now."))
    end
  end

  # ── the form ──────────────────────────────────────────────────────────

  defp open_form(socket, user_uuid) do
    row = UserConfig.get(user_uuid)

    # A user given `agent` after the list was loaded is not in it yet.
    socket =
      if listed(socket, row.user_uuid), do: socket, else: load_rows(socket)

    case listed(socket, row.user_uuid) do
      nil ->
        put_flash(socket, :error, gettext("This user does not use the assistant."))

      listed ->
        endpoints = [include: row.endpoint_uuid] |> Models.list_endpoints() |> summaries()

        socket
        |> assign(
          editing: %{
            user: listed.user,
            params: form_params(row),
            shown: Map.take(row, @shown_fields),
            errors: %{},
            endpoints: endpoints,
            tools: %{},
            tools_loading?: endpoints != [],
            default_endpoint: default_endpoint(),
            assistant_tools: tools_by_roles(listed.user)
          }
        )
        |> start_tools(listed.user.uuid, Enum.map(endpoints, & &1.uuid))
    end
  end

  # What the user's assistant can use by every role they hold: a session acting
  # as one of them sees no more than that.
  defp tools_by_roles(user),
    do: user |> Scope.for_user(narrow: false) |> ToolAvailability.for_scope()

  defp listed(socket, user_uuid), do: Enum.find(socket.assigns.rows, &(&1.user.uuid == user_uuid))

  defp summaries(endpoints), do: Enum.map(endpoints, &Models.summary/1)

  defp start_tools(socket, _user_uuid, []), do: socket

  # The endpoints are read again off the page process, so neither the page
  # nor the closure holds their keys.
  defp start_tools(socket, user_uuid, endpoint_uuids) do
    start_async(socket, :tools, fn -> {user_uuid, Models.tools_support_of(endpoint_uuids)} end)
  end

  defp default_endpoint do
    with uuid when is_binary(uuid) <- Config.default_endpoint_uuid(),
         %{} = endpoint <- PhoenixKitAI.get_endpoint(uuid) do
      Models.summary(endpoint)
    else
      _ -> nil
    end
  end

  defp form_params(row) do
    %{
      "enabled" => if(row.enabled == false, do: "false", else: ""),
      "endpoint_uuid" => row.endpoint_uuid || "",
      "system_prompt" => row.system_prompt || "",
      "daily_cost_limit_usd" => usd_param(row.daily_cost_limit_micro_usd),
      "monthly_cost_limit_usd" => usd_param(row.monthly_cost_limit_micro_usd),
      "daily_turn_limit" => int_param(row.daily_turn_limit),
      "max_attachment_mb" => int_param(row.max_attachment_mb),
      "max_attachments_per_message" => int_param(row.max_attachments_per_message),
      "notify_on_limit" => to_string(row.notify_on_limit == true)
    }
  end

  defp usd_param(nil), do: ""
  defp usd_param(micro), do: Config.micro_to_usd(micro)

  defp int_param(nil), do: ""
  defp int_param(n), do: Integer.to_string(n)

  # What the form offers, as strings.
  defp text_params(params) do
    keys = ["endpoint_uuid" | Map.keys(@plain_fields) ++ Map.keys(@money_fields)]
    for key <- keys, is_binary(params[key]), into: %{}, do: {key, params[key]}
  end

  defp update_editing(socket, fun), do: update_editing(socket, nil, fun)

  defp update_editing(%{assigns: %{editing: nil}} = socket, _user_uuid, _fun), do: socket

  defp update_editing(%{assigns: %{editing: editing}} = socket, user_uuid, fun) do
    if user_uuid in [nil, editing.user.uuid],
      do: assign(socket, editing: fun.(editing)),
      else: socket
  end

  # ── saving ────────────────────────────────────────────────────────────

  defp save(socket, editing, params) do
    submitted = text_params(params)

    cond do
      not Access.may_manage?(socket) ->
        denied(socket)

      not UserConfig.agent_user?(editing.user.uuid) ->
        socket
        |> assign(editing: nil)
        |> put_flash(:error, gettext("This user does not use the assistant."))

      true ->
        case attrs(submitted, editing) do
          {:ok, attrs} -> update_user(socket, editing, submitted, attrs)
          {:error, errors} -> show_errors(socket, editing, submitted, errors)
        end
    end
  end

  defp update_user(socket, editing, submitted, attrs) do
    case UserConfig.admin_update(Access.session_scope(socket), editing.user.uuid, attrs,
           expected: editing.shown
         ) do
      {:ok, _row, _fields} ->
        socket
        |> assign(editing: nil)
        |> load_rows()
        |> put_flash(:info, gettext("Settings saved."))

      {:error, %Ecto.Changeset{} = changeset} ->
        show_errors(socket, editing, submitted, changeset_errors(changeset))

      # The model stopped fitting between the form's check and the save.
      {:error, {reason, _needs} = refusal} when reason in [:model_unfit, :model_unverified] ->
        show_errors(socket, editing, submitted, %{endpoint_uuid: [unfit_text(refusal)]})

      {:error, :forbidden} ->
        if Access.may_manage?(socket), do: owner_only(socket), else: denied(socket)

      {:error, :stale} ->
        socket
        |> assign(editing: nil)
        |> load_rows()
        |> put_flash(
          :error,
          gettext(
            "Someone else changed these settings after the form was opened. Nothing was saved: open the form again."
          )
        )

      {:error, :not_found} ->
        socket
        |> assign(editing: nil)
        |> put_flash(:error, gettext("This user does not use the assistant."))
    end
  end

  defp show_errors(socket, editing, submitted, errors) do
    socket
    |> assign(editing: %{editing | params: Map.merge(editing.params, submitted), errors: errors})
    |> put_flash(:error, gettext("Nothing was saved: check the highlighted fields."))
  end

  defp denied(socket),
    do: put_flash(socket, :error, gettext("You do not have access to the AI assistant users."))

  defp owner_only(socket),
    do: put_flash(socket, :error, gettext("Only an Owner can change an Owner's assistant."))

  # The fields present in the submit as `admin_changeset/2` takes them: blank
  # means "the module default" (`nil`), dollars become micro-dollars, the model
  # must be one the form offered.
  defp attrs(submitted, editing) do
    {attrs, errors} =
      Enum.reduce(submitted, {%{}, %{}}, fn {key, value}, {attrs, errors} ->
        cond do
          Map.has_key?(@money_fields, key) -> money(key, value, attrs, errors)
          key == "endpoint_uuid" -> endpoint(value, editing, attrs, errors)
          key in @whole_fields -> whole(key, value, attrs, errors)
          true -> {Map.put(attrs, Map.fetch!(@plain_fields, key), blank_to_nil(value)), errors}
        end
      end)

    if errors == %{}, do: {:ok, attrs}, else: {:error, errors}
  end

  defp money(key, value, attrs, errors) do
    field = Map.fetch!(@money_fields, key)

    case blank_to_nil(value) do
      nil ->
        {Map.put(attrs, field, nil), errors}

      text ->
        case Config.usd_to_micro(text) do
          {:ok, micro} ->
            {Map.put(attrs, field, micro), errors}

          {:error, :fraction} ->
            {attrs, Map.put(errors, field, [gettext("is finer than a millionth of a dollar")])}

          {:error, _reason} ->
            {attrs, Map.put(errors, field, [gettext("is not a valid amount")])}
        end
    end
  end

  # Read as `decimal_input` lets it be typed ("1 000", "3,0"); the range is
  # the changeset's.
  defp whole(key, value, attrs, errors) do
    field = Map.fetch!(@plain_fields, key)

    case blank_to_nil(value) do
      nil ->
        {Map.put(attrs, field, nil), errors}

      text ->
        with {:ok, decimal} <- Number.parse_decimal(text),
             true <- Decimal.integer?(decimal) do
          {Map.put(attrs, field, Decimal.to_integer(decimal)), errors}
        else
          _not_whole -> {attrs, Map.put(errors, field, [gettext("is not a whole number")])}
        end
    end
  end

  defp endpoint(value, editing, attrs, errors) do
    case blank_to_nil(value) do
      nil ->
        {Map.put(attrs, :endpoint_uuid, nil), errors}

      uuid ->
        case chosen_endpoint(uuid, editing) do
          :ok -> {Map.put(attrs, :endpoint_uuid, uuid), errors}
          {:error, message} -> {attrs, Map.put(errors, :endpoint_uuid, [message])}
        end
    end
  end

  # One the form offered, and — when it is a new choice — one that fits the
  # assistant's AI task.
  defp chosen_endpoint(uuid, editing) do
    cond do
      not Enum.any?(editing.endpoints, &(&1.uuid == uuid)) ->
        {:error, gettext("is not available")}

      uuid == editing.shown.endpoint_uuid ->
        :ok

      true ->
        case PhoenixKitAI.Tasks.check_selection("agent.chat", uuid) do
          :ok -> :ok
          {:error, refusal} -> {:error, unfit_text(refusal)}
        end
    end
  end

  defp unfit_text({:model_unfit, _missing}),
    do: gettext("cannot be used: its model does not take tools, which the assistant needs")

  defp unfit_text({:model_unverified, _unclear}),
    do:
      gettext(
        "cannot be used yet: nobody knows whether its model takes tools. Mark what it can do on its AI endpoint first"
      )

  defp unfit_text(_gone), do: gettext("is not available")

  defp blank_to_nil(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
  end

  # ── rendering ─────────────────────────────────────────────────────────

  defp usd(micro), do: Spend.format_usd(micro)

  # Whether money goes uncounted for the model chosen in the form (the
  # module's when none is).
  defp money_off?(editing) do
    chosen =
      case editing.params["endpoint_uuid"] do
        uuid when uuid in [nil, ""] -> editing.default_endpoint
        uuid -> Enum.find(editing.endpoints, &(&1.uuid == uuid))
      end

    chosen != nil and not Models.reports_cost?(chosen)
  end

  defp endpoint_label(endpoint, editing) do
    base = "#{endpoint.name} (#{endpoint.model})"

    case Map.get(editing.tools, endpoint.uuid) do
      :unsupported -> base <> " — " <> gettext("no tools")
      :unknown -> base <> " — " <> gettext("tools unknown")
      _supported_or_not_yet_known -> base
    end
  end

  defp endpoint_options(editing) do
    default =
      case editing.default_endpoint do
        %{name: name} -> gettext("Module default (%{name})", name: name)
        nil -> gettext("Module default (none set)")
      end

    [{default, ""} | Enum.map(editing.endpoints, &{endpoint_label(&1, editing), &1.uuid})]
  end

  defp errors(editing, field), do: Map.get(editing.errors, field, [])

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full max-w-6xl gap-6 px-4 py-6">
      <section :if={@editing} id="agent-user-form-section" class="card bg-base-100 shadow-sm">
        <.form
          for={%{}}
          as={:user_settings}
          id="agent-user-form"
          phx-change="validate_user"
          phx-submit="save_user"
        >
          <div class="card-body gap-4">
            <h2 class="card-title text-base">
              {gettext("Settings of %{user}", user: @editing.user.email)}
            </h2>

            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <.select
                id="agent-user-enabled"
                name="user_settings[enabled]"
                label={gettext("Assistant")}
                value={@editing.params["enabled"]}
                options={[{gettext("Allowed"), ""}, {gettext("Switched off"), "false"}]}
                errors={errors(@editing, :enabled)}
              />
              <div>
                <.select
                  id="agent-user-endpoint"
                  name="user_settings[endpoint_uuid]"
                  label={gettext("Model")}
                  value={@editing.params["endpoint_uuid"]}
                  options={endpoint_options(@editing)}
                  errors={errors(@editing, :endpoint_uuid)}
                />
                <p :if={@editing.tools_loading?} class="mt-1 text-xs text-base-content/60">
                  {gettext("Checking which models take tools…")}
                </p>
              </div>
            </div>

            <.textarea
              id="agent-user-system-prompt"
              name="user_settings[system_prompt]"
              label={gettext("Prompt for this user")}
              value={@editing.params["system_prompt"]}
              errors={errors(@editing, :system_prompt)}
              rows="4"
            />

            <p :if={money_off?(@editing)} id="agent-user-money-off" class="text-sm text-warning">
              {gettext(
                "This model does not report what a call costs: money is not counted, only the turn limit applies."
              )}
            </p>

            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <.decimal_input
                id="agent-user-daily-cost"
                name="user_settings[daily_cost_limit_usd]"
                label={gettext("Spending per day")}
                unit="$"
                value={@editing.params["daily_cost_limit_usd"]}
                errors={errors(@editing, :daily_cost_limit_micro_usd)}
                placeholder={gettext("module default")}
              />
              <.decimal_input
                id="agent-user-monthly-cost"
                name="user_settings[monthly_cost_limit_usd]"
                label={gettext("Spending per month")}
                unit="$"
                value={@editing.params["monthly_cost_limit_usd"]}
                errors={errors(@editing, :monthly_cost_limit_micro_usd)}
                placeholder={gettext("module default")}
              />
              <.decimal_input
                id="agent-user-turns"
                name="user_settings[daily_turn_limit]"
                label={gettext("Turns per day")}
                value={@editing.params["daily_turn_limit"]}
                errors={errors(@editing, :daily_turn_limit)}
                placeholder={gettext("module default")}
              />
              <.decimal_input
                id="agent-user-attachment-mb"
                name="user_settings[max_attachment_mb]"
                label={gettext("Largest attachment")}
                unit={pgettext("unit", "MB")}
                value={@editing.params["max_attachment_mb"]}
                errors={errors(@editing, :max_attachment_mb)}
                placeholder={gettext("module default")}
              />
              <.decimal_input
                id="agent-user-attachments"
                name="user_settings[max_attachments_per_message]"
                label={gettext("Attachments per message")}
                value={@editing.params["max_attachments_per_message"]}
                errors={errors(@editing, :max_attachments_per_message)}
                placeholder={gettext("module default")}
              />
            </div>

            <.checkbox
              id="agent-user-notify"
              name="user_settings[notify_on_limit]"
              checked={@editing.params["notify_on_limit"] == "true"}
              label={gettext("Tell the watchers when this user reaches a limit")}
            />

            <div class="flex justify-end gap-2">
              <.button type="button" variant="ghost" id="agent-user-cancel" phx-click="cancel">
                {gettext("Cancel")}
              </.button>
              <.button type="submit" variant="primary" id="agent-user-save">
                {gettext("Save")}
              </.button>
            </div>
          </div>
        </.form>
      </section>

      <.assistant_tools
        :if={@editing}
        id="agent-user-tools"
        modules={@editing.assistant_tools}
        subject={:user}
      />

      <section class="card bg-base-100 shadow-sm">
        <div class="overflow-x-auto">
          <table id="agent-users" class="table">
            <thead>
              <tr>
                <th>{gettext("User")}</th>
                <th>{gettext("Model")}</th>
                <th>{gettext("Limits")}</th>
                <th class="text-right">{gettext("Today")}</th>
                <th class="text-right">{gettext("This month")}</th>
                <th>{gettext("Notify")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} id={"agent-user-#{row.user.uuid}"}>
                <td>
                  <div class="font-medium">{row.user.email}</div>
                  <span
                    id={"agent-user-#{row.user.uuid}-status"}
                    data-off={not row.settings.enabled? || nil}
                    class={[
                      "badge badge-sm",
                      if(row.settings.enabled?, do: "badge-ghost", else: "badge-error")
                    ]}
                  >
                    {if row.settings.enabled?, do: gettext("Active"), else: gettext("Switched off")}
                  </span>
                  <div :if={row.block} id={"agent-user-#{row.user.uuid}-blocked"} class="mt-1">
                    <span class="badge badge-sm badge-warning">{gettext("Blocked")}</span>
                    <div
                      :if={row.block.reason}
                      id={"agent-user-#{row.user.uuid}-block-reason"}
                      class="text-xs text-base-content/70"
                    >
                      {row.block.reason}
                    </div>
                  </div>
                </td>
                <td id={"agent-user-#{row.user.uuid}-model"}>
                  <%= if row.endpoint do %>
                    <div>{row.endpoint.name}</div>
                    <div class="text-xs text-base-content/60">
                      {row.endpoint.model}
                      <span :if={!row.own_endpoint?}>· {gettext("module default")}</span>
                    </div>
                  <% else %>
                    <span class="text-base-content/60">{gettext("not set")}</span>
                  <% end %>
                </td>
                <td id={"agent-user-#{row.user.uuid}-limits"} class="text-sm">
                  <div>
                    ${usd(row.settings.daily_cost_limit_micro_usd)} / {gettext("day")}
                  </div>
                  <div>
                    ${usd(row.settings.monthly_cost_limit_micro_usd)} / {gettext("month")}
                  </div>
                  <div>
                    {row.settings.daily_turn_limit} {gettext("turns")} / {gettext("day")}
                  </div>
                  <div
                    :if={row.money_off?}
                    id={"agent-user-#{row.user.uuid}-money-off"}
                    class="text-xs text-warning"
                  >
                    {gettext("money is not counted — only the turn limit applies")}
                  </div>
                </td>
                <td id={"agent-user-#{row.user.uuid}-day"} class="text-right tabular-nums">
                  ${usd(row.spend.day_micro_usd)}
                </td>
                <td id={"agent-user-#{row.user.uuid}-month"} class="text-right tabular-nums">
                  ${usd(row.spend.month_micro_usd)}
                </td>
                <td
                  id={"agent-user-#{row.user.uuid}-notify"}
                  data-on={row.settings.notify_on_limit || nil}
                >
                  {if row.settings.notify_on_limit, do: gettext("Yes"), else: gettext("No")}
                </td>
                <td class="text-right">
                  <.button
                    :if={row.block && row.block.liftable?}
                    type="button"
                    size="sm"
                    variant="ghost"
                    id={"agent-user-lift-#{row.user.uuid}"}
                    phx-click="lift_block"
                    phx-value-user={row.user.uuid}
                  >
                    {gettext("Lift the block")}
                  </.button>
                  <.button
                    :if={@owner? or not row.owner?}
                    type="button"
                    size="sm"
                    id={"agent-user-configure-#{row.user.uuid}"}
                    phx-click="configure"
                    phx-value-user={row.user.uuid}
                  >
                    {gettext("Configure")}
                  </.button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end
end
