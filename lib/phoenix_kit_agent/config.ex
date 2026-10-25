defmodule PhoenixKitAgent.Config do
  @moduledoc """
  The module settings (`phoenix_kit_settings`, keys `agent_*`) and their
  defaults. A per-user value (`PhoenixKitAgent.Schemas.UserSettings`) wins over
  these; these win over the built-in defaults below.

  | Key | Default |
  |---|---|
  | `agent_enabled` | `false` (see `PhoenixKitAgent.enabled?/0`) |
  | `agent_default_endpoint_uuid` | none — the AI endpoint the assistant uses |
  | `agent_vision_endpoint_uuid` | none — describes images for a model without image input |
  | `agent_system_prompt` | none — the module's system prompt (JSON `{"text": …}`) |
  | `agent_daily_cost_limit_micro_usd` | `1_000_000` ($1) |
  | `agent_monthly_cost_limit_micro_usd` | `10_000_000` ($10) |
  | `agent_daily_turn_limit` | `200` |
  | `agent_max_attachment_mb` | `20` |
  | `agent_max_attachments_per_message` | `5` |
  | `agent_limit_watchers` | none — JSON `{"uuids": […]}` of user uuids; none = every Owner |
  | `agent_max_tool_rounds` | `8` |
  | `agent_turn_deadline_s` | `300` |
  | `agent_history_chars` | `24_000` |
  | `agent_tool_result_chars` | `12_000` |
  | `agent_capture_ai_content` | `false` |

  Money is in micro-dollars ($1 = 1_000_000); the AI journal keeps dollars
  (`phoenix_kit_ai_requests.cost`), read through `cost_to_micro/1`. A stored
  value that is not a whole number, or is outside its range (below), reads as
  the default. A limit of `0` is a real limit (nothing allowed); a technical
  value must be positive.

  Core keeps a string setting to 1000 characters, so the two settings that can
  be longer — the module prompt and the watchers — are JSON settings
  (`value_json`), written by `put_system_prompt/2` and `put_limit_watchers/2`.
  The two models are written by `put_default_endpoint/2` and
  `put_vision_endpoint/2`, which take only an AI endpoint that chats and fits
  its AI task (`agent.chat`, `agent.attachment`).

  Every writer records the change with who made it (`actor_uuid:` in `opts`)
  in the core Activity log: through the settings history (`setting.changed`,
  with the values before and after) — except the module prompt, whose text
  must not be kept there (nor in the query log that history's write goes
  to): it is written without that history, and its change is recorded as
  `agent.settings_updated` with the field name only.

  `agent_capture_ai_content` is on only when it reads exactly `"true"`: then the
  bodies of the assistant's model calls are written to the AI request journal,
  where every holder of the `ai` permission reads them. Only an Owner may switch
  it: `put_capture_ai_content/2` does not check that, its caller (the Settings
  page, `PhoenixKitAgent.Web.SettingsLive`) does.
  """

  import Ecto.Changeset

  alias PhoenixKit.Activity
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.History
  alias PhoenixKit.Utils.Number
  alias PhoenixKitAgent.Schemas.Message
  alias PhoenixKitAI.Endpoint

  @module "agent"
  @micro_per_usd 1_000_000

  # {field, setting key, default, min, max}
  @limits [
    {:daily_cost_limit_micro_usd, "agent_daily_cost_limit_micro_usd", 1_000_000, 0,
     1_000_000_000_000},
    {:monthly_cost_limit_micro_usd, "agent_monthly_cost_limit_micro_usd", 10_000_000, 0,
     1_000_000_000_000},
    {:daily_turn_limit, "agent_daily_turn_limit", 200, 0, 100_000},
    {:max_attachment_mb, "agent_max_attachment_mb", 20, 0, 1_024},
    {:max_attachments_per_message, "agent_max_attachments_per_message", 5, 0, 50}
  ]

  @technical [
    {:max_tool_rounds, "agent_max_tool_rounds", 8, 1, 50},
    {:turn_deadline_s, "agent_turn_deadline_s", 300, 10, 3_600},
    {:history_chars, "agent_history_chars", 24_000, 1_000, 1_000_000},
    {:tool_result_chars, "agent_tool_result_chars", 12_000, 500, 1_000_000}
  ]

  @money_fields %{
    daily_cost_limit_usd: :daily_cost_limit_micro_usd,
    monthly_cost_limit_usd: :monthly_cost_limit_micro_usd
  }

  @watchers_key "agent_limit_watchers"
  @prompt_key "agent_system_prompt"

  # The longest module prompt, in characters.
  @prompt_max 16_000

  @typedoc "Why `put_default_endpoint/2` or `put_vision_endpoint/2` wrote nothing."
  @type endpoint_refusal ::
          :invalid_endpoint | {:model_unfit | :model_unverified, [atom()]}

  # ── Readers ───────────────────────────────────────────────────────────

  @doc "The module's default per-user limits."
  @spec limit_defaults() :: %{atom() => non_neg_integer()}
  def limit_defaults, do: Map.new(@limits, fn spec -> {elem(spec, 0), read(spec)} end)

  @doc "Most model ↔ tool rounds in one turn."
  @spec max_tool_rounds() :: pos_integer()
  def max_tool_rounds, do: technical(:max_tool_rounds)

  @doc "Deadline of a whole turn, in seconds."
  @spec turn_deadline_s() :: pos_integer()
  def turn_deadline_s, do: technical(:turn_deadline_s)

  @doc "How many characters of earlier messages go into the model's context."
  @spec history_chars() :: pos_integer()
  def history_chars, do: technical(:history_chars)

  @doc "How many characters of one tool result go to the model (and are kept)."
  @spec tool_result_chars() :: pos_integer()
  def tool_result_chars, do: technical(:tool_result_chars)

  @doc "The AI endpoint the assistant uses by default, or `nil`."
  @spec default_endpoint_uuid() :: String.t() | nil
  def default_endpoint_uuid, do: uuid_setting("agent_default_endpoint_uuid")

  @doc "The AI endpoint that describes images for a model without image input, or `nil`."
  @spec vision_endpoint_uuid() :: String.t() | nil
  def vision_endpoint_uuid, do: uuid_setting("agent_vision_endpoint_uuid")

  @doc "The module's system prompt, or `nil`."
  @spec system_prompt() :: String.t() | nil
  def system_prompt do
    case json_setting(@prompt_key) do
      %{"text" => prompt} when is_binary(prompt) ->
        if String.trim(prompt) == "", do: nil, else: prompt

      _none ->
        nil
    end
  end

  @doc """
  The users told when someone hits a limit (`agent_limit_watchers`). Empty means
  every Owner; who those are is decided where the notice is sent.
  """
  @spec limit_watchers() :: [String.t()]
  def limit_watchers, do: @watchers_key |> json_setting() |> watcher_uuids()

  @doc "Whether the bodies of the assistant's model calls go to the AI journal."
  @spec capture_ai_content?() :: boolean()
  def capture_ai_content? do
    string_setting("agent_capture_ai_content") == "true"
  end

  # ── Writers ───────────────────────────────────────────────────────────

  @doc """
  Sets the module's system prompt (`agent_system_prompt`); a blank one means
  none. NUL characters are cut (the database refuses them); a prompt over
  #{@prompt_max} characters is `{:error, changeset}` and nothing is written —
  it goes into every request. A change is recorded in the Activity log as
  `agent.settings_updated` by `actor_uuid:` (in `opts`), with the field name
  and never the text (see the moduledoc). The caller checks `agent.manage`.
  """
  @spec put_system_prompt(String.t() | nil, keyword()) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()}
  def put_system_prompt(prompt, opts) when is_binary(prompt) or is_nil(prompt) do
    changeset =
      {%{}, %{text: :string}}
      |> cast(%{text: Message.strip_nul(prompt || "")}, [:text], empty_values: [])
      |> validate_length(:text, max: @prompt_max)

    if changeset.valid? do
      text = get_field(changeset, :text) || ""
      changed? = stored_prompt() != text

      # `history: false`: the settings history would keep the text, and log it.
      with {:ok, setting} <-
             Settings.update_json_setting_with_module(
               @prompt_key,
               %{"text" => text},
               @module,
               history: false
             ) do
        if changed?, do: log_change(["system_prompt"], opts)
        {:ok, setting}
      end
    else
      {:error, %{changeset | action: :update}}
    end
  end

  @doc """
  Sets the AI endpoint the assistant uses by default
  (`agent_default_endpoint_uuid`), or none (`nil`). Only an existing endpoint
  that chats is taken; anything else is `{:error, :invalid_endpoint}` and
  nothing is written. A newly chosen endpoint must fit the `agent.chat` AI
  task (`PhoenixKitAI.Tasks.check_selection/2`): one whose model is known not
  to take tools is `{:error, {:model_unfit, missing}}`, one nobody knows
  takes them `{:error, {:model_unverified, unclear}}`, and nothing is
  written; the endpoint already set is not checked again. `opts` go to
  `PhoenixKit.Settings` (`actor_uuid:`, `source:`). The caller checks
  `agent.manage`.
  """
  @spec put_default_endpoint(String.t() | nil, keyword()) ::
          {:ok, term()} | {:error, endpoint_refusal() | Ecto.Changeset.t()}
  def put_default_endpoint(uuid, opts),
    do: put_endpoint("agent_default_endpoint_uuid", "agent.chat", uuid, opts)

  @doc """
  Sets the AI endpoint that describes pictures for a model that does not see
  them (`agent_vision_endpoint_uuid`), or none (`nil`); as
  `put_default_endpoint/2`, against the `agent.attachment` AI task (its model
  must take pictures).
  """
  @spec put_vision_endpoint(String.t() | nil, keyword()) ::
          {:ok, term()} | {:error, endpoint_refusal() | Ecto.Changeset.t()}
  def put_vision_endpoint(uuid, opts),
    do: put_endpoint("agent_vision_endpoint_uuid", "agent.attachment", uuid, opts)

  defp put_endpoint(key, _task, nil, opts),
    do: Settings.update_setting_with_module(key, "", @module, opts)

  defp put_endpoint(key, task, uuid, opts) when is_binary(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Endpoint{} = endpoint <- PhoenixKitAI.get_endpoint(uuid),
         :chat <- Endpoint.kind(endpoint),
         :ok <- fits(key, task, endpoint) do
      Settings.update_setting_with_module(key, uuid, @module, opts)
    else
      {:error, {reason, _needs}} = refusal when reason in [:model_unfit, :model_unverified] ->
        refusal

      _not_a_chat_endpoint ->
        {:error, :invalid_endpoint}
    end
  end

  defp put_endpoint(_key, _task, _other, _opts), do: {:error, :invalid_endpoint}

  # The endpoint already set is not checked again.
  defp fits(key, task, endpoint) do
    if uuid_setting(key) == endpoint.uuid,
      do: :ok,
      else: PhoenixKitAI.Tasks.check_selection(task, endpoint)
  end

  defp stored_prompt do
    case json_setting(@prompt_key) do
      %{"text" => text} when is_binary(text) -> text
      _none -> ""
    end
  end

  defp log_change(fields, opts) do
    Activity.log(@module, "agent.settings_updated",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "agent_settings",
      metadata: %{"fields" => fields}
    )

    :ok
  end

  @doc """
  Switches `agent_capture_ai_content`. `opts` go to `PhoenixKit.Settings`
  (`actor_uuid:`, `source:`). The caller checks that the person is an Owner.
  """
  @spec put_capture_ai_content(boolean(), keyword()) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()}
  def put_capture_ai_content(value, opts) when is_boolean(value) do
    Settings.update_boolean_setting_with_module("agent_capture_ai_content", value, @module, opts)
  end

  @doc """
  Sets who is told when someone hits a limit (`agent_limit_watchers`): user
  uuids, repeats dropped; an empty list means every Owner. Anything that is
  not a uuid is `{:error, :invalid_uuid}` and nothing is written. The caller
  checks `agent.manage`.
  """
  @spec put_limit_watchers([String.t()], keyword()) ::
          {:ok, term()} | {:error, :invalid_uuid | Ecto.Changeset.t()}
  def put_limit_watchers(uuids, opts) when is_list(uuids) do
    cast = Enum.map(uuids, &Ecto.UUID.cast/1)

    if Enum.all?(cast, &match?({:ok, _}, &1)) do
      list = cast |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      Settings.update_json_setting_with_module(@watchers_key, %{"uuids" => list}, @module, opts)
    else
      {:error, :invalid_uuid}
    end
  end

  @doc """
  Takes `user_uuid` out of `agent_limit_watchers`, under the setting's row lock
  (a concurrent change of the list is not lost). `{:ok, :unchanged}` when it was
  not in the list.
  """
  @spec remove_limit_watcher(String.t()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
  def remove_limit_watcher(user_uuid) when is_binary(user_uuid) do
    result =
      RepoHelper.repo().transaction(fn ->
        stored = History.lock_current(@watchers_key)
        uuids = watcher_uuids(stored && stored.value_json)

        if user_uuid in uuids do
          case Settings.update_json_setting_with_module(
                 @watchers_key,
                 %{"uuids" => List.delete(uuids, user_uuid)},
                 @module
               ) do
            {:ok, setting} -> setting
            {:error, changeset} -> RepoHelper.repo().rollback(changeset)
          end
        else
          :unchanged
        end
      end)

    # The write dropped the cached value before this transaction committed; a
    # reader in between could have cached the old list again.
    PhoenixKit.Cache.invalidate_now(:settings, [@watchers_key])
    result
  end

  # ── The defaults form (Settings → AI Agent) ──────────────────────────

  @doc """
  The current defaults as the form shows them: string values, money in dollars.
  """
  @spec defaults_form_values() :: %{String.t() => String.t()}
  def defaults_form_values do
    limits = limit_defaults()

    money =
      Map.new(@money_fields, fn {usd_field, micro_field} ->
        {Atom.to_string(usd_field), micro_to_usd(Map.fetch!(limits, micro_field))}
      end)

    integers =
      for {field, _key, _default, _min, _max} <- form_integer_specs(), into: %{} do
        value = Map.get(limits, field) || technical(field)
        {Atom.to_string(field), Integer.to_string(value)}
      end

    Map.merge(money, integers)
  end

  @doc "Validates the defaults form; see `save_defaults/2`."
  @spec defaults_changeset(map()) :: Ecto.Changeset.t()
  def defaults_changeset(params) do
    types =
      Map.merge(
        Map.new(@money_fields, fn {usd_field, _} -> {usd_field, :string} end),
        Map.new(form_integer_specs(), fn spec -> {elem(spec, 0), :string} end)
      )

    values = defaults_form_values()
    data = Map.new(types, fn {field, _} -> {field, values[Atom.to_string(field)]} end)

    {data, types}
    |> cast(stringify(params), Map.keys(types))
    |> validate_required(Map.keys(types))
    |> validate_money()
    |> validate_integers()
    |> Map.put(:action, :validate)
  end

  @doc """
  Saves the defaults form: dollars become micro-dollars; every value is checked
  against its range and nothing is written unless all are valid. Only values
  that differ from what is in effect are written, so an untouched built-in
  default stays unstored (and follows a later change of the default). They are
  written in one transaction (`PhoenixKit.Settings.update_settings_batch/2`):
  a write the database refuses leaves every setting as it was and is
  `{:error, :not_saved}`. `opts` go to `PhoenixKit.Settings` (`actor_uuid:`,
  `source:`) so the change is in the settings history with who made it.
  """
  @spec save_defaults(map(), keyword()) ::
          {:ok, [String.t()]} | {:error, Ecto.Changeset.t() | :not_saved}
  def save_defaults(params, opts) do
    changeset = defaults_changeset(params)

    if changeset.valid? do
      changeset
      |> to_settings()
      |> Enum.reject(fn {key, value} -> effective_value(key) == value end)
      |> write_all(opts)
    else
      {:error, changeset}
    end
  end

  defp write_all([], _opts), do: {:ok, []}

  defp write_all(settings, opts) do
    case Settings.update_settings_batch(Map.new(settings), opts) do
      {:ok, _written} -> {:ok, Enum.map(settings, &elem(&1, 0))}
      {:error, _step, _value, _changes} -> {:error, :not_saved}
    end
  rescue
    _db_error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :not_saved}
  end

  defp form_integer_specs do
    Enum.reject(@limits, fn spec -> elem(spec, 0) in Map.values(@money_fields) end) ++
      @technical
  end

  defp validate_money(changeset) do
    Enum.reduce(@money_fields, changeset, fn {usd_field, micro_field}, acc ->
      {_, _, _, min, max} = spec_of(micro_field)

      validate_change(acc, usd_field, fn ^usd_field, value ->
        case usd_to_micro(value) do
          {:ok, micro} when micro >= min and micro <= max -> []
          {:ok, _} -> [{usd_field, "is out of range"}]
          {:error, :fraction} -> [{usd_field, "is finer than a millionth of a dollar"}]
          {:error, _} -> [{usd_field, "is not a valid amount"}]
        end
      end)
    end)
  end

  defp validate_integers(changeset) do
    Enum.reduce(form_integer_specs(), changeset, fn {field, _key, _default, min, max}, acc ->
      validate_change(acc, field, fn ^field, value ->
        case whole_number(value) do
          n when is_integer(n) and n >= min and n <= max -> []
          n when is_integer(n) -> [{field, "must be between #{min} and #{max}"}]
          nil -> [{field, "is not a whole number"}]
        end
      end)
    end)
  end

  defp to_settings(changeset) do
    money =
      Enum.map(@money_fields, fn {usd_field, micro_field} ->
        {:ok, micro} = usd_to_micro(get_field(changeset, usd_field))
        {elem(spec_of(micro_field), 1), Integer.to_string(micro)}
      end)

    integers =
      Enum.map(form_integer_specs(), fn {field, key, _default, _min, _max} ->
        {key, Integer.to_string(whole_number(get_field(changeset, field)))}
      end)

    money ++ integers
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp spec_of(field), do: Enum.find(@limits ++ @technical, &(elem(&1, 0) == field))

  defp effective_value(key) do
    @limits
    |> Kernel.++(@technical)
    |> Enum.find(&(elem(&1, 1) == key))
    |> read()
    |> Integer.to_string()
  end

  defp technical(field), do: field |> spec_of() |> read()

  defp read({_field, key, default, min, max}) do
    case key |> string_setting() |> whole_number() do
      n when is_integer(n) and n >= min and n <= max -> n
      _ -> default
    end
  end

  defp string_setting(key) do
    case Settings.get_setting_cached(key, nil) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp json_setting(key) do
    Settings.get_json_setting_cached(key, nil)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp watcher_uuids(%{"uuids" => uuids}) when is_list(uuids) do
    uuids
    |> Enum.flat_map(fn uuid ->
      case Ecto.UUID.cast(uuid) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  defp watcher_uuids(_none), do: []

  defp uuid_setting(key) do
    with value when is_binary(value) <- string_setting(key),
         {:ok, uuid} <- Ecto.UUID.cast(String.trim(value)) do
      uuid
    else
      _ -> nil
    end
  end

  defp whole_number(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp whole_number(_), do: nil

  @doc """
  Dollars typed by a person (`"2,5"`, `"0.05"`) as micro-dollars: `{:ok,
  integer}`, `{:error, :fraction}` when finer than a millionth of a dollar,
  `{:error, reason}` for anything that is not a non-negative amount.
  """
  @spec usd_to_micro(term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def usd_to_micro(value) do
    with {:ok, usd} <- Number.parse_decimal(value, min: 0) do
      micro = Decimal.mult(usd, @micro_per_usd)

      if Decimal.equal?(micro, Decimal.round(micro, 0)),
        do: {:ok, Decimal.to_integer(Decimal.round(micro, 0))},
        else: {:error, :fraction}
    end
  end

  @doc """
  A cost in dollars as the AI journal keeps it (`PhoenixKitAI.Request.cost`,
  a `Decimal`, finer than a micro-dollar at times) as whole micro-dollars,
  rounded half up: `$0.0000025` is `3`. `nil` (no cost known) stays `nil`.
  A sum is rounded once, after it is added up, never row by row.
  """
  @spec cost_to_micro(Decimal.t() | nil) :: non_neg_integer() | nil
  def cost_to_micro(nil), do: nil

  def cost_to_micro(%Decimal{} = usd) do
    usd |> Decimal.mult(@micro_per_usd) |> Decimal.round(0, :half_up) |> Decimal.to_integer()
  end

  @doc "Micro-dollars as dollars for a form field: `1_500_000` is `\"1.5\"`."
  @spec micro_to_usd(non_neg_integer()) :: String.t()
  def micro_to_usd(micro) do
    micro
    |> Decimal.new()
    |> Decimal.div(@micro_per_usd)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp stringify(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {to_string(k), v} end)
  end
end
