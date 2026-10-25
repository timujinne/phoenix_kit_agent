defmodule PhoenixKitAgent.Schemas.Message do
  @moduledoc """
  One message of a chat (`phoenix_kit_agent_messages`): what the user wrote, a
  model answer (with the tool calls it asked for), a tool result, or a notice
  (a limit, an error, a refusal). The table is also the assistant's journal of
  tool calls: who, what, when, and the outcome.

  `conversation_uuid`, `ai_request_uuid`, `assistant_message_uuid` and
  `confirmation_uuid` are set by the caller, never cast. `tool_name` is the
  registry name of the tool, not the name shown to the model; `tool_result` is
  the truncated result, without confirmation tokens or other control fields.

  A write the user is asked to confirm (V2 of the migrations) is a `tool`
  message with `tool_outcome: "needs_confirmation"`, the uuid of core's
  confirmation in `confirmation_uuid` and the `assistant` message whose tool
  call it answers in `assistant_message_uuid`; how it ended is a `notice` with
  the same `confirmation_uuid` and its outcome (`confirmed`, `rejected`,
  `expired`, `changed`, `failed`). One without such a notice is still waiting.

  `changeset/2` is the full set of fields, for the turn loop
  (`PhoenixKitAgent.Turns`) only; `user_changeset/2` is what a person writes —
  the text of a `user` message and nothing else. Both cut NUL characters from
  every text they keep (PostgreSQL refuses them in `text` and `jsonb`).

  `tool_summary` is virtual: the read functions of
  `PhoenixKitAgent.Conversations` fill it for a `tool` message in place of
  the result (see there). So is `card`: the chat panel puts there what it
  shows of a confirmation (`PhoenixKitAgent.Confirmations.cards/4`).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @roles ~w(user assistant tool notice)
  @tool_outcomes ~w(ok error denied needs_confirmation confirmed rejected expired changed failed)

  # The largest values of the `integer` and `bigint` columns.
  @int4_max 2_147_483_647
  @int8_max 9_223_372_036_854_775_807

  @text_fields ~w(turn_ref role content tool_call_id tool_name tool_outcome model error)a
  @json_fields ~w(tool_calls tool_result)a

  @type t :: %__MODULE__{}

  schema "phoenix_kit_agent_messages" do
    field(:turn_ref, :string)
    field(:role, :string)
    field(:content, :string)
    field(:tool_calls, {:array, :map})
    field(:tool_call_id, :string)
    field(:tool_name, :string)
    field(:tool_outcome, :string)
    field(:tool_result, :map)
    field(:model, :string)
    field(:input_tokens, :integer)
    field(:output_tokens, :integer)
    field(:cost_micro_usd, :integer)
    field(:latency_ms, :integer)
    field(:error, :string)

    belongs_to(:conversation, PhoenixKitAgent.Schemas.Conversation,
      foreign_key: :conversation_uuid,
      references: :uuid
    )

    field(:ai_request_uuid, UUIDv7)
    field(:assistant_message_uuid, UUIDv7)
    field(:confirmation_uuid, UUIDv7)
    field(:tool_summary, :map, virtual: true)
    field(:card, :map, virtual: true)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The message roles: `user`, `assistant`, `tool`, `notice`."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "The outcomes of a tool call."
  @spec tool_outcomes() :: [String.t()]
  def tool_outcomes, do: @tool_outcomes

  @doc """
  Builds a message from all its content fields — for the turn loop only, never
  from what a client sent.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(
      attrs,
      @text_fields ++
        @json_fields ++ [:input_tokens, :output_tokens, :cost_micro_usd, :latency_ms]
    )
    |> strip_nul_changes()
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:tool_outcome, @tool_outcomes)
    |> validate_number(:input_tokens,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @int4_max
    )
    |> validate_number(:output_tokens,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @int4_max
    )
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0, less_than_or_equal_to: @int4_max)
    |> validate_number(:cost_micro_usd,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @int8_max
    )
    |> key_constraints()
  end

  @doc """
  A message the user writes: role `user` and the non-blank `content`; every
  other attribute is ignored.
  """
  @spec user_changeset(t(), map()) :: Ecto.Changeset.t()
  def user_changeset(message, attrs) do
    message
    |> cast(attrs, [:content])
    |> put_change(:role, "user")
    |> strip_nul_changes()
    |> validate_required([:content])
    |> key_constraints()
  end

  @doc false
  # `value` without NUL characters: a string, or every string (keys
  # included) inside a list or map.
  @spec strip_nul(term()) :: term()
  def strip_nul(value) when is_binary(value), do: String.replace(value, <<0>>, "")
  def strip_nul(value) when is_list(value), do: Enum.map(value, &strip_nul/1)

  def strip_nul(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {strip_nul(key), strip_nul(item)} end)

  def strip_nul(value), do: value

  defp strip_nul_changes(changeset) do
    Enum.reduce(@text_fields ++ @json_fields, changeset, fn field, acc ->
      case fetch_change(acc, field) do
        {:ok, value} -> put_change(acc, field, strip_nul(value))
        :error -> acc
      end
    end)
  end

  defp key_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:conversation_uuid,
      name: :phoenix_kit_agent_messages_conversation_uuid_fkey
    )
    |> foreign_key_constraint(:ai_request_uuid,
      name: :phoenix_kit_agent_messages_ai_request_uuid_fkey
    )
  end
end
