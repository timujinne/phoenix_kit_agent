defmodule PhoenixKitAgent.Web.SpendingLiveTest do
  @moduledoc """
  Admin → Agent → Spending (spec §7, §10): what every user spent on the
  assistant today and this month, from the AI request journal, and their turns
  today. Open to `agent.manage` only.
  """

  use PhoenixKitAgent.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitAgent.Schemas.Message

  @path "/en/admin/agent/spending"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = Settings.update_setting("time_zone", "Europe/Tallinn")
    %{endpoint: endpoint_fixture()}
  end

  defp spend!(user, endpoint, cost, opts \\ []) do
    Repo.insert!(%PhoenixKitAI.Request{
      endpoint_uuid: endpoint.uuid,
      user_uuid: user.uuid,
      model: endpoint.model,
      status: "success",
      cost: journal_cost(cost),
      metadata: Keyword.get(opts, :metadata, %{"source" => "agent"}),
      inserted_at: Keyword.get(opts, :at, DateTime.truncate(DateTime.utc_now(), :second))
    })
  end

  defp turn!(user) do
    chat = conversation_fixture(user)

    Repo.insert!(%Message{
      conversation_uuid: chat.uuid,
      turn_ref: UUIDv7.generate(),
      role: "user",
      content: "Hi"
    })
  end

  describe "with agent.manage" do
    setup %{conn: conn} do
      admin = user_with(["agent", "agent.manage"], "manager")
      %{conn: log_in(conn, admin), admin: admin}
    end

    test "every user who spent this month, today and this month, with today's turns", ctx do
      member = user_with(["agent"], "member")
      # Someone who no longer holds `agent` still spent.
      former = user_with(["dashboard"], "former")
      idle = user_with(["agent"], "idle")

      spend!(member, ctx.endpoint, 120_000)
      spend!(member, ctx.endpoint, 30_000)
      spend!(member, ctx.endpoint, 5_000, metadata: %{"source" => "playground"})
      turn!(member)
      turn!(member)
      spend!(former, ctx.endpoint, 2_000_000)

      {:ok, view, _html} = live(ctx.conn, @path)

      row = "#agent-spending-#{member.uuid}"
      assert has_element?(view, row, member.email)
      assert has_element?(view, "#{row}-day", "0.15")
      assert has_element?(view, "#{row}-month", "0.15")
      assert has_element?(view, "#{row}-turns", "2")

      assert has_element?(view, "#agent-spending-#{former.uuid}-month", "2.00")
      refute has_element?(view, "#agent-spending-#{idle.uuid}")

      assert has_element?(view, "#agent-spending-total-day", "2.15")
      assert has_element?(view, "#agent-spending-total-month", "2.15")
    end

    test "spending of an earlier day of the month counts for the month only", ctx do
      member = user_with(["agent"], "member")

      # A site time zone where today is not the first of the month: the dates
      # at UTC+14 and UTC-12 (legacy offset settings) are always one or two
      # days apart, so one of them is not the first.
      zone =
        Enum.find(["14", "-12"], fn zone ->
          {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", zone)
          %{day: {day_start, _}, month: {month_start, _}} = PhoenixKitAgent.Spend.windows()
          DateTime.compare(day_start, month_start) == :gt
        end)

      assert zone
      {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", zone)
      {day_start, _} = PhoenixKitAgent.Spend.windows().day

      spend!(member, ctx.endpoint, 40_000, at: DateTime.add(day_start, -60, :second))
      spend!(member, ctx.endpoint, 10_000)

      {:ok, view, _html} = live(ctx.conn, @path)

      assert has_element?(view, "#agent-spending-#{member.uuid}-day", "0.01")
      assert has_element?(view, "#agent-spending-#{member.uuid}-month", "0.05")
    end

    test "nobody spent anything", ctx do
      {:ok, view, _html} = live(ctx.conn, @path)

      assert has_element?(view, "#agent-spending-empty")
      assert has_element?(view, "#agent-spending-total-month", "0.00")
    end

    test "the page is in the language of the user", ctx do
      {:ok, view, _html} =
        ctx.conn |> Plug.Test.init_test_session(%{"locale" => "et"}) |> live(@path)

      assert has_element?(
               view,
               "#agent-spending-empty",
               "Keegi ei kasutanud assistenti sel kuul."
             )
    end
  end

  describe "without agent.manage" do
    test "the page does not open for a user who only uses the assistant", %{conn: conn} do
      user = user_with(["agent"], "member")
      spend!(user, endpoint_fixture(), 1_000)

      assert {:error, {:live_redirect, %{to: to}}} = live(log_in(conn, user), @path)
      assert to =~ "/admin"
    end

    test "nobody signed in is sent away", %{conn: conn} do
      assert {:error, {:live_redirect, _}} = live(conn, @path)
    end
  end
end
