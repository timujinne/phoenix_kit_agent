defmodule PhoenixKitAgent.Fixtures do
  @moduledoc """
  Rows the integration tests build on: users with exactly the permissions a
  test names, AI endpoints and request-journal rows, agent chats.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAgent.Schemas.Conversation
  alias PhoenixKitAgent.Test.Repo

  @doc """
  A registered user. The first user of a database is made its Owner by core;
  every test runs in a sandbox, so call `owner_fixture/0` first where a test
  needs the Owner to be someone in particular.
  """
  def user_fixture(tag \\ "user") do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "agent-#{tag}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    Repo.get!(Auth.User, user.uuid)
  end

  @doc "The Owner of the sandbox: an existing one, or a new user made Owner."
  def owner_fixture do
    case Roles.users_with_role("Owner") do
      [owner | _] -> Repo.get!(Auth.User, owner.uuid)
      [] -> ensure_owner(user_fixture("owner"))
    end
  end

  defp ensure_owner(user) do
    unless "Owner" in Roles.get_user_roles(user), do: {:ok, _} = Roles.assign_role(user, "Owner")
    user
  end

  @doc "A user holding one new custom role that grants exactly `permissions`."
  def user_with(permissions, tag \\ "member") do
    # Not the first user of the sandbox: that one would be the Owner.
    _ = owner_fixture()
    {:ok, role} = Roles.create_role(%{name: "AgentTest#{System.unique_integer([:positive])}"})
    for key <- permissions, do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture(tag)
    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  @doc "The user's scope, as core builds it for a signed-in session."
  def scope_of(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  @doc """
  A live browser session of `user`: the `{session_token_uuid, user_uuid}`
  reference core's `SessionRef.from_session/1` reads from a LiveView session,
  and the raw token (to revoke the session with). The user's email is
  confirmed first (core refuses the session of an unconfirmed account), unless
  `confirmed: false`.
  """
  def session_fixture(user, opts \\ []) do
    if Keyword.get(opts, :confirmed, true) do
      Repo.update_all(from(u in Auth.User, where: u.uuid == ^user.uuid),
        set: [confirmed_at: DateTime.utc_now()]
      )
    end

    token = Auth.generate_user_session_token(Repo.get!(Auth.User, user.uuid))
    {:ok, ref} = SessionRef.from_session(%{"user_token" => token})
    {ref, token}
  end

  def endpoint_fixture(attrs \\ %{}, opts \\ []) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Agent endpoint #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "deepseek/deepseek-v4.1-flash",
            api_key: "sk-or-v1-test-key"
          },
          Map.new(attrs)
        ),
        opts
      )

    endpoint
  end

  @doc """
  A journal cost (`PhoenixKitAI.Request.cost`, dollars) from micro-dollars,
  the unit the tests count in; a `Decimal` is taken as dollars already.
  """
  def journal_cost(nil), do: nil
  def journal_cost(%Decimal{} = usd), do: usd
  def journal_cost(micro) when is_integer(micro), do: Decimal.div(micro, 1_000_000)

  def ai_request_fixture(user, endpoint) do
    %PhoenixKitAI.Request{}
    |> PhoenixKitAI.Request.changeset(%{
      endpoint_uuid: endpoint.uuid,
      user_uuid: user.uuid,
      model: endpoint.model,
      status: "success",
      metadata: %{"source" => "agent"}
    })
    |> Repo.insert!()
  end

  def conversation_fixture(user, attrs \\ %{}) do
    %Conversation{user_uuid: user.uuid}
    |> Conversation.changeset(Map.merge(%{title: "Chat"}, Map.new(attrs)))
    |> Repo.insert!()
  end
end
