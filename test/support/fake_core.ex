defmodule PhoenixKitAgent.Test.FakeCore do
  @moduledoc """
  Stands in for the core's `PhoenixKit.API.Executor` and `PhoenixKit.API.Confirm`
  where the core at hand does not let a linked Telegram chat hold a write
  (no `Executor.link_writes?/0`), so the module's side of it can be tested
  on any core it supports:

      config :phoenix_kit_agent, :api_modules, executor: FakeCore, confirm: FakeCore

  It does what the core with that feature does, on top of the real calls:
  a chat reference acts as the session of its user (`install/1`), as long as
  the chat is still linked to that user; a row held through a chat carries
  the chat in its `context` (`"origin" => "telegram"`, `"connection_uuid"`,
  `"chat_id"` as a string), a row held anywhere else does not; a chat reads,
  confirms or turns down only a row of its own chat — another's is
  `{:error, :foreign}` to a read, and `other_origin` to a redeem — and the
  row that replaces a changed one keeps the chat.

  `{:fake_core, :redeem, via}` is sent to the process named in
  `:fake_core_listener` for each redeem, with the `via` it got.
  The tests that run on a core with the feature leave this module out.
  """

  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Executor
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKitAgent.Test.Repo
  alias PhoenixKitAgent.Turns.Tools

  import Ecto.Query, only: [from: 2]

  @doc "Lets the chat references of `user` act as the live session `session_ref`."
  def install(user_uuid, session_ref) do
    sessions = Application.get_env(:phoenix_kit_agent, :fake_core_sessions, %{})

    Application.put_env(
      :phoenix_kit_agent,
      :fake_core_sessions,
      Map.put(sessions, user_uuid, session_ref)
    )
  end

  def link_writes?, do: true

  # ── the executor ──────────────────────────────────────────────────

  def visible_for(ref, :admin, opts),
    do: with_session(ref, &Executor.visible_for(&1, :admin, opts))

  def execute_as({:telegram_link, _, connection, chat_id} = ref, :admin, name, input, opts) do
    ref
    |> with_session(&Executor.execute_as(&1, :admin, name, input, opts))
    |> tap(fn
      {:ok, %{result: result}, _headers} ->
        with {:ok, uuid} <- Tools.held(result), do: bind(uuid, connection, chat_id)

      _other ->
        :ok
    end)
  end

  def execute_as(ref, :admin, name, input, opts),
    do: Executor.execute_as(ref, :admin, name, input, opts)

  def redeem_as(ref, :admin, uuid, name, input, opts) do
    case Application.get_env(:phoenix_kit_agent, :fake_core_listener) do
      pid when is_pid(pid) -> send(pid, {:fake_core, :redeem, opts[:via]})
      _none -> :ok
    end

    redeem(ref, uuid, name, input, opts)
  end

  defp redeem({:telegram_link, _, connection, chat_id} = ref, uuid, name, input, opts) do
    if mine?(uuid, connection, chat_id) do
      ref
      |> with_session(&Executor.redeem_as(&1, :admin, uuid, name, input, opts))
      |> tap(&bind_replacement(&1, connection, chat_id))
    else
      {:error, :confirm_token_invalid, "The confirmation is not for this chat.",
       %{reason: "other_origin"}, []}
    end
  end

  defp redeem(ref, uuid, name, input, opts),
    do: Executor.redeem_as(ref, :admin, uuid, name, input, opts)

  # The row that replaces a changed one is the chat's too.
  defp bind_replacement({:ok, %{result: result}, _headers}, connection, chat_id) do
    with {:ok, new_uuid} <- Tools.held(result), do: bind(new_uuid, connection, chat_id)
  end

  defp bind_replacement(_other, _connection, _chat_id), do: :ok

  # ── the confirmations ─────────────────────────────────────────────

  def get_for_user(uuid, {:telegram_link, _, connection, chat_id} = ref) do
    cond do
      not linked?(ref) -> {:error, :unauthorized}
      foreign?(uuid, connection, chat_id) -> {:error, :foreign}
      true -> Confirm.get_for_user(uuid, session(ref))
    end
  end

  def get_for_user(uuid, ref), do: Confirm.get_for_user(uuid, ref)

  def reject_for_user(uuid, ref, now \\ DateTime.utc_now())

  def reject_for_user(uuid, {:telegram_link, _, connection, chat_id} = ref, now) do
    cond do
      not linked?(ref) -> {:error, :unauthorized}
      foreign?(uuid, connection, chat_id) -> {:error, :foreign}
      true -> Confirm.reject_for_user(uuid, session(ref), now)
    end
  end

  def reject_for_user(uuid, ref, now), do: Confirm.reject_for_user(uuid, ref, now)

  def lookup_for_user(uuid, user_uuid), do: Confirm.lookup_for_user(uuid, user_uuid)

  # ── the chat's side ───────────────────────────────────────────────

  defp with_session({:telegram_link, _, _, _} = ref, fun) do
    if linked?(ref),
      do: fun.(session(ref)),
      else: {:error, :unauthorized, "The chat is not linked.", %{reason: :unlinked}, []}
  end

  defp with_session(ref, fun), do: fun.(ref)

  defp linked?({:telegram_link, user_uuid, connection, chat_id}) do
    match?(%{uuid: ^user_uuid}, Linking.linked_user(connection, chat_id))
  end

  defp session({:telegram_link, user_uuid, _, _}) do
    :phoenix_kit_agent
    |> Application.fetch_env!(:fake_core_sessions)
    |> Map.fetch!(user_uuid)
  end

  defp bind(uuid, connection, chat_id) do
    row = Repo.get!(Confirmation, uuid)

    context =
      Map.merge(row.context || %{}, %{
        "origin" => "telegram",
        "connection_uuid" => connection,
        "chat_id" => to_string(chat_id)
      })

    Repo.update_all(from(c in Confirmation, where: c.uuid == ^uuid), set: [context: context])
  end

  defp mine?(uuid, connection, chat_id), do: origin(uuid, connection, chat_id) == :mine

  # A row that is there and is not this chat's; a row that is not there is
  # left to the real call to say so.
  defp foreign?(uuid, connection, chat_id), do: origin(uuid, connection, chat_id) == :foreign

  defp origin(uuid, connection, chat_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Confirmation{context: context} <- Repo.get(Confirmation, uuid) do
      if match?(%{"origin" => "telegram"}, context) and context["connection_uuid"] == connection and
           context["chat_id"] == to_string(chat_id),
         do: :mine,
         else: :foreign
    else
      _missing -> :missing
    end
  end
end
