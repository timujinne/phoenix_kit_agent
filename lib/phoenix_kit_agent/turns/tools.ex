defmodule PhoenixKitAgent.Turns.Tools do
  @moduledoc """
  How the tools of a round are shown to the model, and how what it sends back
  is taken (spec §6.1 b, f; §6.2, §6.4).

    * The tools are those core lists for the session
      (`PhoenixKit.API.Executor.visible_for/3` with `allow: :all`): the module
      adds no filter of its own and opens nothing beyond them. Whether a
      session sees the write tools of a module is core's setting
      `api_session_write_modules` (the "Agent may act" box of Settings → API),
      and a write never runs on the call: core holds it for the user's
      confirmation (`PhoenixKitAgent.Confirmations`).
    * Names: the model sees `PhoenixKit.API.MCP.Names.to_mcp/1` of the registry
      name (`catalogue.list_products` → `catalogue_list_products`); a name that
      is not 1-64 characters of `[a-zA-Z0-9_-]` (what model APIs accept) is
      left out, and of two tools with one MCP name the first wins
      (`Names.dedupe/1`). `for_model/1` returns the map back from that name to
      the tool, and only a name in it is ever executed.
    * Schemas: `PhoenixKit.API.Executor.input_schema/1` without the control
      fields (`PhoenixKit.API.ControlFields`: `dry_run`, `confirm_token`,
      `idempotency_key`) — the model neither sees nor sets them; they are cut
      from its arguments too (`arguments/1`).
    * Results: the JSON of a result longer than `agent_tool_result_chars` is
      replaced by `%{"truncated" => true, "partial" => <its beginning>, "hint"
      => …}` whose own JSON fits the limit (`fit/2`). The same value is kept in
      the database.
  """

  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.MCP.Names
  alias PhoenixKit.API.Tool

  @model_name ~r/\A[a-zA-Z0-9_-]{1,64}\z/

  @hint "The result was cut to fit. Narrow the request (filters, a smaller limit) to see the rest."

  @doc """
  The tool definitions for the model (OpenAI function tools) and the map from
  each model name to its tool.
  """
  @spec for_model([Tool.t()]) :: {[map()], %{String.t() => Tool.t()}}
  def for_model(tools) when is_list(tools) do
    by_name =
      tools
      |> Names.dedupe()
      |> Enum.map(&{Names.to_mcp(&1.name), &1})
      |> Enum.filter(fn {name, _tool} -> Regex.match?(@model_name, name) end)

    definitions =
      Enum.map(by_name, fn {name, tool} ->
        %{
          "type" => "function",
          "function" => %{
            "name" => name,
            "description" => description(tool),
            "parameters" => parameters(tool)
          }
        }
      end)

    {definitions, Map.new(by_name)}
  end

  @doc """
  The arguments of a tool call as the executor's input: the JSON object the
  model sent, without control fields. `:error` for anything that is not a
  JSON object.
  """
  @spec arguments(term()) :: {:ok, map()} | :error
  def arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> arguments(decoded)
      {:error, _} -> :error
    end
  end

  def arguments(arguments) when is_map(arguments),
    do: {:ok, Map.drop(arguments, ControlFields.names())}

  def arguments(_other), do: :error

  @doc """
  The uuid of the confirmation a write's answer says it waits for — core's
  prompt for a live session (`"executed": false`, `"status":
  "confirmation_required"`, `"confirmation_id"`) — else `:error`.
  """
  @spec held(term()) :: {:ok, String.t()} | :error
  def held(%{"executed" => false, "status" => "confirmation_required", "confirmation_id" => uuid})
      when is_binary(uuid),
      do: {:ok, uuid}

  def held(_result), do: :error

  @doc """
  What is kept of a write that waits for confirmation `uuid`, and sent back to
  the model: the status and the uuid, never a code, the preview or the
  arguments.
  """
  @spec held_result(String.t()) :: map()
  def held_result(uuid) when is_binary(uuid),
    do: %{"status" => "confirmation_required", "confirmation_id" => uuid}

  @doc """
  `result` as it is kept and sent to the model: itself when its JSON is at
  most `limit` characters, else the truncated form (see the moduledoc).
  """
  @spec fit(map(), pos_integer()) :: map()
  def fit(result, limit) when is_map(result) and is_integer(limit) and limit > 0 do
    json = Jason.encode!(result)

    if String.length(json) <= limit, do: result, else: cut(json, limit, limit)
  end

  # Each removed character of `partial` shortens the encoded form by at least
  # one character, so one correction by the excess is enough.
  defp cut(json, limit, keep) do
    truncated = %{"truncated" => true, "partial" => String.slice(json, 0, keep), "hint" => @hint}
    excess = String.length(Jason.encode!(truncated)) - limit

    if excess <= 0 or keep == 0,
      do: truncated,
      else: cut(json, limit, max(keep - excess, 0))
  end

  defp description(%Tool{description: description, title: title}) do
    case description do
      text when is_binary(text) and text != "" -> text
      _ -> title || ""
    end
  end

  defp parameters(tool) do
    control = ControlFields.names()
    schema = Executor.input_schema(tool)

    schema
    |> Map.update("properties", %{}, &Map.drop(&1, control))
    |> then(fn schema ->
      case schema do
        %{"required" => required} when is_list(required) ->
          Map.put(schema, "required", required -- control)

        _ ->
          schema
      end
    end)
  end
end
