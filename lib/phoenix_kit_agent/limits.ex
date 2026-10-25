defmodule PhoenixKitAgent.Limits do
  @moduledoc """
  The spending and turn limits of a user (spec §7.3) and who is told when one
  is near or reached (spec §7.4).

  ## What is counted

    * Money — `PhoenixKitAgent.Spend`: the user's rows of the AI request
      journal whose `metadata.source` is `"agent"`, so a call that describes
      an attachment counts as well as a model call of a turn; every row with
      a cost, a failed call's included. Micro-dollars, `$1 = 1_000_000`.
    * Turns — the user's `user` messages with a `turn_ref` (one per turn), in
      any of their chats.

  The windows are the calendar day and month of the site time zone. The
  limits in force are `PhoenixKitAgent.UserConfig.effective/1`'s: the
  user's own, else the module's. A limit of `0` allows nothing.

  The money limits apply only on an endpoint whose calls get what they cost
  in the journal (`PhoenixKitAgent.Models.reports_cost?/2`: a model call of a
  turn, or a picture's description on the vision endpoint, where the provider
  reports a cost or `phoenix_kit_ai` has a price for the model): on another,
  nothing would be counted, so only the turn limit applies there — the admin
  pages say so for the default model. An endpoint that cannot be found keeps
  the money limits.

  ## When

  `check/3` runs before a turn, while the turn holds its locks
  (`PhoenixKitAgent.Turns`), so the previous turn of the user — and every
  journal row it wrote — is over by then. A turn that started under its
  limits runs to its end, even past them.

  ## Notices

  Each is sent once per limit and period: a row of
  `phoenix_kit_agent_limit_events` (`user, kind, period`, unique) is inserted
  first with `ON CONFLICT DO NOTHING`, and only an insert that went through
  sends anything.

    * 80 % of a limit (`check/3`) — an in-app notice to the user
      (`PhoenixKit.Notifications.upsert_inapp/3`, key
      `agent:limit:<kind>:<period>`). Event kind `warn_80`, period key
      `cost:<period>` or `turns:<period>`, so each of the three limits warns
      on its own.
    * A limit reached (`announce_reached/2`) — the in-app notice to the user
      (the same key, so an unread warning becomes the new text), and, only
      when the user's `notify_on_limit` is on, a notification of type
      `"agent_limit"` to the watchers (`create_many/2`, which respects a
      watcher who switched that type off). The two have their own events —
      the watchers' period key is `w:<period>`, written only when they are
      told — so `notify_on_limit` switched on later in the period still
      tells the watchers of that period, once.

  A call refused by the `phoenix_kit_ai` budget is signalled by
  `phoenix_kit_ai` itself (its `limit_reached` event, to its watchers and
  to those of the task, `guard_watchers/1`); the turn's notice in the chat
  says the budget is used up.

  The watchers are `agent_limit_watchers` (empty: every Owner) and the user's
  own `notify_user_uuids`, without the user, who is told as the user.

  Notices name the user by e-mail and the limit with its numbers; nothing of a
  chat. A notice that cannot be sent is logged as the class of the failure.
  """

  use Gettext, backend: PhoenixKitAgent.Gettext

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Notifications
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.{RecipientLocale, Routes}
  alias PhoenixKitAgent.{Config, Models, Spend, UserConfig}
  alias PhoenixKitAgent.Schemas.{LimitEvent, UserSettings}

  @typedoc "A limit of a user."
  @type kind :: :daily_cost | :monthly_cost | :daily_turns

  @typedoc "A limit as it stands: what was used of it in its period."
  @type status :: %{
          kind: kind(),
          used: non_neg_integer(),
          limit: non_neg_integer(),
          period_key: String.t()
        }

  @typedoc "What a user used today and this month, and the keys of those periods."
  @type usage :: %{
          day_micro_usd: non_neg_integer(),
          month_micro_usd: non_neg_integer(),
          day_turns: non_neg_integer(),
          day_key: String.t(),
          month_key: String.t()
        }

  @notice_type "agent_limit"
  @icon "hero-sparkles"

  @doc "What `user_uuid` used in the day and month of `now` (see the moduledoc)."
  @spec usage(String.t(), DateTime.t()) :: usage()
  def usage(user_uuid, now \\ DateTime.utc_now()) when is_binary(user_uuid) do
    %{day_micro_usd: day, month_micro_usd: month} = Spend.for_users([user_uuid], now)[user_uuid]
    keys = Spend.period_keys(now)

    %{
      day_micro_usd: day,
      month_micro_usd: month,
      day_turns: Spend.turns_today([user_uuid], now)[user_uuid],
      day_key: keys.day,
      month_key: keys.month
    }
  end

  @doc """
  Whether the user of `settings` (`UserConfig.effective/1`) may start a turn
  on `endpoint_uuid` now: `:ok`, or `{:error, {:limit_reached, status}}` for
  the first limit used up — the month's money, the day's money, the day's
  turns. On `:ok`, a limit at 80 % or more is announced to the user (once per
  period). Sends nothing about a limit reached: that is
  `announce_reached/2`.

  Options: `:use` — what the call on the endpoint is (`:chat`, the default,
  or `:vision`, see `money_counted?/2`); `:now`.
  """
  @spec check(UserConfig.effective(), String.t() | nil, keyword()) ::
          :ok | {:error, {:limit_reached, status()}}
  def check(settings, endpoint_uuid, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    money? = money_counted?(endpoint_uuid, Keyword.get(opts, :use, :chat))
    statuses = statuses(settings, usage(settings.user_uuid, now), money?)

    case Enum.find(statuses, &(&1.used >= &1.limit)) do
      nil ->
        statuses
        |> Enum.filter(&near?/1)
        |> Enum.each(&warn(settings.user_uuid, &1))

      reached ->
        {:error, {:limit_reached, reached}}
    end
  end

  @doc """
  Tells that the user of `settings` reached a limit (`status` from
  `check/3`): once per limit and period — the user in the app, and the
  watchers when the user's `notify_on_limit` is on.
  """
  @spec announce_reached(UserConfig.effective(), status()) :: :ok
  def announce_reached(settings, %{kind: kind, period_key: period} = status) do
    user_uuid = settings.user_uuid

    safely(fn ->
      if first?(user_uuid, Atom.to_string(kind), period, status.used, status.limit) do
        Notifications.upsert_inapp(user_uuid, key(kind, period), %{
          text: reached_text(status),
          icon: @icon
        })
      end
    end)

    # The watchers' own event, written only when they are told: switched on
    # later in the period, `notify_on_limit` still reaches them.
    if settings.notify_on_limit do
      safely(fn ->
        if first?(user_uuid, Atom.to_string(kind), "w:" <> period, status.used, status.limit),
          do: tell_watchers(user_uuid, &watcher_text(&1, status))
      end)
    end

    :ok
  end

  @doc """
  Who is told about the user's limits: `agent_limit_watchers` (empty: every
  Owner) and the user's own `notify_user_uuids`, without the user.
  """
  @spec watchers(String.t()) :: [String.t()]
  def watchers(user_uuid) do
    configured =
      case Config.limit_watchers() do
        [] -> "Owner" |> Roles.users_with_role() |> Enum.map(& &1.uuid)
        uuids -> uuids
      end

    own =
      from(s in UserSettings, where: s.user_uuid == ^user_uuid, select: s.notify_user_uuids)
      |> repo().one()
      |> List.wrap()

    (configured ++ own) |> Enum.uniq() |> List.delete(user_uuid)
  end

  @doc """
  The watchers the module adds to the AI guard's own for its tasks
  (`watchers` of `PhoenixKitAgent.ai_tasks/0`, called with the user's uuid
  or nil): `agent_limit_watchers`, plus the user's `notify_user_uuids` when
  their `notify_on_limit` is on, without the user. An empty
  `agent_limit_watchers` adds nobody: the guard tells its own watchers
  (every Owner by default) anyway.
  """
  @spec guard_watchers(String.t() | nil) :: [String.t()]
  def guard_watchers(user_uuid) when is_binary(user_uuid) do
    own =
      from(s in UserSettings,
        where: s.user_uuid == ^user_uuid and s.notify_on_limit == true,
        select: s.notify_user_uuids
      )
      |> repo().one()
      |> List.wrap()

    (Config.limit_watchers() ++ own) |> Enum.uniq() |> List.delete(user_uuid)
  end

  def guard_watchers(_no_user), do: Config.limit_watchers()

  @doc """
  Whether money counts for a `call` (`:chat` or `:vision`) on
  `endpoint_uuid` (see the moduledoc): an endpoint whose such calls get a
  cost (`PhoenixKitAgent.Models.reports_cost?/2`), or one that cannot be
  found.
  """
  @spec money_counted?(String.t() | nil, Models.call_kind()) :: boolean()
  def money_counted?(endpoint_uuid, call \\ :chat)

  def money_counted?(endpoint_uuid, call) when is_binary(endpoint_uuid) do
    case PhoenixKitAI.get_endpoint(endpoint_uuid) do
      nil -> true
      endpoint -> Models.reports_cost?(endpoint, call)
    end
  end

  def money_counted?(_none, _call), do: true

  # ── internals ─────────────────────────────────────────────────────────

  defp statuses(settings, usage, money?) do
    money =
      if money? do
        [
          %{
            kind: :monthly_cost,
            used: usage.month_micro_usd,
            limit: settings.monthly_cost_limit_micro_usd,
            period_key: usage.month_key
          },
          %{
            kind: :daily_cost,
            used: usage.day_micro_usd,
            limit: settings.daily_cost_limit_micro_usd,
            period_key: usage.day_key
          }
        ]
      else
        []
      end

    money ++
      [
        %{
          kind: :daily_turns,
          used: usage.day_turns,
          limit: settings.daily_turn_limit,
          period_key: usage.day_key
        }
      ]
  end

  defp near?(%{used: used, limit: limit}), do: limit > 0 and used * 5 >= limit * 4

  defp warn(user_uuid, %{kind: kind, period_key: period} = status) do
    safely(fn ->
      if first?(user_uuid, "warn_80", warn_period(kind, period), status.used, status.limit) do
        Notifications.upsert_inapp(user_uuid, key(kind, period), %{
          text: warn_text(status),
          icon: @icon
        })
      end
    end)
  end

  defp warn_period(:daily_turns, period), do: "turns:" <> period
  defp warn_period(_money, period), do: "cost:" <> period

  defp key(kind, period), do: "agent:limit:#{kind}:#{period}"

  # The one row of this notice; `true` only for the call that inserted it.
  defp first?(user_uuid, kind, period, used, limit) do
    now = DateTime.utc_now()

    {count, _} =
      repo().insert_all(
        LimitEvent,
        [
          %{
            user_uuid: user_uuid,
            limit_kind: kind,
            period_key: period,
            used: used,
            limit: limit,
            notified_at: now,
            inserted_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:user_uuid, :limit_kind, :period_key]
      )

    count == 1
  end

  defp tell_watchers(user_uuid, text_fun) do
    case watchers(user_uuid) do
      [] ->
        :ok

      watchers ->
        email = user_email(user_uuid)

        Notifications.create_many(watchers, %{
          type: @notice_type,
          text: text_fun.(email),
          icon: @icon,
          link: Routes.path("/admin/agent/spending")
        })
    end
  end

  defp user_email(user_uuid) do
    case Auth.get_user(user_uuid) do
      %{email: email} -> email
      nil -> gettext("A user")
    end
  end

  # ── texts ─────────────────────────────────────────────────────────────

  defp warn_text(%{kind: :daily_turns, used: used, limit: limit}),
    do:
      gettext("You have used %{used} of your %{limit} AI assistant turns for today.",
        used: used,
        limit: limit
      )

  defp warn_text(%{kind: :daily_cost, used: used, limit: limit}),
    do:
      gettext(
        "You have used 80% of your daily spending limit for the AI assistant ($%{used} of $%{limit}).",
        used: Spend.format_usd(used),
        limit: Spend.format_usd(limit)
      )

  defp warn_text(%{kind: :monthly_cost, used: used, limit: limit}),
    do:
      gettext(
        "You have used 80% of your monthly spending limit for the AI assistant ($%{used} of $%{limit}).",
        used: Spend.format_usd(used),
        limit: Spend.format_usd(limit)
      )

  defp reached_text(%{kind: :daily_turns, limit: limit}),
    do: gettext("You have used all your %{limit} AI assistant turns for today.", limit: limit)

  defp reached_text(%{kind: :daily_cost, limit: limit}),
    do:
      gettext("You have reached your daily spending limit for the AI assistant ($%{limit}).",
        limit: Spend.format_usd(limit)
      )

  defp reached_text(%{kind: :monthly_cost, limit: limit}),
    do:
      gettext("You have reached your monthly spending limit for the AI assistant ($%{limit}).",
        limit: Spend.format_usd(limit)
      )

  # The watchers are other people than the one whose process this is, and one
  # text goes to all of them: it is written in the site's content language
  # (`Settings.get_content_language/0`, the primary one), else the default locale.
  defp for_watchers(fun) do
    language = Settings.get_content_language() || PhoenixKit.Config.default_locale()

    RecipientLocale.in_locale(language, fn ->
      Gettext.with_locale(
        PhoenixKitAgent.Gettext,
        Gettext.get_locale(PhoenixKitWeb.Gettext),
        fun
      )
    end)
  end

  defp watcher_text(email, %{kind: :daily_turns, limit: limit}),
    do:
      for_watchers(fn ->
        gettext("%{email} has used all %{limit} AI assistant turns for today.",
          email: email,
          limit: limit
        )
      end)

  defp watcher_text(email, %{kind: :daily_cost, limit: limit}),
    do:
      for_watchers(fn ->
        gettext("%{email} has reached the daily AI assistant spending limit ($%{limit}).",
          email: email,
          limit: Spend.format_usd(limit)
        )
      end)

  defp watcher_text(email, %{kind: :monthly_cost, limit: limit}),
    do:
      for_watchers(fn ->
        gettext("%{email} has reached the monthly AI assistant spending limit ($%{limit}).",
          email: email,
          limit: Spend.format_usd(limit)
        )
      end)

  # A notice is never worth a turn: a failure is logged as its class only.
  defp safely(fun) do
    _ = fun.()
    :ok
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAgent] a limit notice was not sent: #{inspect(error.__struct__)}"
      )

      :ok
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAgent] a limit notice was not sent: #{kind}")
      :ok
  end

  defp repo, do: RepoHelper.repo()
end
