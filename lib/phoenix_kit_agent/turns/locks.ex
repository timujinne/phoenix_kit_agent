defmodule PhoenixKitAgent.Turns.Locks do
  @moduledoc """
  The two locks of a turn (spec §6.1 step 3), both rows in the database:

    * the chat's — `busy_since` / `busy_turn_ref` of
      `phoenix_kit_agent_conversations`: one turn per chat;
    * the user's — the same columns of `phoenix_kit_agent_user_settings` (the
      row is created empty when the user has none): one turn in flight per
      user, so parallel chats cannot run past a limit.

  Each is taken by one atomic statement that succeeds only when the lock is
  free or older than its TTL (`busy_since < now - ttl`), so a lock left by a
  node that went down frees itself. No advisory lock: it would hold a pool
  connection for the whole turn. A lock is released only by the turn that
  holds it (`busy_turn_ref`), so a late release cannot free a newer turn, and
  a running turn checks before each round that it still holds both
  (`held?/3`): a turn whose lock was taken over stops there. Times are the
  database's (`now()`), so the TTL does not depend on the clocks of the nodes.
  Neither statement touches `updated_at` of a settings row: that stays the
  time the settings themselves last changed.

  A click on a confirmation card (`PhoenixKitAgent.Confirmations`) takes the
  user's lock alone (`acquire_user/4`) under a ref of its own (`click_ref/0`):
  it is refused while a turn of the user runs, and no turn starts while it
  runs — the click keeps its lock fresh (`keep_user/4`) for as long as it
  runs. Whoever is refused the user's lock learns what holds it:
  `:turn_in_flight` (a turn) or `:click_in_flight` (a click).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.Schemas.{Conversation, UserSettings}

  # What the ref of a click starts with; a turn's ref is a bare UUIDv7.
  @click_prefix "confirm-"

  @doc """
  Takes both locks for `turn_ref`, or neither. The chat is tried first, so a
  second turn in the same chat is `:conversation_busy`; a turn of the user in
  another chat is `:turn_in_flight`, a click of the user `:click_in_flight`.
  """
  @spec acquire(String.t(), String.t(), String.t(), pos_integer()) ::
          :ok | {:error, :conversation_busy | :turn_in_flight | :click_in_flight}
  def acquire(user_uuid, conversation_uuid, turn_ref, ttl_s) do
    result =
      repo().transaction(fn ->
        now = db_now()
        stale = DateTime.add(now, -ttl_s, :second)

        with :ok <- lock_conversation(user_uuid, conversation_uuid, turn_ref, now, stale),
             :ok <- lock_user(user_uuid, turn_ref, now, now, stale) do
          :ok
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "A new ref for a click on a confirmation card, told apart from a turn's."
  @spec click_ref() :: String.t()
  def click_ref, do: @click_prefix <> UUIDv7.generate()

  @doc """
  Takes the user's lock alone for `ref` (a click on a confirmation card), or
  `{:error, :turn_in_flight | :click_in_flight}`. `ttl_s` is how old another
  holder's lock must be to be taken over — the TTL of a turn's locks, so a
  turn still running is never taken over; `hold_s` (at most `ttl_s`) is how
  long this lock blocks a turn: it is dated back by `ttl_s - hold_s`, so a
  turn takes it over `hold_s` after it was taken (or last kept,
  `keep_user/4`), should it never be released (its node went down).
  Released with `release_user/2`.
  """
  @spec acquire_user(String.t(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, :turn_in_flight | :click_in_flight}
  def acquire_user(user_uuid, ref, ttl_s, hold_s) when hold_s > 0 and hold_s <= ttl_s do
    now = db_now()

    lock_user(
      user_uuid,
      ref,
      held_since(now, ttl_s, hold_s),
      now,
      DateTime.add(now, -ttl_s, :second)
    )
  end

  @doc """
  Dates the user's lock of `ref` as if taken now (with `acquire_user/4`'s
  `ttl_s` and `hold_s`), while `ref` still holds it: a click that runs longer
  than its hold keeps blocking a turn. `true` when `ref` held it.
  """
  @spec keep_user(String.t(), String.t(), pos_integer(), pos_integer()) :: boolean()
  def keep_user(user_uuid, ref, ttl_s, hold_s) when hold_s > 0 and hold_s <= ttl_s do
    {count, _} =
      repo().update_all(
        from(s in UserSettings, where: s.user_uuid == ^user_uuid and s.busy_turn_ref == ^ref),
        set: [busy_since: held_since(db_now(), ttl_s, hold_s)]
      )

    count == 1
  end

  defp held_since(now, ttl_s, hold_s), do: DateTime.add(now, hold_s - ttl_s, :second)

  @doc "Releases the user's lock if `ref` still holds it."
  @spec release_user(String.t(), String.t()) :: :ok
  def release_user(user_uuid, ref) do
    repo().update_all(
      from(s in UserSettings, where: s.user_uuid == ^user_uuid and s.busy_turn_ref == ^ref),
      set: [busy_since: nil, busy_turn_ref: nil]
    )

    :ok
  end

  @doc "Whether `turn_ref` holds both locks."
  @spec held?(String.t(), String.t(), String.t()) :: boolean()
  def held?(user_uuid, conversation_uuid, turn_ref) do
    repo().exists?(
      from(c in Conversation,
        where: c.uuid == ^conversation_uuid and c.busy_turn_ref == ^turn_ref
      )
    ) and
      repo().exists?(
        from(s in UserSettings, where: s.user_uuid == ^user_uuid and s.busy_turn_ref == ^turn_ref)
      )
  end

  @doc """
  Whether the chat's lock is `turn_ref`'s and younger than `ttl_s` (the
  database's clock): the turn may still run, on this node or another.
  """
  @spec fresh?(String.t(), String.t(), pos_integer()) :: boolean()
  def fresh?(conversation_uuid, turn_ref, ttl_s) do
    stale = stale_before(ttl_s)

    repo().exists?(
      from(c in Conversation,
        where:
          c.uuid == ^conversation_uuid and c.busy_turn_ref == ^turn_ref and
            c.busy_since >= ^stale
      )
    )
  end

  @doc "Releases both locks if `turn_ref` still holds them."
  @spec release(String.t(), String.t(), String.t()) :: :ok
  def release(user_uuid, conversation_uuid, turn_ref) do
    repo().update_all(
      from(c in Conversation,
        where: c.uuid == ^conversation_uuid and c.busy_turn_ref == ^turn_ref
      ),
      set: [busy_since: nil, busy_turn_ref: nil]
    )

    repo().update_all(
      from(s in UserSettings, where: s.user_uuid == ^user_uuid and s.busy_turn_ref == ^turn_ref),
      set: [busy_since: nil, busy_turn_ref: nil]
    )

    :ok
  end

  @doc """
  Releases the locks of `turn_ref` only while the chat's lock is still its and
  older than `ttl_s` (the database's clock): what is left of a turn lost with
  its node. `true` when this call released it, so of two callers at most one
  does; the user's lock goes too, if `turn_ref` still holds it.
  """
  @spec release_stale(String.t(), String.t(), String.t(), pos_integer()) :: boolean()
  def release_stale(user_uuid, conversation_uuid, turn_ref, ttl_s) do
    stale = stale_before(ttl_s)

    {count, _} =
      repo().update_all(
        from(c in Conversation,
          where:
            c.uuid == ^conversation_uuid and c.busy_turn_ref == ^turn_ref and
              c.busy_since < ^stale
        ),
        set: [busy_since: nil, busy_turn_ref: nil]
      )

    if count == 1 do
      repo().update_all(
        from(s in UserSettings,
          where: s.user_uuid == ^user_uuid and s.busy_turn_ref == ^turn_ref
        ),
        set: [busy_since: nil, busy_turn_ref: nil]
      )

      true
    else
      false
    end
  end

  defp lock_conversation(user_uuid, conversation_uuid, turn_ref, now, stale) do
    {count, _} =
      repo().update_all(
        from(c in Conversation,
          where:
            c.uuid == ^conversation_uuid and c.user_uuid == ^user_uuid and
              (is_nil(c.busy_since) or c.busy_since < ^stale)
        ),
        set: [busy_since: now, busy_turn_ref: turn_ref]
      )

    if count == 1, do: :ok, else: {:error, :conversation_busy}
  end

  # One statement: insert the row, or take the lock of the existing one when
  # it is free or stale. A conflict whose `WHERE` fails touches no row. The
  # lock is dated `since` (`now`, or earlier for a short one).
  defp lock_user(user_uuid, turn_ref, since, now, stale, retry? \\ true) do
    take =
      from(s in UserSettings,
        where: is_nil(s.busy_since) or s.busy_since < ^stale,
        update: [set: [busy_since: ^since, busy_turn_ref: ^turn_ref]]
      )

    {count, _} =
      repo().insert_all(
        UserSettings,
        [
          %{
            user_uuid: user_uuid,
            busy_since: since,
            busy_turn_ref: turn_ref,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: take,
        conflict_target: [:user_uuid]
      )

    case count == 1 || holder(user_uuid) do
      true -> :ok
      nil when retry? -> lock_user(user_uuid, turn_ref, since, now, stale, false)
      nil -> {:error, :turn_in_flight}
      holder -> {:error, holder}
    end
  end

  # What holds the user's lock that could not be taken: a click or a turn;
  # `nil` once it is released (between the take and this read), and then the
  # take is tried once more.
  defp holder(user_uuid) do
    ref =
      repo().one(
        from(s in UserSettings, where: s.user_uuid == ^user_uuid, select: s.busy_turn_ref)
      )

    cond do
      not is_binary(ref) -> nil
      String.starts_with?(ref, @click_prefix) -> :click_in_flight
      true -> :turn_in_flight
    end
  end

  # A lock taken before this time is older than `ttl_s`.
  defp stale_before(ttl_s), do: DateTime.add(db_now(), -ttl_s, :second)

  # `now()` is the transaction's start, the same for both locks.
  defp db_now do
    %{rows: [[now]]} = repo().query!("SELECT now()")
    now
  end

  defp repo, do: RepoHelper.repo()
end
