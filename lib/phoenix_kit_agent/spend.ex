defmodule PhoenixKitAgent.Spend do
  @moduledoc """
  What users spent on the assistant (spec §7.3), counted from the AI request
  journal (`phoenix_kit_ai_requests`) rather than from the module's own
  messages: a row of the user (`user_uuid`) whose `metadata.source` is
  `"agent"` — every model call of the module passes both, so a call that
  describes an attachment is counted too. The journal is not pruned by age, so
  the month never loses rows. The journal keeps a cost in dollars (`cost`, a
  `numeric` that can be finer than a micro-dollar); the sums are in
  micro-dollars ($1 = 1_000_000): each window is added up in dollars and only
  then rounded, half up, to a whole micro-dollar
  (`PhoenixKitAgent.Config.cost_to_micro/1`) — two rows of $0.0000004 are
  `1`, not `0`. Only endpoints that report a cost add to it.

  Every row with a cost counts, whatever its `status`: a call that failed or
  timed out after the provider billed it is money spent all the same. Today
  `phoenix_kit_ai` writes a cost only on its `"success"` rows (a failed call is
  logged with `cost` `NULL`, which adds nothing), so the sums equal a
  success-only count. For the same reason the queries do not filter on
  `status = 'success'` and cannot use core's partial index
  `phoenix_kit_ai_requests_user_spend_idx`; they go by the journal's
  `user_uuid` index and the month's window.

  The windows are calendar days and months in the **site time zone**
  (Settings → `time_zone`; `PhoenixKit.Utils.TimeZone`), each from its local
  midnight to the next one — so a day that has 23 or 25 hours is counted right.

  Turns are counted from the module's own messages (`turns_today/2`): a turn
  is one `user` message with a `turn_ref`.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitAgent.Config
  alias PhoenixKitAgent.Schemas.{Conversation, Message}
  alias PhoenixKitAI.Request

  @typedoc "Half-open: from the first instant, up to but not including the second."
  @type window :: {DateTime.t(), DateTime.t()}

  @type spent :: %{day_micro_usd: non_neg_integer(), month_micro_usd: non_neg_integer()}

  @doc "The local day and month that contain `now`, as UTC windows."
  @spec windows(DateTime.t()) :: %{day: window(), month: window()}
  def windows(now \\ DateTime.utc_now()) do
    zone = Settings.get_setting("time_zone", "0")
    today = TimeZone.local_date(now, zone)
    first = Date.beginning_of_month(today)

    %{
      day: {TimeZone.date_start(today, zone), TimeZone.date_start(Date.add(today, 1), zone)},
      month: {
        TimeZone.date_start(first, zone),
        TimeZone.date_start(Date.add(Date.end_of_month(today), 1), zone)
      }
    }
  end

  @doc """
  The local day and month that contain `now`, as keys: `%{day: "2026-10-19",
  month: "2026-10"}`.
  """
  @spec period_keys(DateTime.t()) :: %{day: String.t(), month: String.t()}
  def period_keys(now \\ DateTime.utc_now()) do
    today = TimeZone.local_date(now, Settings.get_setting("time_zone", "0"))
    %{day: Date.to_iso8601(today), month: String.slice(Date.to_iso8601(today), 0, 7)}
  end

  @doc """
  How many turns each of `user_uuids` started today (the local day of `now`),
  in any of their chats: `%{user_uuid => count}`, every user in the answer.
  """
  @spec turns_today([String.t()], DateTime.t()) :: %{String.t() => non_neg_integer()}
  def turns_today(user_uuids, now \\ DateTime.utc_now())
  def turns_today([], _now), do: %{}

  def turns_today(user_uuids, now) when is_list(user_uuids) do
    %{day: {from, to}} = windows(now)

    counts =
      from(m in Message,
        join: c in Conversation,
        on: c.uuid == m.conversation_uuid,
        where:
          c.user_uuid in ^user_uuids and m.role == "user" and not is_nil(m.turn_ref) and
            m.inserted_at >= ^from and m.inserted_at < ^to,
        group_by: c.user_uuid,
        select: {c.user_uuid, count(m.turn_ref, :distinct)}
      )
      |> RepoHelper.repo().all()
      |> Map.new()

    Map.new(user_uuids, &{&1, Map.get(counts, &1, 0)})
  end

  @doc """
  Everyone who used the assistant this month (the local month of `now`): a
  request in the journal or a turn. User uuids; a journal row whose user was
  deleted has none and is left out, and so is a call the AI guard refused
  (`metadata.refused`): it was never made.
  """
  @spec users_this_month(DateTime.t()) :: [String.t()]
  def users_this_month(now \\ DateTime.utc_now()) do
    %{month: {from, to}} = windows(now)

    journal =
      from(r in Request,
        where:
          not is_nil(r.user_uuid) and fragment("?->>'source' = 'agent'", r.metadata) and
            fragment("coalesce(?->>'refused', 'false') <> 'true'", r.metadata) and
            r.inserted_at >= ^from and r.inserted_at < ^to,
        distinct: true,
        select: r.user_uuid
      )

    turns =
      from(m in Message,
        join: c in Conversation,
        on: c.uuid == m.conversation_uuid,
        where:
          m.role == "user" and not is_nil(m.turn_ref) and m.inserted_at >= ^from and
            m.inserted_at < ^to,
        distinct: true,
        select: c.user_uuid
      )

    (RepoHelper.repo().all(journal) ++ RepoHelper.repo().all(turns)) |> Enum.uniq()
  end

  @doc "Micro-dollars as dollars with at least two decimals: `1_500_000` is `\"1.50\"`."
  @spec format_usd(integer()) :: String.t()
  def format_usd(micro) when is_integer(micro) do
    text = micro |> Decimal.new() |> Decimal.div(1_000_000) |> Decimal.normalize()
    text = Decimal.to_string(text, :normal)

    case String.split(text, ".") do
      [whole] -> "#{whole}.00"
      [whole, <<_::binary-size(1)>> = fraction] -> "#{whole}.#{fraction}0"
      _ -> text
    end
  end

  @doc """
  What each of `user_uuids` spent today and this month (the windows of `now`):
  `%{user_uuid => %{day_micro_usd:, month_micro_usd:}}`, every user in the
  answer, zero when there is nothing.
  """
  @spec for_users([String.t()], DateTime.t()) :: %{String.t() => spent()}
  def for_users(user_uuids, now \\ DateTime.utc_now())
  def for_users([], _now), do: %{}

  def for_users(user_uuids, now) when is_list(user_uuids) do
    %{day: {day_from, day_to}, month: {month_from, month_to}} = windows(now)

    totals =
      from(r in Request,
        where:
          r.user_uuid in ^user_uuids and fragment("?->>'source' = 'agent'", r.metadata) and
            r.inserted_at >= ^month_from and r.inserted_at < ^month_to,
        group_by: r.user_uuid,
        select: {
          r.user_uuid,
          coalesce(sum(r.cost), 0),
          coalesce(
            filter(sum(r.cost), r.inserted_at >= ^day_from and r.inserted_at < ^day_to),
            0
          )
        }
      )
      |> RepoHelper.repo().all()
      |> Map.new(fn {user_uuid, month, day} ->
        {user_uuid,
         %{day_micro_usd: Config.cost_to_micro(day), month_micro_usd: Config.cost_to_micro(month)}}
      end)

    Map.new(user_uuids, fn uuid ->
      {uuid, Map.get(totals, uuid, %{day_micro_usd: 0, month_micro_usd: 0})}
    end)
  end
end
