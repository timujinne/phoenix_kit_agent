defmodule PhoenixKitAgent.UserConfig do
  @moduledoc """
  The assistant settings of one user (spec §5.4, §7) and how they combine with
  the module's.

  ## What is in effect

  `effective/1` is the one place the turn loop reads a user's settings: the
  user's own value (`PhoenixKitAgent.Schemas.UserSettings`), else the module
  default (`PhoenixKitAgent.Config`). A `nil` field means "the default"; `0` is
  a real limit. A blank prompt is no prompt. The model (`endpoint_uuid`) is read
  when a turn starts, so a change takes effect with the next turn of any chat
  (spec §14, В6).

  `enabled?/1` is the user's own switch: `false` only when an admin switched the
  assistant off for them (it never grants the `agent` permission).

  ## Who writes what

    * The user — `put_personal_instructions/3` and `get_personal_instructions/2`,
      for **their own** `personal_instructions` only. Like
      `PhoenixKitAgent.Conversations` they act for a live browser session and
      need `impersonated: boolean` in the options; an impersonated session, a
      revoked one, a user without `agent` or one switched off is refused. The
      write replaces that one column, so nothing an admin set can change
      through it.
    * An admin — `admin_update/4`, with the scope of a person who holds
      `agent.manage` (checked again here, so a caller that forgets is refused).
      It writes the switch, the model, the admin's prompt, the limits and the
      notice flags (`UserSettings.admin_changeset/2`) and records who changed
      which fields for whom in the core Activity log — field names only, never
      a prompt text. An Owner's settings are changed by an Owner only, and a
      form opened before someone else's save does not overwrite it
      (`expected:`).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Activity
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAgent.{Config, Conversations}
  alias PhoenixKitAgent.Schemas.UserSettings

  @manage "agent.manage"

  @typedoc "The settings in force for a user."
  @type effective :: %{
          user_uuid: String.t(),
          enabled?: boolean(),
          endpoint_uuid: String.t() | nil,
          system_prompt: String.t() | nil,
          personal_instructions: String.t() | nil,
          daily_cost_limit_micro_usd: non_neg_integer(),
          monthly_cost_limit_micro_usd: non_neg_integer(),
          daily_turn_limit: non_neg_integer(),
          max_attachment_mb: non_neg_integer(),
          max_attachments_per_message: non_neg_integer(),
          notify_on_limit: boolean(),
          own: [atom()]
        }

  # ── what is in effect ─────────────────────────────────────────────────

  @doc """
  The settings in force for `user_uuid`: their own value, else the module
  default (see the moduledoc). `own` lists the fields (model, prompt, limits)
  the user's row sets itself.
  """
  @spec effective(String.t()) :: effective()
  def effective(user_uuid) when is_binary(user_uuid),
    do: [user_uuid] |> effective_many() |> Map.fetch!(user_uuid)

  @doc """
  `effective/1` for several users with one query and one read of the module
  defaults: `%{user_uuid => effective}`.
  """
  @spec effective_many([String.t()]) :: %{String.t() => effective()}
  def effective_many([]), do: %{}

  def effective_many(user_uuids) when is_list(user_uuids) do
    rows =
      from(s in UserSettings, where: s.user_uuid in ^user_uuids)
      |> repo().all()
      |> Map.new(&{&1.user_uuid, &1})

    defaults = Config.limit_defaults()
    default_endpoint = Config.default_endpoint_uuid()

    Map.new(user_uuids, fn uuid ->
      row = Map.get(rows, uuid) || %UserSettings{}
      {uuid, build_effective(uuid, row, defaults, default_endpoint)}
    end)
  end

  @doc """
  The endpoints the assistant's turns use now: the module default and
  every user's own model. It backs the `endpoints` of the `agent.chat` AI
  task (`PhoenixKitAgent.ai_tasks/0`).
  """
  @spec endpoint_uuids() :: [String.t()]
  def endpoint_uuids do
    own =
      from(s in UserSettings,
        where: not is_nil(s.endpoint_uuid),
        distinct: true,
        select: s.endpoint_uuid
      )
      |> repo().all()

    Enum.uniq(List.wrap(Config.default_endpoint_uuid()) ++ own)
  end

  defp build_effective(user_uuid, row, defaults, default_endpoint) do
    limits =
      Map.new(UserSettings.limit_fields(), fn field ->
        {field, Map.get(row, field) || Map.fetch!(defaults, field)}
      end)

    own =
      [:endpoint_uuid, :system_prompt | UserSettings.limit_fields()]
      |> Enum.filter(&(Map.get(row, &1) not in [nil, ""]))

    Map.merge(limits, %{
      user_uuid: user_uuid,
      enabled?: row.enabled != false,
      endpoint_uuid: row.endpoint_uuid || default_endpoint,
      system_prompt: present(row.system_prompt),
      personal_instructions: present(row.personal_instructions),
      notify_on_limit: row.notify_on_limit == true,
      own: own
    })
  end

  @doc """
  The people the assistant is for: active users who hold `agent` through a role
  (and the Owners, who hold every permission), by e-mail. The admin screen lists
  these.
  """
  @spec agent_users() :: [User.t()]
  def agent_users do
    owners = "Owner" |> Roles.users_with_role() |> Enum.map(& &1.uuid)
    uuids = Enum.uniq(Permissions.users_with_permission("agent") ++ owners)

    from(u in User,
      where: u.uuid in ^uuids and u.is_active == true,
      order_by: [asc: u.email, asc: u.uuid]
    )
    |> repo().all()
  end

  @doc """
  The people who may be chosen to be told when someone reaches a limit
  (`agent_limit_watchers`, spec §7.4): active users who hold `agent.manage`
  through a role, the Owners, and whoever is a watcher now, by e-mail.
  """
  @spec watcher_candidates() :: [User.t()]
  def watcher_candidates do
    owners = "Owner" |> Roles.users_with_role() |> Enum.map(& &1.uuid)
    managers = Enum.uniq(Permissions.users_with_permission(@manage) ++ owners)
    watchers = Config.limit_watchers()

    from(u in User,
      where: (u.uuid in ^managers and u.is_active == true) or u.uuid in ^watchers,
      order_by: [asc: u.email, asc: u.uuid]
    )
    |> repo().all()
  end

  @doc "Whether `user_uuid` is one of `agent_users/0`."
  @spec agent_user?(term()) :: boolean()
  def agent_user?(user_uuid) do
    case Ecto.UUID.cast(user_uuid) do
      {:ok, uuid} -> Enum.any?(agent_users(), &(&1.uuid == uuid))
      :error -> false
    end
  end

  @doc "Whether the assistant is not switched off for the user (see the moduledoc)."
  @spec enabled?(String.t()) :: boolean()
  def enabled?(user_uuid) when is_binary(user_uuid) do
    not repo().exists?(
      from(s in UserSettings, where: s.user_uuid == ^user_uuid and s.enabled == false)
    )
  end

  @doc """
  The user's settings row as it is stored, for the admin's form: an unsaved
  `%UserSettings{}` when they have none. `nil` for a malformed uuid.
  """
  @spec get(term()) :: UserSettings.t() | nil
  def get(user_uuid) do
    case Ecto.UUID.cast(user_uuid) do
      {:ok, uuid} -> repo().get(UserSettings, uuid) || %UserSettings{user_uuid: uuid}
      :error -> nil
    end
  end

  # ── the user's own: personal instructions ─────────────────────────────

  @doc """
  The session user's own personal instructions (`nil` when none). Refusals are
  those of `PhoenixKitAgent.Conversations`.
  """
  @spec get_personal_instructions(Conversations.session_ref(), keyword()) ::
          {:ok, String.t() | nil} | {:error, Conversations.refusal()}
  def get_personal_instructions(session_ref, opts) do
    with {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts) do
      {:ok, effective(user_uuid).personal_instructions}
    end
  end

  @doc """
  Sets the session user's own personal instructions (a blank text clears them).
  They are the user's, ranked below the module's and the admin's prompt (spec
  §7.1). Only this one column is written, whatever else the row holds; a text
  over 4000 characters, or one that is not text, is `{:error, changeset}` and
  nothing is written.
  """
  @spec put_personal_instructions(Conversations.session_ref(), term(), keyword()) ::
          {:ok, String.t() | nil} | {:error, Conversations.refusal() | Ecto.Changeset.t()}
  def put_personal_instructions(session_ref, text, opts) do
    with {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts) do
      changeset =
        UserSettings.personal_changeset(%UserSettings{user_uuid: user_uuid}, %{
          personal_instructions: text
        })

      if changeset.valid? do
        stored = Ecto.Changeset.get_field(changeset, :personal_instructions)
        write_personal(user_uuid, stored)
      else
        {:error, %{changeset | action: :update}}
      end
    end
  end

  # An upsert of the one column (and `updated_at`): a row an admin filled in,
  # or one holding a live turn's lock, keeps everything else. `log: false`:
  # Ecto would print the bound values, the user's text among them.
  defp write_personal(user_uuid, text) do
    now = DateTime.utc_now()

    repo().insert!(
      %UserSettings{user_uuid: user_uuid, personal_instructions: text},
      on_conflict: [set: [personal_instructions: text, updated_at: now]],
      conflict_target: :user_uuid,
      log: false
    )

    {:ok, text}
  end

  # ── the admin's ───────────────────────────────────────────────────────

  @doc """
  Saves what an admin sets for `target_user_uuid` (`attrs` as
  `UserSettings.admin_changeset/2` casts them) on behalf of `actor_scope`,
  which must hold `agent.manage` — and be an Owner when the target is one: an
  Owner's assistant is not set by the people an Owner manages. The row is
  created if the user has none, and locked while it is changed.

  `expected: %{field => value}` in `opts` is what the caller's form showed
  when it was opened: when the stored row no longer holds those values (an
  admin saved in between), nothing is written and the answer is `{:error,
  :stale}`, so a stale form never overwrites that change unseen. Fields not
  named there do not count.

  Returns `{:ok, settings, changed_fields}`; when fields changed, the actor,
  the user (as the resource of the entry) and the field names go to the core
  Activity log (action `agent.user_settings_updated`) — no values, and no
  notification for the user. `{:error, :forbidden}` without the permission
  (or for an Owner's settings, to a non-Owner), `{:error, :not_found}` for an
  unknown user, `{:error, changeset}` for an invalid value (nothing is
  written). A newly chosen model must fit the `agent.chat` AI task
  (`PhoenixKitAI.Tasks.check_selection/2`): one known not to take tools is
  `{:error, {:model_unfit, missing}}`, one nobody knows takes them `{:error,
  {:model_unverified, unclear}}`, and nothing is written; none (the module
  default) and the model already saved are not checked.
  """
  @spec admin_update(Scope.t() | nil, term(), map(), keyword()) ::
          {:ok, UserSettings.t(), [atom()]}
          | {:error,
             :forbidden
             | :not_found
             | :stale
             | {:model_unfit | :model_unverified, [atom()]}
             | Ecto.Changeset.t()}
  def admin_update(actor_scope, target_user_uuid, attrs, opts \\ []) when is_map(attrs) do
    with :ok <- authorize_manage(actor_scope),
         {:ok, target} <- existing_user(target_user_uuid),
         :ok <- authorize_target(actor_scope, target) do
      actor_uuid = Scope.user_uuid(actor_scope)

      case save_admin(target.uuid, actor_uuid, attrs, Keyword.get(opts, :expected)) do
        {:ok, row, fields} ->
          log_change(actor_uuid, target.uuid, fields)
          {:ok, row, fields}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Whether `actor_scope` may set the assistant of `target_user_uuid` with
  `admin_update/4`: it holds `agent.manage`, and is an Owner if the target is.
  """
  @spec may_configure?(Scope.t() | nil, term()) :: boolean()
  def may_configure?(actor_scope, target_user_uuid) do
    with :ok <- authorize_manage(actor_scope),
         {:ok, target} <- existing_user(target_user_uuid) do
      authorize_target(actor_scope, target) == :ok
    else
      _refused -> false
    end
  end

  defp authorize_manage(%Scope{} = scope) do
    if Scope.can?(scope, @manage), do: :ok, else: {:error, :forbidden}
  end

  defp authorize_manage(_none), do: {:error, :forbidden}

  defp authorize_target(actor_scope, target) do
    if Roles.user_has_role_owner?(target) and not Scope.owner?(actor_scope),
      do: {:error, :forbidden},
      else: :ok
  end

  defp existing_user(user_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(user_uuid),
         %User{} = user <- repo().get(User, uuid) do
      {:ok, user}
    else
      _unknown -> {:error, :not_found}
    end
  end

  defp save_admin(target, actor_uuid, attrs, expected) do
    result =
      repo().transaction(fn ->
        repo().insert!(%UserSettings{user_uuid: target},
          on_conflict: :nothing,
          conflict_target: :user_uuid
        )

        row =
          repo().one!(from(s in UserSettings, where: s.user_uuid == ^target, lock: "FOR UPDATE"))

        unless unchanged?(row, expected), do: repo().rollback(:stale)

        changeset = UserSettings.admin_changeset(row, attrs)
        fields = changeset.changes |> Map.keys() |> Enum.sort()

        with {:error, refusal} <- check_model(changeset), do: repo().rollback(refusal)

        changeset =
          if fields == [],
            do: changeset,
            else: Ecto.Changeset.put_change(changeset, :updated_by_uuid, actor_uuid)

        # `log: false`: the bound values hold the admin's prompt.
        case repo().update(changeset, log: false) do
          {:ok, saved} -> {saved, fields}
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, {row, fields}} -> {:ok, row, fields}
      {:error, %Ecto.Changeset{}} = error -> error
      {:error, :stale} = error -> error
      {:error, {:model_unfit, _missing}} = error -> error
      {:error, {:model_unverified, _unclear}} = error -> error
    end
  end

  # A newly chosen model must fit the `agent.chat` AI task. None (the module
  # default) and the model already saved are not checked; an endpoint that
  # does not exist is the changeset's foreign key error.
  defp check_model(changeset) do
    with uuid when is_binary(uuid) <- Ecto.Changeset.get_change(changeset, :endpoint_uuid),
         {:error, {reason, _needs}} = refusal when reason in [:model_unfit, :model_unverified] <-
           PhoenixKitAI.Tasks.check_selection("agent.chat", uuid) do
      refusal
    else
      _fit_none_or_kept -> :ok
    end
  end

  defp unchanged?(_row, nil), do: true

  defp unchanged?(row, expected) when is_map(expected),
    do: Enum.all?(expected, fn {field, value} -> Map.get(row, field) == value end)

  defp log_change(_actor_uuid, _target, []), do: :ok

  defp log_change(actor_uuid, target, fields) do
    # No `target_uuid`: core would turn the entry into a notification for the
    # user, who did not ask for one and could not switch it off.
    Activity.log("agent", "agent.user_settings_updated",
      actor_uuid: actor_uuid,
      resource_type: "agent_user_settings",
      resource_uuid: target,
      metadata: %{"fields" => Enum.map(fields, &Atom.to_string/1)}
    )

    :ok
  end

  defp present(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp present(_none), do: nil

  defp repo, do: RepoHelper.repo()
end
