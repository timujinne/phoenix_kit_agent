defmodule PhoenixKitAgent.Turns.LocksTest do
  @moduledoc """
  The two row locks of a turn (spec §6.1 step 3): taken together, held by one
  turn ref, released only by the turn that holds them.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitAgent.Schemas.{Conversation, UserSettings}
  alias PhoenixKitAgent.Turns.Locks

  @ttl_s 360

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    user = user_fixture("locks")
    %{user: user, chat: conversation_fixture(user)}
  end

  defp holders(ctx) do
    {Repo.get!(Conversation, ctx.chat.uuid).busy_turn_ref,
     Repo.get!(UserSettings, ctx.user.uuid).busy_turn_ref}
  end

  test "a release by an older turn leaves the newer turn's locks in place", ctx do
    assert :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "old", @ttl_s)
    :ok = Locks.release(ctx.user.uuid, ctx.chat.uuid, "old")
    assert :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "new", @ttl_s)

    :ok = Locks.release(ctx.user.uuid, ctx.chat.uuid, "old")

    assert holders(ctx) == {"new", "new"}
    assert Locks.held?(ctx.user.uuid, ctx.chat.uuid, "new")
  end

  test "held?/3 is true only while the turn holds both locks", ctx do
    refute Locks.held?(ctx.user.uuid, ctx.chat.uuid, "t1")

    :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t1", @ttl_s)
    assert Locks.held?(ctx.user.uuid, ctx.chat.uuid, "t1")
    refute Locks.held?(ctx.user.uuid, ctx.chat.uuid, "t2")

    Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^ctx.user.uuid),
      set: [busy_turn_ref: "t2"]
    )

    refute Locks.held?(ctx.user.uuid, ctx.chat.uuid, "t1")

    :ok = Locks.release(ctx.user.uuid, ctx.chat.uuid, "t1")
    refute Locks.held?(ctx.user.uuid, ctx.chat.uuid, "t1")
  end

  test "taking and releasing the user's lock leaves the settings' updated_at alone", ctx do
    changed = ~U[2026-01-02 03:04:05.000000Z]

    Repo.insert!(%UserSettings{
      user_uuid: ctx.user.uuid,
      daily_turn_limit: 3,
      updated_at: changed
    })

    :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t1", @ttl_s)
    assert Repo.get!(UserSettings, ctx.user.uuid).updated_at == changed

    :ok = Locks.release(ctx.user.uuid, ctx.chat.uuid, "t1")
    settings = Repo.get!(UserSettings, ctx.user.uuid)
    assert settings.updated_at == changed
    assert settings.daily_turn_limit == 3
  end

  describe "the user's lock alone (a click on a confirmation card)" do
    test "is refused while a turn of the user runs, and blocks a turn while held", ctx do
      :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "turn", @ttl_s)
      assert {:error, :turn_in_flight} = Locks.acquire_user(ctx.user.uuid, "click", @ttl_s, 30)
      :ok = Locks.release(ctx.user.uuid, ctx.chat.uuid, "turn")

      assert :ok = Locks.acquire_user(ctx.user.uuid, "click", @ttl_s, 30)
      assert {:error, :turn_in_flight} = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t2", @ttl_s)
      assert {:error, :turn_in_flight} = Locks.acquire_user(ctx.user.uuid, "click2", @ttl_s, 30)
      # The chat's own lock is not taken.
      assert Repo.get!(Conversation, ctx.chat.uuid).busy_turn_ref == nil

      :ok = Locks.release_user(ctx.user.uuid, "other")
      assert Repo.get!(UserSettings, ctx.user.uuid).busy_turn_ref == "click"
      :ok = Locks.release_user(ctx.user.uuid, "click")
      assert :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t2", @ttl_s)
    end

    test "a turn that has run longer than the click's hold is still never taken over", ctx do
      :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "turn", @ttl_s)
      age(ctx.user, 120)

      assert {:error, :turn_in_flight} = Locks.acquire_user(ctx.user.uuid, "click", @ttl_s, 30)
    end

    test "a click lock never released blocks a turn for its hold only", ctx do
      :ok = Locks.acquire_user(ctx.user.uuid, "click", @ttl_s, 30)
      assert {:error, :turn_in_flight} = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t1", @ttl_s)

      age(ctx.user, 31)
      assert :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t1", @ttl_s)
    end

    test "a click kept fresh blocks a turn past its hold; another ref keeps nothing", ctx do
      click = Locks.click_ref()
      :ok = Locks.acquire_user(ctx.user.uuid, click, @ttl_s, 30)
      age(ctx.user, 31)

      refute Locks.keep_user(ctx.user.uuid, "another", @ttl_s, 30)
      assert Locks.keep_user(ctx.user.uuid, click, @ttl_s, 30)

      assert {:error, :click_in_flight} =
               Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t1", @ttl_s)

      :ok = Locks.release_user(ctx.user.uuid, click)
      refute Locks.keep_user(ctx.user.uuid, click, @ttl_s, 30)
      assert :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t1", @ttl_s)
    end

    test "a refusal says whether a click or a turn holds the user's lock", ctx do
      click = Locks.click_ref()
      assert "confirm-" <> _uuid = click
      :ok = Locks.acquire_user(ctx.user.uuid, click, @ttl_s, 30)

      assert {:error, :click_in_flight} =
               Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t1", @ttl_s)

      assert {:error, :click_in_flight} =
               Locks.acquire_user(ctx.user.uuid, Locks.click_ref(), @ttl_s, 30)

      # The chat's lock is not left behind by the refused turn.
      assert Repo.get!(Conversation, ctx.chat.uuid).busy_turn_ref == nil

      :ok = Locks.release_user(ctx.user.uuid, click)
      :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t1", @ttl_s)

      assert {:error, :turn_in_flight} =
               Locks.acquire_user(ctx.user.uuid, Locks.click_ref(), @ttl_s, 30)
    end
  end

  # The user's lock as if taken `seconds` earlier.
  defp age(user, seconds) do
    Repo.update_all(
      from(s in UserSettings,
        where: s.user_uuid == ^user.uuid,
        update: [set: [busy_since: fragment("busy_since - make_interval(secs => ?)", ^seconds)]]
      ),
      []
    )
  end
end
