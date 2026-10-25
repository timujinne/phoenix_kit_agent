defmodule PhoenixKitAgent.SpendTest do
  @moduledoc """
  What a user spent on the assistant (spec §7.3): counted from the AI request
  journal (`user_uuid` and `metadata.source = "agent"`), in calendar days and
  months of the site time zone, in micro-dollars ($1 = 1_000_000).
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitAgent.Spend

  setup do
    {:ok, _} = Settings.update_setting("time_zone", "Europe/Tallinn")
    %{user: user_fixture("spender"), endpoint: endpoint_fixture()}
  end

  defp spend!(user, endpoint, cost, at, metadata \\ %{"source" => "agent"}, status \\ "success") do
    Repo.insert!(%PhoenixKitAI.Request{
      endpoint_uuid: endpoint.uuid,
      user_uuid: user.uuid,
      model: endpoint.model,
      status: status,
      cost: journal_cost(cost),
      metadata: metadata,
      inserted_at: at
    })
  end

  describe "for_users/2" do
    test "sums the user's assistant requests of today and of the month", ctx do
      now = ~U[2026-07-15 12:00:00Z]

      spend!(ctx.user, ctx.endpoint, 120_000, ~U[2026-07-15 08:00:00Z])
      spend!(ctx.user, ctx.endpoint, 30_000, ~U[2026-07-15 11:59:00Z])
      spend!(ctx.user, ctx.endpoint, 500_000, ~U[2026-07-03 08:00:00Z])

      assert Spend.for_users([ctx.user.uuid], now) == %{
               ctx.user.uuid => %{day_micro_usd: 150_000, month_micro_usd: 650_000}
             }
    end

    test "leaves out other users, other sources, requests without a cost and other months",
         ctx do
      now = ~U[2026-07-15 12:00:00Z]
      other = user_fixture("other")

      spend!(ctx.user, ctx.endpoint, 10, ~U[2026-07-15 08:00:00Z])
      spend!(other, ctx.endpoint, 1_000, ~U[2026-07-15 08:00:00Z])
      spend!(ctx.user, ctx.endpoint, 1_000, ~U[2026-07-15 08:00:00Z], %{"source" => "playground"})
      spend!(ctx.user, ctx.endpoint, 1_000, ~U[2026-07-15 08:00:00Z], %{})
      spend!(ctx.user, ctx.endpoint, nil, ~U[2026-07-15 08:00:00Z])
      spend!(ctx.user, ctx.endpoint, 1_000, ~U[2026-06-15 08:00:00Z])
      spend!(ctx.user, ctx.endpoint, 1_000, ~U[2026-08-15 08:00:00Z])

      assert Spend.for_users([ctx.user.uuid, other.uuid], now) == %{
               ctx.user.uuid => %{day_micro_usd: 10, month_micro_usd: 10},
               other.uuid => %{day_micro_usd: 1_000, month_micro_usd: 1_000}
             }
    end

    test "a user with no requests spent nothing, and is still in the answer", ctx do
      assert Spend.for_users([ctx.user.uuid], ~U[2026-07-15 12:00:00Z]) == %{
               ctx.user.uuid => %{day_micro_usd: 0, month_micro_usd: 0}
             }

      assert Spend.for_users([]) == %{}
    end

    test "the day and the month are those of the site time zone, not of UTC", ctx do
      # 00:30 on 16 July in Tallinn (UTC+3).
      now = ~U[2026-07-15 21:30:00Z]

      spend!(ctx.user, ctx.endpoint, 1, ~U[2026-07-15 20:59:00Z])
      spend!(ctx.user, ctx.endpoint, 20, ~U[2026-07-15 21:00:00Z])

      assert %{day_micro_usd: 20, month_micro_usd: 21} =
               Spend.for_users([ctx.user.uuid], now)[ctx.user.uuid]
    end

    test "the month turns over at local midnight of the first", ctx do
      # 00:30 on 1 August in Tallinn.
      now = ~U[2026-07-31 21:30:00Z]

      spend!(ctx.user, ctx.endpoint, 5, ~U[2026-07-31 20:59:00Z])
      spend!(ctx.user, ctx.endpoint, 7, ~U[2026-07-31 21:05:00Z])

      assert %{day_micro_usd: 7, month_micro_usd: 7} =
               Spend.for_users([ctx.user.uuid], now)[ctx.user.uuid]
    end

    test "winter time: the same rule with another offset", ctx do
      # 01:00 on 16 January in Tallinn (UTC+2) is 23:00Z on the 15th.
      now = ~U[2026-01-15 23:00:00Z]

      spend!(ctx.user, ctx.endpoint, 3, ~U[2026-01-15 21:59:00Z])
      spend!(ctx.user, ctx.endpoint, 4, ~U[2026-01-15 22:00:00Z])

      assert %{day_micro_usd: 4} = Spend.for_users([ctx.user.uuid], now)[ctx.user.uuid]
    end

    test "the day ends at the next local midnight; later rows count for the month only", ctx do
      # 15 July in Tallinn runs from 21:00Z on the 14th to 21:00Z on the 15th.
      now = ~U[2026-07-15 12:00:00Z]

      spend!(ctx.user, ctx.endpoint, 1, ~U[2026-07-15 20:59:59Z])
      spend!(ctx.user, ctx.endpoint, 10, ~U[2026-07-15 21:00:00Z])
      spend!(ctx.user, ctx.endpoint, 100, ~U[2026-07-20 08:00:00Z])

      assert %{day_micro_usd: 1, month_micro_usd: 111} =
               Spend.for_users([ctx.user.uuid], now)[ctx.user.uuid]
    end

    test "a call that failed but has a cost is money spent; one without a cost is not", ctx do
      now = ~U[2026-07-15 12:00:00Z]
      at = ~U[2026-07-15 08:00:00Z]

      spend!(ctx.user, ctx.endpoint, 40, at, %{"source" => "agent"}, "error")
      spend!(ctx.user, ctx.endpoint, 2, at, %{"source" => "agent"}, "timeout")
      spend!(ctx.user, ctx.endpoint, nil, at, %{"source" => "agent"}, "error")
      spend!(ctx.user, ctx.endpoint, 5, at)

      assert %{day_micro_usd: 47, month_micro_usd: 47} =
               Spend.for_users([ctx.user.uuid], now)[ctx.user.uuid]
    end

    test "dollars finer than a micro-dollar are summed first, then rounded half up", ctx do
      now = ~U[2026-07-15 12:00:00Z]

      spend!(ctx.user, ctx.endpoint, Decimal.new("0.0000004"), ~U[2026-07-15 08:00:00Z])
      spend!(ctx.user, ctx.endpoint, Decimal.new("0.0000004"), ~U[2026-07-15 09:00:00Z])
      spend!(ctx.user, ctx.endpoint, Decimal.new("0.0000017"), ~U[2026-07-03 08:00:00Z])

      # Day: $0.0000008 is 0.8 micro, 1. Month: $0.0000025 is 2.5 micro, 3 —
      # not 2, as rounding each row (0 + 0 + 2) or half to even would give.
      assert Spend.for_users([ctx.user.uuid], now) == %{
               ctx.user.uuid => %{day_micro_usd: 1, month_micro_usd: 3}
             }
    end

    test "a sum of large costs is still a whole number of micro-dollars", ctx do
      spend!(ctx.user, ctx.endpoint, 2_000_000_000, ~U[2026-07-15 08:00:00Z])
      spend!(ctx.user, ctx.endpoint, 2_000_000_000, ~U[2026-07-15 09:00:00Z])

      assert %{day_micro_usd: 4_000_000_000} =
               Spend.for_users([ctx.user.uuid], ~U[2026-07-15 12:00:00Z])[ctx.user.uuid]
    end
  end

  describe "users_this_month/1" do
    test "who called the assistant this month, without a call the AI guard refused", ctx do
      now = ~U[2026-07-15 12:00:00Z]
      refused = user_fixture("refused")
      failed = user_fixture("failed")
      gone = user_fixture("gone")

      spend!(ctx.user, ctx.endpoint, 10, ~U[2026-07-15 08:00:00Z])
      # Refused before any request was sent: never a call.
      spend!(
        refused,
        ctx.endpoint,
        nil,
        ~U[2026-07-15 08:00:00Z],
        %{"source" => "agent", "refused" => true},
        "error"
      )

      # Sent, and failed: a call.
      spend!(failed, ctx.endpoint, nil, ~U[2026-07-15 08:00:00Z], %{"source" => "agent"}, "error")
      spend!(gone, ctx.endpoint, 10, ~U[2026-06-15 08:00:00Z])

      assert Enum.sort(Spend.users_this_month(now)) == Enum.sort([ctx.user.uuid, failed.uuid])
    end
  end

  describe "windows/1" do
    test "the bounds of the day and of the month in the site time zone" do
      assert %{
               day: {~U[2026-07-14 21:00:00Z], ~U[2026-07-15 21:00:00Z]},
               month: {~U[2026-06-30 21:00:00Z], ~U[2026-07-31 21:00:00Z]}
             } = Spend.windows(~U[2026-07-15 12:00:00Z])
    end
  end
end
