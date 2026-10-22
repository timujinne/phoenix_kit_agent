defmodule PhoenixKitAgent.Models do
  @moduledoc """
  The choice of a model for a user (spec §7.2). The module has no models of its
  own: the choice is among the endpoints of `phoenix_kit_ai` (an endpoint is a
  connection plus a model), and only endpoints that can chat.

  `list_endpoints/1` is the choice; `tools_support/1` says, per endpoint,
  whether its model takes tools — the assistant is useless on one that does
  not, so the screen marks those:

    * `:supported` / `:unsupported` — OpenRouter publishes the parameters of
      each model, and `phoenix_kit_ai` maps Anthropic's model listing onto the
      same fields; `OpenRouterClient.model_supports_parameter?(model, "tools")`
      answers. One listing is fetched per connection (API key and base URL),
      however many endpoints use it;
    * `:unknown` — every other provider (`phoenix_kit_ai` has no capability
      listing for them), a model the listing does not name, and a listing that
      could not be fetched.

  `image_input_support/1` is the same question about images, from the model's
  declared input modalities; the attachments (spec §9) use it to decide whether
  a picture goes to the model as pixels or as a description.

  `tools_support/1` and `image_input_support/1` make network requests: call them
  off the LiveView process.

  `reports_cost?/1` says whether an endpoint's answers carry what the call
  cost — the money limits count only such calls (spec §7.3).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.Models.Cache
  alias PhoenixKitAI.{Endpoint, OpenRouterClient}

  @typedoc "Whether a model takes tools."
  @type support :: :supported | :unsupported | :unknown

  @typedoc """
  What a page shows of an endpoint: never the endpoint itself, which carries
  its API key.
  """
  @type summary :: %{uuid: String.t(), name: String.t(), model: String.t(), provider: String.t()}

  @page_size 500

  # How long the answer of `image_input/1` is kept: a model's abilities do not
  # change by the minute; a listing that could not be fetched ("unknown") is
  # asked again sooner.
  @known_ttl_ms 300_000
  @unknown_ttl_ms 30_000

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
      provider: endpoint.provider
    }

  @doc "The endpoints with these uuids as `t:summary/0`: `%{uuid => summary}`."
  @spec summaries([String.t()]) :: %{String.t() => summary()}
  def summaries(uuids) when is_list(uuids) do
    from(e in Endpoint,
      where: e.uuid in ^Enum.uniq(uuids),
      select: {e.uuid, %{uuid: e.uuid, name: e.name, model: e.model, provider: e.provider}}
    )
    |> RepoHelper.repo().all()
    |> Map.new()
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
  def tools_support(endpoints), do: capability(endpoints, &takes_tools?/1)

  @doc """
  Whether each endpoint's model takes images as input (see the moduledoc):
  `%{endpoint_uuid => support}`. A model that can only produce images does not.
  """
  @spec image_input_support([Endpoint.t()]) :: %{String.t() => support()}
  def image_input_support(endpoints), do: capability(endpoints, &takes_images?/1)

  @doc """
  `image_input_support/1` for the one endpoint with this uuid. `:unknown` for
  no endpoint (`nil`) and for one that does not exist. Asked for every picture,
  so the answer is kept for a few minutes (`clear_cache/0` forgets it).
  """
  @spec image_input(String.t() | nil) :: support()
  def image_input(endpoint_uuid) when is_binary(endpoint_uuid) do
    case PhoenixKitAI.get_endpoint(endpoint_uuid) do
      %Endpoint{} = endpoint ->
        Cache.fetch(
          cache_key(endpoint),
          &ttl/1,
          fn -> endpoint |> List.wrap() |> image_input_support() |> Map.fetch!(endpoint.uuid) end
        )

      _none ->
        :unknown
    end
  end

  def image_input(_none), do: :unknown

  @doc "Forgets the answers `image_input/1` has kept."
  @spec clear_cache() :: :ok
  defdelegate clear_cache, to: Cache, as: :clear

  # What the answer depends on: the model and the connection it is listed
  # through. Read from the endpoint's own row, so that the key is made without
  # resolving the API key (a settings or integrations lookup) for each call.
  defp cache_key(endpoint) do
    {:image_input, endpoint.uuid, endpoint.model, endpoint.provider, endpoint.integration_uuid,
     endpoint.base_url, endpoint.updated_at}
  end

  defp ttl(:unknown), do: @unknown_ttl_ms
  defp ttl(_known), do: @known_ttl_ms

  defp capability(endpoints, check) do
    {listed, others} = Enum.split_with(endpoints, &lists_capabilities?/1)

    unknown = Map.new(others, &{&1.uuid, :unknown})

    listed
    |> Enum.group_by(&connection/1)
    |> Enum.reduce(unknown, fn {connection, group}, acc ->
      Map.merge(acc, group_support(connection, group, check))
    end)
  end

  @doc """
  Whether calls on the endpoint report their cost to the AI journal:
  OpenRouter answers with one (`usage.cost`), and `phoenix_kit_ai` prices an
  Anthropic call from its rate table (`PhoenixKitAI.AnthropicPricing`, where
  the installed version has it) when the model is in it. On an endpoint that
  does not, money is not counted and only the turn limit applies.
  """
  @spec reports_cost?(Endpoint.t() | %{provider: term()} | nil) :: boolean()
  def reports_cost?(%{provider: provider} = endpoint) when is_binary(provider) do
    case Endpoint.base_provider(provider) do
      "openrouter" -> true
      "anthropic" -> anthropic_priced?(endpoint)
      _other -> false
    end
  end

  def reports_cost?(_endpoint), do: false

  # ── internals ─────────────────────────────────────────────────────────

  @anthropic_pricing PhoenixKitAI.AnthropicPricing

  # Called through `apply/3`: an older `phoenix_kit_ai` has no rate table, and
  # then an Anthropic call is logged without a cost.
  defp anthropic_priced?(%{model: model}) when is_binary(model) do
    Code.ensure_loaded?(@anthropic_pricing) and
      function_exported?(@anthropic_pricing, :per_token, 1) and
      apply(@anthropic_pricing, :per_token, [model]) != nil
  end

  defp anthropic_priced?(_endpoint), do: false

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

  # The providers whose model listing says what a model takes: OpenRouter's
  # `supported_parameters` and input modalities, and Anthropic's own
  # `/models`, which `phoenix_kit_ai` maps onto the same fields.
  @listing_providers ~w(openrouter anthropic)

  defp lists_capabilities?(%Endpoint{provider: provider}) when is_binary(provider),
    do: Endpoint.base_provider(provider) in @listing_providers

  defp lists_capabilities?(_endpoint), do: false

  defp connection(endpoint) do
    {OpenRouterClient.resolve_api_key(endpoint), blank_to_nil(endpoint.base_url)}
  rescue
    _ -> :unresolved
  end

  defp group_support(connection, group, check) do
    case models(connection) do
      {:ok, models} ->
        Map.new(group, fn endpoint -> {endpoint.uuid, support(models, endpoint.model, check)} end)

      :error ->
        Map.new(group, &{&1.uuid, :unknown})
    end
  end

  defp models({api_key, base_url}) when is_binary(api_key) and api_key != "" do
    opts = if base_url, do: [base_url: base_url], else: []

    case OpenRouterClient.fetch_models(api_key, opts) do
      {:ok, models} -> {:ok, Map.new(models, &{&1.id, &1})}
      _failed -> :error
    end
  rescue
    # No part of the request goes to a log: a failed listing is "unknown".
    _ -> :error
  catch
    _kind, _reason -> :error
  end

  defp models(_no_key), do: :error

  defp support(models, model_id, check) do
    case Map.fetch(models, model_id) do
      {:ok, model} -> verdict(check.(model))
      :error -> :unknown
    end
  end

  defp verdict(true), do: :supported
  defp verdict(false), do: :unsupported
  defp verdict(:unknown), do: :unknown

  defp takes_tools?(model), do: OpenRouterClient.model_supports_parameter?(model, "tools")

  # OpenRouter lists `input_modalities`; the older `modality` ("text+image->text")
  # is the fallback. Only the input side counts. A model that declares neither
  # is not known not to see.
  defp takes_images?(%{architecture: architecture}) when is_map(architecture) do
    case {architecture["input_modalities"], architecture["modality"]} do
      {inputs, _modality} when is_list(inputs) ->
        "image" in inputs

      {_none, modality} when is_binary(modality) ->
        modality |> String.split("->") |> hd() |> String.contains?("image")

      _unknown_shape ->
        :unknown
    end
  end

  defp takes_images?(_model), do: :unknown

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_none), do: nil
end
