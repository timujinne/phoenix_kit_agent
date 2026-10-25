defmodule PhoenixKitAgent.Models do
  @moduledoc """
  The choice of a model for a user (spec §7.2). The module has no models of its
  own: the choice is among the endpoints of `phoenix_kit_ai` (an endpoint is a
  connection plus a model), and only endpoints that can chat.

  `list_endpoints/1` is the choice; `tools_support/1` says, per endpoint,
  whether its model takes tools — the assistant is useless on one that does
  not, so the screens mark those. `image_input_support/1` is the same question
  about images in; the attachments (spec §9) use it to decide whether a
  picture goes to the model as pixels or as a description. Both read
  `PhoenixKitAI.Capabilities.for_endpoint/1` — the provider's catalogue as
  `phoenix_kit_ai` keeps it, with what an admin declared on the endpoint where
  the catalogue says nothing — from its cache only, never the network:

    * `:supported` / `:unsupported` — the model is known to take it, or not;
    * `:unknown` — nobody knows: a provider without a catalogue whose
      endpoint declares nothing, a model the catalogue does not list, a
      catalogue not read yet.

  Only `:supported` lets pixels go to a model (`image_input/1`).

  `reports_cost?/2` says whether a call on an endpoint gets what it cost in
  the AI journal — the money limits count only such calls (spec §7.3).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKitAI.{Capabilities, Endpoint, TaskLimits}

  @typedoc "Whether a model takes tools."
  @type support :: :supported | :unsupported | :unknown

  @typedoc """
  What a page shows of an endpoint: never the endpoint itself, which carries
  its API key. `reports_cost?` is `reports_cost?/2` of a chat call on it.
  """
  @type summary :: %{
          uuid: String.t(),
          name: String.t(),
          model: String.t(),
          provider: String.t(),
          reports_cost?: boolean()
        }

  @typedoc """
  What a call on an endpoint is: a model call of a turn, or a picture
  described by the vision model.
  """
  @type call_kind :: :chat | :vision

  # What `reports_cost?/2` reads of an endpoint, its key left out.
  @cost_fields [:uuid, :name, :model, :provider, :base_url, :provider_settings]

  @page_size 500

  @doc """
  The endpoints a user can be given: enabled ones that chat (not speech,
  embedding or image models), by name. `include: uuid` (or a list of uuids)
  adds that endpoint even if it can no longer be picked — the one a user has
  now, so that saving the form does not drop it unnoticed.
  """
  @spec list_endpoints(keyword()) :: [Endpoint.t()]
  def list_endpoints(opts \\ []) do
    {endpoints, _total} = PhoenixKitAI.list_endpoints(enabled: true, page_size: @page_size)

    endpoints
    |> Enum.filter(&(Endpoint.kind(&1) == :chat))
    |> add_current(opts |> Keyword.get(:include) |> List.wrap())
    |> Enum.sort_by(&{String.downcase(&1.name || ""), &1.uuid})
  end

  @doc "An endpoint as a page keeps it (`t:summary/0`)."
  @spec summary(Endpoint.t()) :: summary()
  def summary(%Endpoint{} = endpoint),
    do: %{
      uuid: endpoint.uuid,
      name: endpoint.name,
      model: endpoint.model,
      provider: endpoint.provider,
      reports_cost?: reports_cost?(endpoint)
    }

  @doc "The endpoints with these uuids as `t:summary/0`: `%{uuid => summary}`."
  @spec summaries([String.t()]) :: %{String.t() => summary()}
  def summaries(uuids) when is_list(uuids) do
    from(e in Endpoint, where: e.uuid in ^Enum.uniq(uuids), select: struct(e, ^@cost_fields))
    |> RepoHelper.repo().all()
    |> Map.new(&{&1.uuid, summary(&1)})
  end

  @doc """
  `tools_support/1` for the endpoints with these uuids, read again from the
  database (one that is gone is left out).
  """
  @spec tools_support_of([String.t()]) :: %{String.t() => support()}
  def tools_support_of(uuids) when is_list(uuids) do
    from(e in Endpoint, where: e.uuid in ^Enum.uniq(uuids))
    |> RepoHelper.repo().all()
    |> tools_support()
  end

  @doc """
  `image_input_support/1` for the endpoints with these uuids, read again from
  the database (one that is gone is left out).
  """
  @spec image_input_support_of([String.t()]) :: %{String.t() => support()}
  def image_input_support_of(uuids) when is_list(uuids) do
    from(e in Endpoint, where: e.uuid in ^Enum.uniq(uuids))
    |> RepoHelper.repo().all()
    |> image_input_support()
  end

  @doc "Whether each endpoint's model takes tools (see the moduledoc): `%{endpoint_uuid => support}`."
  @spec tools_support([Endpoint.t()]) :: %{String.t() => support()}
  def tools_support(endpoints), do: capability(endpoints, :tools)

  @doc """
  Whether each endpoint's model takes images as input (see the moduledoc):
  `%{endpoint_uuid => support}`. A model that can only produce images does not.
  """
  @spec image_input_support([Endpoint.t()]) :: %{String.t() => support()}
  def image_input_support(endpoints), do: capability(endpoints, :vision)

  @doc """
  `image_input_support/1` for the one endpoint with this uuid, read again from
  the database. `:unknown` for no endpoint (`nil`) and for one that does not
  exist.
  """
  @spec image_input(String.t() | nil) :: support()
  def image_input(endpoint_uuid) when is_binary(endpoint_uuid) do
    case PhoenixKitAI.get_endpoint(endpoint_uuid) do
      %Endpoint{} = endpoint ->
        endpoint |> List.wrap() |> image_input_support() |> Map.fetch!(endpoint.uuid)

      _none ->
        :unknown
    end
  end

  def image_input(_none), do: :unknown

  defp capability(endpoints, flag),
    do: Map.new(endpoints, &{&1.uuid, &1 |> Capabilities.for_endpoint() |> support(flag)})

  defp support(%Capabilities{} = caps, flag) do
    case Map.fetch!(caps, flag) do
      :yes -> :supported
      :no -> :unsupported
      :unknown -> :unknown
    end
  end

  defp support(:unknown, _flag), do: :unknown

  @doc """
  Whether a call on the endpoint gets what it cost in the AI journal, as
  `phoenix_kit_ai` prices it. On an endpoint where it does not, money is not
  counted and only the turn limit applies.

    * `:chat` (a model call of a turn) — `PhoenixKitAI.reports_cost?/1`: the
      provider reports the cost (OpenRouter), or the operator's catalogue, a
      manual price on the endpoint or Anthropic's list price prices its model.
    * `:vision` (a picture described, `PhoenixKitAI.describe_image/3`) —
      `PhoenixKitAI.TaskLimits.money_counted?/2` with `:vision`, which is the
      chat rule: `phoenix_kit_ai` prices a description like a chat call (the
      provider's cost, a catalogue, a manual or a list price).

  A `t:summary/0` carries the answer for `:chat`.
  """
  @spec reports_cost?(Endpoint.t() | summary() | nil, call_kind()) :: boolean()
  def reports_cost?(endpoint, call \\ :chat)

  def reports_cost?(%Endpoint{} = endpoint, :chat), do: PhoenixKitAI.reports_cost?(endpoint)

  def reports_cost?(%Endpoint{} = endpoint, :vision),
    do: TaskLimits.money_counted?(endpoint, [:vision])

  def reports_cost?(%{reports_cost?: reports?}, :chat) when is_boolean(reports?), do: reports?

  def reports_cost?(_endpoint, _call), do: false

  # ── internals ─────────────────────────────────────────────────────────

  defp add_current(endpoints, uuids) do
    Enum.reduce(uuids, endpoints, fn
      uuid, acc when is_binary(uuid) ->
        cond do
          Enum.any?(acc, &(&1.uuid == uuid)) -> acc
          current = PhoenixKitAI.get_endpoint(uuid) -> [current | acc]
          true -> acc
        end

      _none, acc ->
        acc
    end)
  end
end
