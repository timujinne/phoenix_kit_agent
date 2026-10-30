defmodule PhoenixKitAgent.Test.Tools do
  @moduledoc """
  A stand-in feature module with admin API tools, for the turn tests: the tools
  a session sees through `PhoenixKit.API.Executor.visible_for/3` and calls
  through `execute_as/5`.

  | Tool | Kind | Scope | Permission |
  |---|---|---|---|
  | `agenttest.list_items` | read | `agenttest.items:read` | `dashboard` |
  | `agenttest.secret_items` | read | `agenttest.secret:read` | `users` |
  | `agenttest.write_item` | write | `agenttest.items:write` | `dashboard` |

  Every handler sends `{:agent_test_tool, name, input, ctx}` to the process in
  `Application.get_env(:phoenix_kit_agent, :test_tool_listener)`, and then
  calls the function in `:test_tool_hook`, if one is set, with the tool's name
  and input — in the process that runs the tool (the turn's task).
  `agenttest.list_items` with `"size" => n` answers about `n` characters, and
  with `"say" => text` answers `text` as its only item.

  `agenttest.write_item` is a write as a module ships one: a dry run (what
  core asks for before a person confirms) writes nothing and answers the
  preview in the common shape (`rows` / `changes` / `totals`) with the
  fingerprint of the setting `agenttest_written`, and sends
  `{:agent_test_preview, input}` instead of the message above; the real run
  sets `agenttest_written` to the `"name"` of the input. Changing the setting
  in between is "the data changed under the preview". While the setting
  `agenttest_locked` is `"yes"` a dry run is refused (as a handler refuses
  what it may not do now, the item being edited by someone else); a real run
  of the name `"fail"` fails, after the confirmation is spent; one of the name
  `"batch"` answers with a `summary` of `ok: 7, failed: 3` (and a free-text
  `note`).
  """

  alias PhoenixKit.API.Tool

  @read %{read_only: true, destructive: false, idempotent: true, open_world: false}
  @write %{read_only: false, destructive: false, idempotent: false, open_world: false}

  def module_key, do: "agent_test_tools"
  def module_name, do: "Agent test tools"
  def enabled?, do: true

  def api_tools do
    [
      tool(:list_items, "agenttest.items:read", "dashboard", @read, %{
        "query" => %{"type" => "string"},
        "size" => %{"type" => "integer", "minimum" => 0},
        "say" => %{"type" => "string"}
      }),
      tool(:secret_items, "agenttest.secret:read", "users", @read, %{}),
      tool(:write_item, "agenttest.items:write", "dashboard", @write, %{
        "name" => %{"type" => "string"}
      })
    ]
  end

  def list_items(input, ctx) do
    notify("agenttest.list_items", input, ctx)

    case input do
      %{"size" => size} -> {:ok, %{"items" => [String.duplicate("x", size)]}}
      %{"say" => text} -> {:ok, %{"items" => [text]}}
      _ -> {:ok, %{"items" => ["chair", "table", "lamp"], "query" => input["query"]}}
    end
  end

  def secret_items(input, ctx) do
    notify("agenttest.secret_items", input, ctx)
    {:ok, %{"items" => ["secret"]}}
  end

  def write_item(input, %{dry_run?: true}) do
    if PhoenixKit.Settings.get_setting("agenttest_locked") == "yes",
      do: {:error, :conflict, "The item is being edited by someone else.", %{}},
      else: preview_item(input)
  end

  def write_item(input, ctx) do
    notify("agenttest.write_item", input, ctx)

    case input do
      %{"name" => "fail"} ->
        {:error, :conflict, "The item could not be written.", %{}}

      %{"name" => "batch"} ->
        {:ok, _} = PhoenixKit.Settings.update_setting("agenttest_written", "batch")

        {:ok,
         %{
           "written" => true,
           "summary" => %{"ok" => 7, "failed" => 3, "note" => "FREE-TEXT-MARKER"}
         }}

      _ ->
        {:ok, _} = PhoenixKit.Settings.update_setting("agenttest_written", input["name"] || "yes")
        {:ok, %{"written" => true}}
    end
  end

  defp preview_item(input) do
    listener = Application.get_env(:phoenix_kit_agent, :test_tool_listener)
    if is_pid(listener), do: send(listener, {:agent_test_preview, input})

    written = PhoenixKit.Settings.get_setting("agenttest_written")

    preview = %{
      "rows" => [
        %{
          "ref" => "item",
          "action" => "update",
          "changes" => %{"name" => %{"from" => written, "to" => input["name"]}}
        }
      ],
      "totals" => %{"rows" => 1, "update" => 1}
    }

    {:preview, preview, fingerprint(written)}
  end

  defp fingerprint(value),
    do: :crypto.hash(:sha256, inspect(value)) |> Base.encode16(case: :lower)

  defp notify(name, input, ctx) do
    case Application.get_env(:phoenix_kit_agent, :test_tool_listener) do
      pid when is_pid(pid) -> send(pid, {:agent_test_tool, name, input, ctx})
      _ -> :ok
    end

    case Application.get_env(:phoenix_kit_agent, :test_tool_hook) do
      hook when is_function(hook, 2) -> hook.(name, input)
      _ -> :ok
    end
  end

  defp tool(verb, scope, permission, annotations, properties) do
    Tool.new!(
      name: "agenttest.#{verb}",
      audience: :admin,
      scope: scope,
      permission: permission,
      title: Atom.to_string(verb),
      description: "Test tool #{verb}.",
      input_schema: %{
        "type" => "object",
        "properties" => properties,
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object"},
      handler: {__MODULE__, verb},
      annotations: annotations
    )
  end
end
