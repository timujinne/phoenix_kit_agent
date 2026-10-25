defmodule PhoenixKitAgent.LimitsTest do
  @moduledoc """
  The spending and turn limits of a user and the notices about them (spec
  §5.5, §7.3, §7.4): money from the AI request journal (vision calls
  included), turns from the module's own user messages, in the calendar day
  and month of the site time zone; one notice per limit and period.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Notifications.{Notification, Prefs}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitAgent.{Config, Limits, UserConfig}
  alias PhoenixKitAgent.Schemas.{LimitEvent, Message, UserSettings}

  setup do
    {:ok, _} = Settings.update_setting("time_zone", "Europe/Tallinn")
    owner = owner_fixture()
    user = user_with(["agent"], "limited")
    %{owner: owner, user: user, endpoint: endpoint_fixture()}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp spend!(user, endpoint, cost, opts \\ []) do
    Repo.insert!(%PhoenixKitAI.Request{
      endpoint_uuid: endpoint.uuid,
      user_uuid: user.uuid,
      model: endpoint.model,
      status: "success",
      request_type: Keyword.get(opts, :type, "chat"),
      cost: journal_cost(cost),
      metadata: Keyword.get(opts, :metadata, %{"source" => "agent"}),
      inserted_at: Keyword.get(opts, :at, DateTime.truncate(DateTime.utc_now(), :second))
    })
  end

  # `n` turns of the user: a user message each, with its own turn ref.
  defp turns!(user, n, at \\ DateTime.utc_now()) do
    chat = conversation_fixture(user)
    {micro, _precision} = at.microsecond
    at = %{at | microsecond: {micro, 6}}

    for _ <- 1..n//1 do
      Repo.insert!(%Message{
        conversation_uuid: chat.uuid,
        turn_ref: UUIDv7.generate(),
        role: "user",
        content: "Hi",
        inserted_at: at
      })
    end

    chat
  end

  defp limits!(user, attrs) do
    Repo.insert!(
      struct(UserSettings, Map.merge(%{user_uuid: user.uuid}, Map.new(attrs))),
      on_conflict: {:replace_all_except, [:user_uuid, :inserted_at]},
      conflict_target: :user_uuid
    )

    UserConfig.effective(user.uuid)
  end

  defp notifications(user) do
    Repo.all(
      from(n in Notification,
        where: n.recipient_uuid == ^user.uuid,
        order_by: [asc: n.inserted_at, asc: n.uuid]
      )
    )
  end

  defp events(user) do
    Repo.all(from(e in LimitEvent, where: e.user_uuid == ^user.uuid, order_by: e.limit_kind))
  end

  defp today_key, do: Limits.usage(UUIDv7.generate()).day_key

  # ── usage ───────────────────────────────────────────────────────────

  describe "usage/2" do
    test "money from the journal, a vision call that no message records included", ctx do
      spend!(ctx.user, ctx.endpoint, 120_000,
        metadata: %{"source" => "agent", "attribution" => %{"agent_message_uuid" => "x"}}
      )

      # A description of an attachment: source "agent", no message of the module.
      spend!(ctx.user, ctx.endpoint, 30_000, type: "vision")
      spend!(ctx.user, ctx.endpoint, 5_000, metadata: %{"source" => "playground"})
      spend!(user_fixture("other"), ctx.endpoint, 7_000)

      assert %{day_micro_usd: 150_000, month_micro_usd: 150_000} =
               Limits.usage(ctx.user.uuid)
    end

    test "turns are the user messages of the day that carry a turn ref", ctx do
      chat = turns!(ctx.user, 3)

      # A notice of a refused start and a message written without a turn are no turns.
      Repo.insert!(%Message{
        conversation_uuid: chat.uuid,
        turn_ref: UUIDv7.generate(),
        role: "notice",
        content: "Limit"
      })

      Repo.insert!(%Message{conversation_uuid: chat.uuid, role: "user", content: "No turn"})
      turns!(user_fixture("other"), 2)

      assert %{day_turns: 3} = Limits.usage(ctx.user.uuid)
    end

    test "the day and the month turn over at local midnight of the site time zone", ctx do
      # 00:30 on 1 August in Tallinn (UTC+3).
      now = ~U[2026-07-31 21:30:00Z]

      turns!(ctx.user, 2, ~U[2026-07-31 20:59:00Z])
      turns!(ctx.user, 1, ~U[2026-07-31 21:05:00Z])
      spend!(ctx.user, ctx.endpoint, 5, at: ~U[2026-07-31 20:59:00Z])
      spend!(ctx.user, ctx.endpoint, 7, at: ~U[2026-07-31 21:05:00Z])

      assert Limits.usage(ctx.user.uuid, now) == %{
               day_micro_usd: 7,
               month_micro_usd: 7,
               day_turns: 1,
               day_key: "2026-08-01",
               month_key: "2026-08"
             }
    end
  end

  # ── check ───────────────────────────────────────────────────────────

  describe "check/3" do
    test "under every limit: :ok, nothing recorded or sent", ctx do
      settings = limits!(ctx.user, daily_cost_limit_micro_usd: 1_000_000)
      spend!(ctx.user, ctx.endpoint, 100_000)

      assert :ok = Limits.check(settings, ctx.endpoint.uuid)
      assert events(ctx.user) == []
      assert notifications(ctx.user) == []
    end

    test "the daily money limit, counted from the journal", ctx do
      settings = limits!(ctx.user, daily_cost_limit_micro_usd: 150_000)
      spend!(ctx.user, ctx.endpoint, 100_000)
      spend!(ctx.user, ctx.endpoint, 50_000, type: "vision")

      assert {:error, {:limit_reached, reached}} = Limits.check(settings, ctx.endpoint.uuid)
      assert %{kind: :daily_cost, used: 150_000, limit: 150_000} = reached
      assert reached.period_key == today_key()
    end

    test "a vision call alone reaches the limit", ctx do
      settings = limits!(ctx.user, daily_cost_limit_micro_usd: 10_000)
      spend!(ctx.user, ctx.endpoint, 10_000, type: "vision")

      assert {:error, {:limit_reached, %{kind: :daily_cost}}} =
               Limits.check(settings, ctx.endpoint.uuid)
    end

    test "the month is named first when both money limits are used up", ctx do
      settings =
        limits!(ctx.user, daily_cost_limit_micro_usd: 10, monthly_cost_limit_micro_usd: 10)

      spend!(ctx.user, ctx.endpoint, 10)

      assert {:error, {:limit_reached, %{kind: :monthly_cost, period_key: month}}} =
               Limits.check(settings, ctx.endpoint.uuid)

      assert month == Limits.usage(ctx.user.uuid).month_key
    end

    test "the daily turn limit", ctx do
      settings = limits!(ctx.user, daily_turn_limit: 2)
      turns!(ctx.user, 1)
      assert :ok = Limits.check(settings, ctx.endpoint.uuid)

      turns!(ctx.user, 1)

      assert {:error, {:limit_reached, %{kind: :daily_turns, used: 2, limit: 2}}} =
               Limits.check(settings, ctx.endpoint.uuid)
    end

    test "yesterday's turns and spending (local time) do not count", ctx do
      settings = limits!(ctx.user, daily_turn_limit: 1, daily_cost_limit_micro_usd: 10)
      {day_start, _} = PhoenixKitAgent.Spend.windows().day
      before = DateTime.add(day_start, -60, :second)

      turns!(ctx.user, 1, before)
      spend!(ctx.user, ctx.endpoint, 10, at: before)

      # The month may have begun today; the daily limits are what is checked.
      settings = %{settings | monthly_cost_limit_micro_usd: 1_000_000_000}
      assert :ok = Limits.check(settings, ctx.endpoint.uuid)
    end

    test "a limit of 0 allows nothing", ctx do
      settings = limits!(ctx.user, daily_turn_limit: 0)

      assert {:error, {:limit_reached, %{kind: :daily_turns, used: 0, limit: 0}}} =
               Limits.check(settings, ctx.endpoint.uuid)
    end

    test "an endpoint that reports no cost: the money limits do not apply, the turn limit does",
         ctx do
      direct = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})

      settings =
        limits!(ctx.user,
          daily_cost_limit_micro_usd: 0,
          monthly_cost_limit_micro_usd: 0,
          daily_turn_limit: 1
        )

      spend!(ctx.user, direct, 5_000)
      assert :ok = Limits.check(settings, direct.uuid)
      assert notifications(ctx.user) == []

      turns!(ctx.user, 1)

      assert {:error, {:limit_reached, %{kind: :daily_turns}}} =
               Limits.check(settings, direct.uuid)

      # The same user on an endpoint that reports a cost.
      assert {:error, {:limit_reached, %{kind: :monthly_cost}}} =
               Limits.check(settings, ctx.endpoint.uuid)
    end

    test "a priced Anthropic call counts: the daily money limit refuses after it", ctx do
      claude = endpoint_fixture(%{provider: "anthropic", model: "claude-sonnet-5-5"})
      settings = limits!(ctx.user, daily_cost_limit_micro_usd: 14_000)
      assert :ok = Limits.check(settings, claude.uuid)

      # The row phoenix_kit_ai writes for the call: Anthropic reports no cost,
      # its list price gives one ($2 / $10 per 1M tokens).
      assert {cost, %{cost_source: "table"} = source} =
               PhoenixKitAI.CallCost.for_call(claude, "claude-sonnet-5-5", nil, 2_000, 1_000)

      assert Decimal.equal?(cost, "0.014")

      spend!(ctx.user, claude, 14_000,
        metadata: %{"source" => "agent", "cost_source" => source.cost_source}
      )

      assert {:error, {:limit_reached, %{kind: :daily_cost, used: 14_000}}} =
               Limits.check(settings, claude.uuid)
    end

    test "an Anthropic answer without a cost: phoenix_kit_ai logs its list price, the limit counts it",
         ctx do
      {:ok, _} = PhoenixKitAI.enable_system()
      stub = :anthropic_cost_stub
      Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

      Req.Test.expect(stub, fn conn ->
        Req.Test.json(conn, %{
          "model" => "claude-sonnet-5-5",
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hi"}}],
          "usage" => %{"prompt_tokens" => 2_000, "completion_tokens" => 1_000}
        })
      end)

      claude = endpoint_fixture(%{provider: "anthropic", model: "claude-sonnet-5-5"})
      settings = limits!(ctx.user, daily_cost_limit_micro_usd: 14_000)

      assert {:ok, _} =
               PhoenixKitAI.complete(claude.uuid, [%{role: "user", content: "Hi"}],
                 source: "agent",
                 user_uuid: ctx.user.uuid,
                 cache: false
               )

      assert [%{cost: cost, metadata: %{"cost_source" => "table"}}] =
               Repo.all(from(r in PhoenixKitAI.Request, where: r.user_uuid == ^ctx.user.uuid))

      assert Decimal.equal?(cost, "0.014")

      assert %{day_micro_usd: 14_000} = Limits.usage(ctx.user.uuid)

      assert {:error, {:limit_reached, %{kind: :daily_cost}}} =
               Limits.check(settings, claude.uuid)
    end

    test "a manual price counts like a reported cost", ctx do
      priced =
        endpoint_fixture(
          %{
            provider: "deepseek",
            model: "deepseek-chat",
            provider_settings: %{"pricing" => %{"input" => "0.27", "output" => "1.1"}}
          },
          scope: scope_of(ctx.owner)
        )

      settings = limits!(ctx.user, daily_cost_limit_micro_usd: 1_000)
      spend!(ctx.user, priced, 1_000, metadata: %{"source" => "agent", "cost_source" => "manual"})

      assert {:error, {:limit_reached, %{kind: :daily_cost}}} =
               Limits.check(settings, priced.uuid)
    end

    test "an Anthropic model without a price: the money limits do not apply", ctx do
      unpriced = endpoint_fixture(%{provider: "anthropic", model: "claude-unknown-9"})
      settings = limits!(ctx.user, daily_cost_limit_micro_usd: 0, monthly_cost_limit_micro_usd: 0)

      assert :ok = Limits.check(settings, unpriced.uuid)
      refute Limits.money_counted?(unpriced.uuid)
    end

    test "a picture's description: the money limits apply where phoenix_kit_ai prices it",
         ctx do
      claude = endpoint_fixture(%{provider: "anthropic", model: "claude-sonnet-5-5"})
      unpriced = endpoint_fixture(%{provider: "anthropic", model: "claude-unknown-9"})
      settings = limits!(ctx.user, daily_cost_limit_micro_usd: 10)
      spend!(ctx.user, ctx.endpoint, 10)

      # phoenix_kit_ai prices a description like a chat call: on Anthropic by
      # the list price, so the money limits hold it there too.
      assert {:error, {:limit_reached, %{kind: :daily_cost}}} =
               Limits.check(settings, claude.uuid, use: :vision)

      assert Limits.money_counted?(claude.uuid, :vision)

      assert {:error, {:limit_reached, %{kind: :daily_cost}}} =
               Limits.check(settings, ctx.endpoint.uuid, use: :vision)

      # A model nothing prices counts no money: only the turn limit holds it.
      assert :ok = Limits.check(settings, unpriced.uuid, use: :vision)
      refute Limits.money_counted?(unpriced.uuid, :vision)
    end

    test "80 % of a limit: one in-app notice to the user, once per period", ctx do
      settings = limits!(ctx.user, daily_cost_limit_micro_usd: 1_000_000)
      spend!(ctx.user, ctx.endpoint, 800_000)

      assert :ok = Limits.check(settings, ctx.endpoint.uuid)
      assert [notice] = notifications(ctx.user)
      assert notice.metadata["dedupe_key"] == "agent:limit:daily_cost:#{today_key()}"
      assert notice.metadata["notification_text"] =~ "80%"

      # Seen: a new upsert would be a new row; the period's event keeps it at one.
      Repo.update_all(from(n in Notification, where: n.uuid == ^notice.uuid),
        set: [seen_at: DateTime.truncate(DateTime.utc_now(), :second)]
      )

      spend!(ctx.user, ctx.endpoint, 100_000)
      assert :ok = Limits.check(settings, ctx.endpoint.uuid)
      assert [_one] = notifications(ctx.user)
      assert notifications(ctx.owner) == []
    end

    test "80 % of each of the three limits is its own notice", ctx do
      settings =
        limits!(ctx.user,
          daily_cost_limit_micro_usd: 100,
          monthly_cost_limit_micro_usd: 100,
          daily_turn_limit: 5
        )

      spend!(ctx.user, ctx.endpoint, 85)
      turns!(ctx.user, 4)

      assert :ok = Limits.check(settings, ctx.endpoint.uuid)

      usage = Limits.usage(ctx.user.uuid)

      assert notifications(ctx.user) |> Enum.map(& &1.metadata["dedupe_key"]) |> Enum.sort() ==
               Enum.sort([
                 "agent:limit:daily_cost:#{usage.day_key}",
                 "agent:limit:monthly_cost:#{usage.month_key}",
                 "agent:limit:daily_turns:#{usage.day_key}"
               ])
    end

    test "under 80 % nothing is sent", ctx do
      settings = limits!(ctx.user, daily_turn_limit: 10)
      turns!(ctx.user, 7)

      assert :ok = Limits.check(settings, ctx.endpoint.uuid)
      assert notifications(ctx.user) == []
    end
  end

  # ── a limit reached ─────────────────────────────────────────────────

  describe "announce_reached/2" do
    defp reached!(ctx, settings) do
      assert {:error, {:limit_reached, reached}} = Limits.check(settings, ctx.endpoint.uuid)
      :ok = Limits.announce_reached(settings, reached)
      reached
    end

    test "the user's notice is in the user's language, the watchers' in the site's", ctx do
      Gettext.put_locale(PhoenixKitAgent.Gettext, "et")
      settings = limits!(ctx.user, daily_turn_limit: 1, notify_on_limit: true)
      turns!(ctx.user, 1)

      reached!(ctx, settings)

      assert [mine] = notifications(ctx.user)

      assert mine.metadata["notification_text"] ==
               "Oled täna kasutanud ära kõik oma 1 AI-assistendi vestlusringi."

      assert [theirs] = notifications(ctx.owner)

      assert theirs.metadata["notification_text"] ==
               "#{ctx.user.email} has used all 1 AI assistant turns for today."
    end

    test "the user is told in the app; with notify_on_limit, the watchers too — once", ctx do
      settings = limits!(ctx.user, daily_turn_limit: 1, notify_on_limit: true)
      turns!(ctx.user, 1)

      reached!(ctx, settings)
      reached!(ctx, settings)

      assert [mine] = notifications(ctx.user)
      assert mine.metadata["dedupe_key"] == "agent:limit:daily_turns:#{today_key()}"
      assert [theirs] = notifications(ctx.owner)
      assert theirs.metadata["notification_text"] =~ ctx.user.email

      # One event for the user, one for the watchers.
      day = today_key()
      watchers_day = "w:" <> day

      assert [
               %LimitEvent{limit_kind: "daily_turns", period_key: ^day, used: 1, limit: 1},
               %LimitEvent{limit_kind: "daily_turns", period_key: ^watchers_day}
             ] = Enum.sort_by(events(ctx.user), &String.length(&1.period_key))
    end

    test "without notify_on_limit the watchers hear nothing", ctx do
      settings = limits!(ctx.user, daily_turn_limit: 1)
      turns!(ctx.user, 1)

      reached!(ctx, settings)

      assert [_mine] = notifications(ctx.user)
      assert notifications(ctx.owner) == []
    end

    test "agent_limit_watchers replace the Owners; the user's own list adds to them", ctx do
      watcher = user_fixture("watcher")
      boss = user_fixture("boss")
      {:ok, _} = Config.put_limit_watchers([watcher.uuid], [])

      settings =
        limits!(ctx.user,
          daily_turn_limit: 1,
          notify_on_limit: true,
          notify_user_uuids: [boss.uuid]
        )

      turns!(ctx.user, 1)
      reached!(ctx, settings)

      assert [_] = notifications(watcher)
      assert [_] = notifications(boss)
      assert notifications(ctx.owner) == []
    end

    test "a watcher who switched agent_limit off gets nothing", ctx do
      {:ok, _} = Prefs.merge(Auth.get_user(ctx.owner.uuid), %{"agent_limit" => false})
      settings = limits!(ctx.user, daily_turn_limit: 1, notify_on_limit: true)
      turns!(ctx.user, 1)

      reached!(ctx, settings)

      assert notifications(ctx.owner) == []
      assert [_mine] = notifications(ctx.user)
    end

    test "an Owner who reaches a limit is told once, as the user", ctx do
      settings = limits!(ctx.owner, daily_turn_limit: 0, notify_on_limit: true)

      assert {:error, {:limit_reached, reached}} = Limits.check(settings, ctx.endpoint.uuid)
      :ok = Limits.announce_reached(settings, reached)

      assert [_one] = notifications(ctx.owner)
    end

    test "each period is announced on its own", ctx do
      settings = limits!(ctx.user, daily_turn_limit: 0, notify_on_limit: true)

      :ok =
        Limits.announce_reached(settings, %{
          kind: :daily_turns,
          used: 0,
          limit: 0,
          period_key: "2026-10-19"
        })

      :ok =
        Limits.announce_reached(settings, %{
          kind: :daily_turns,
          used: 0,
          limit: 0,
          period_key: "2026-10-20"
        })

      assert length(notifications(ctx.user)) == 2
      assert length(notifications(ctx.owner)) == 2
    end
  end
end
