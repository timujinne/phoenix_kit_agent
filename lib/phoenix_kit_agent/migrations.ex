defmodule PhoenixKitAgent.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_agent` — the protocol core's
  `mix phoenix_kit.update` discovers through `PhoenixKitAgent.migration_module/0`
  (`current_version/0`, `migrated_version_runtime/1`, `up/1`, `down/1`). Same
  shape as `PhoenixKitDashboards.Migrations`: two version readers, `up/1`
  re-reading the version before it changes anything, the SQL kept as data
  (`up_statements/2`, `down_statements/2`).

  ## Tables (V1)

    * `phoenix_kit_agent_conversations` — a user's chats; the chat list reads
      them by `(user_uuid, status, last_message_at DESC)`.
    * `phoenix_kit_agent_messages` — every message of a chat, the tool calls
      and their outcomes included; `ai_request_uuid` links the
      `phoenix_kit_ai_requests` row of a model call.
    * `phoenix_kit_agent_attachments` — files attached to a message; the bytes
      live in Storage (`file_uuid`).
    * `phoenix_kit_agent_user_settings` — one row per user, `NULL` meaning "the
      module default"; also the per-user "turn in flight" lock.
    * `phoenix_kit_agent_limit_events` — one limit notice per user, kind and
      period.

  ## V2 — the confirmation of a write (spec §5.2, I6)

    * `phoenix_kit_agent_messages.tool_outcome` also takes `expired`,
      `changed` and `failed` (the outcomes of a confirmation card, kept on its
      `notice`);
    * `assistant_message_uuid` — on a `tool` message, the `assistant` message
      whose tool call it answers (the arguments a confirmation is redeemed
      with). No foreign key: both rows are in the same chat and go with it;
    * `confirmation_uuid` — the confirmation core holds the write in
      (`PhoenixKit.API.Confirm`), on the `tool` message that asks for it and
      on the `notice` that says how it ended; partial index
      `phoenix_kit_agent_messages_confirmation_uuid_index`, through which the
      chat panel finds the cards still waiting. No foreign key: core deletes
      its rows on its own schedule.

  `down/1` to V1 drops the two columns and the index, and clears an outcome
  V1 cannot hold (the notice stays, without it).

  Deleting a user deletes their rows of every table (`ON DELETE CASCADE`); a
  deleted `phoenix_kit_ai_requests` row, AI endpoint or Storage file leaves the
  link `NULL` and never blocks the delete. Money is in micro-dollars
  (`*_micro_usd`, `$1 = 1_000_000`); the AI journal keeps dollars
  (`phoenix_kit_ai_requests.cost`), turned into micro-dollars by
  `PhoenixKitAgent.Config.cost_to_micro/1`.

  ## Version marker

  `COMMENT ON TABLE phoenix_kit_agent_conversations IS 'pk_agent_schema:<N>'`.
  No table, or one without a `pk_agent_schema:` comment, reads as version 0.

  ## Idempotency and rollback

  Every statement guards itself (`IF NOT EXISTS` / `IF EXISTS`), so the chain
  can be re-run. These tables belong to this module alone: `down/1` to version
  0 **drops them with every chat, message, attachment link and per-user
  setting in them** (the Storage files of the attachments stay). Back up the
  database first.

  ## Ordering

  The foreign keys reach core's `phoenix_kit_users`, `phoenix_kit_files`,
  `phoenix_kit_ai_endpoints` and `phoenix_kit_ai_requests`, so this chain runs
  after core's (`mix phoenix_kit.update` generates the module migrations after
  core's own).
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @current_version 2
  @default_prefix "public"
  @marker_prefix "pk_agent_schema:"
  @version_table "phoenix_kit_agent_conversations"

  # The values of `phoenix_kit_agent_messages.tool_outcome`, by version.
  @v1_outcomes ~w(ok error denied needs_confirmation confirmed rejected)
  @v2_outcomes @v1_outcomes ++ ~w(expired changed failed)

  # Children first: the order `down_statements/2` drops them in.
  @tables ~w(
    phoenix_kit_agent_limit_events
    phoenix_kit_agent_user_settings
    phoenix_kit_agent_attachments
    phoenix_kit_agent_messages
    phoenix_kit_agent_conversations
  )

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pk_agent_schema:<N>` marker."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  Applies the chain up to `opts[:version]` (default `current_version/0`).
  Migration context only. Re-reads the installed version first: a database
  already at (or past) the target is left alone.
  """
  @spec up(keyword() | map()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)

    if migrated_version(opts) < opts.version do
      Helpers.ensure_extension!("pgcrypto")
      Helpers.ensure_uuid_v7_function(opts.prefix)

      opts.prefix
      |> up_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  Rolls back to `opts[:version]` (default `0`). Migration context only. To 0 it
  drops every table of the module — see the moduledoc.
  """
  @spec down(keyword() | map()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)

    if migrated_version(opts) > opts.version do
      opts.prefix
      |> down_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  The installed version, read inside a migration through `Ecto.Migration`'s
  `repo()`. No rescue: a version that cannot be read aborts the migration.
  """
  @spec migrated_version(keyword() | map()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @current_version)
    read_version(repo(), opts.prefix)
  end

  @doc """
  The installed version, read outside a migration (what `mix phoenix_kit.update`
  calls) through PhoenixKit's configured repo. An invalid prefix raises; a
  database that cannot be reached reads as `0`, which only costs a redundant
  migration file because `up/1` re-reads the version before it changes
  anything.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @current_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.prefix)
  rescue
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  end

  @doc """
  The SQL `up/1` runs, as data. `target` is how far to go (default
  `current_version/0`); `0` is nothing. Every version from V1 on is in it:
  each statement guards itself, so the versions already applied change
  nothing.
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ @default_prefix, target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = valid_prefix!(prefix)

    if target == 0 do
      []
    else
      Enum.flat_map(1..target, &version_up(&1, prefix)) ++ [marker_statement(prefix, target)]
    end
  end

  @doc """
  The SQL `down/1` runs, as data. To `0` it drops every table of the module;
  to a version still in the chain it undoes every later version (each
  statement guards itself) and re-stamps the marker.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ @default_prefix, target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = valid_prefix!(prefix)

    if target == 0 do
      Enum.map(@tables, &"DROP TABLE IF EXISTS #{Helpers.qualify_table(&1, prefix)}")
    else
      later = if target < @current_version, do: @current_version..(target + 1)//-1, else: []
      Enum.flat_map(later, &version_down(&1, prefix)) ++ [marker_statement(prefix, target)]
    end
  end

  defp version_up(1, prefix), do: v1_statements(prefix)
  defp version_up(2, prefix), do: v2_statements(prefix)

  defp version_down(2, prefix), do: v2_down_statements(prefix)

  # ── V1 ────────────────────────────────────────────────────────────────

  defp v1_statements(prefix) do
    uuid7 = Helpers.uuid_v7_call(prefix)
    users = Helpers.qualify_table("phoenix_kit_users", prefix)
    files = Helpers.qualify_table("phoenix_kit_files", prefix)
    endpoints = Helpers.qualify_table("phoenix_kit_ai_endpoints", prefix)
    requests = Helpers.qualify_table("phoenix_kit_ai_requests", prefix)
    conv = Helpers.qualify_table("phoenix_kit_agent_conversations", prefix)
    msgs = Helpers.qualify_table("phoenix_kit_agent_messages", prefix)
    atts = Helpers.qualify_table("phoenix_kit_agent_attachments", prefix)
    settings = Helpers.qualify_table("phoenix_kit_agent_user_settings", prefix)
    events = Helpers.qualify_table("phoenix_kit_agent_limit_events", prefix)

    [
      """
      CREATE TABLE IF NOT EXISTS #{conv} (
        uuid uuid DEFAULT #{uuid7} NOT NULL,
        user_uuid uuid NOT NULL,
        title text,
        status character varying(16) DEFAULT 'active' NOT NULL,
        last_message_at timestamp without time zone,
        message_count integer DEFAULT 0 NOT NULL,
        input_tokens bigint DEFAULT 0 NOT NULL,
        output_tokens bigint DEFAULT 0 NOT NULL,
        cost_micro_usd bigint DEFAULT 0 NOT NULL,
        busy_since timestamp without time zone,
        busy_turn_ref text,
        metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
        inserted_at timestamp without time zone DEFAULT now() NOT NULL,
        updated_at timestamp without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_agent_conversations_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_agent_conversations_user_uuid_fkey FOREIGN KEY (user_uuid)
          REFERENCES #{users}(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_agent_conversations_status_check
          CHECK (status IN ('active', 'archived', 'deleted'))
      )
      """,
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_conversations_user_list_index ON #{conv} (user_uuid, status, last_message_at DESC)",
      """
      CREATE TABLE IF NOT EXISTS #{msgs} (
        uuid uuid DEFAULT #{uuid7} NOT NULL,
        conversation_uuid uuid NOT NULL,
        turn_ref text,
        role character varying(16) NOT NULL,
        content text,
        tool_calls jsonb,
        tool_call_id text,
        tool_name text,
        tool_outcome character varying(32),
        tool_result jsonb,
        ai_request_uuid uuid,
        model text,
        input_tokens integer,
        output_tokens integer,
        cost_micro_usd bigint,
        latency_ms integer,
        error text,
        inserted_at timestamp without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_agent_messages_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_agent_messages_conversation_uuid_fkey FOREIGN KEY (conversation_uuid)
          REFERENCES #{conv}(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_agent_messages_ai_request_uuid_fkey FOREIGN KEY (ai_request_uuid)
          REFERENCES #{requests}(uuid) ON DELETE SET NULL,
        CONSTRAINT phoenix_kit_agent_messages_role_check
          CHECK (role IN ('user', 'assistant', 'tool', 'notice')),
        CONSTRAINT phoenix_kit_agent_messages_tool_outcome_check
          CHECK (#{outcome_check(@v1_outcomes)})
      )
      """,
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_messages_conversation_index ON #{msgs} (conversation_uuid, inserted_at)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_messages_turn_ref_index ON #{msgs} (turn_ref)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_messages_ai_request_uuid_index ON #{msgs} (ai_request_uuid) WHERE ai_request_uuid IS NOT NULL",
      """
      CREATE TABLE IF NOT EXISTS #{atts} (
        uuid uuid DEFAULT #{uuid7} NOT NULL,
        conversation_uuid uuid NOT NULL,
        message_uuid uuid,
        user_uuid uuid NOT NULL,
        file_uuid uuid,
        filename text NOT NULL,
        content_type text NOT NULL,
        size_bytes bigint NOT NULL,
        kind character varying(16) NOT NULL,
        status character varying(16) DEFAULT 'pending' NOT NULL,
        extracted_text text,
        pages integer,
        truncated boolean DEFAULT false NOT NULL,
        error text,
        inserted_at timestamp without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_agent_attachments_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_agent_attachments_conversation_uuid_fkey FOREIGN KEY (conversation_uuid)
          REFERENCES #{conv}(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_agent_attachments_message_uuid_fkey FOREIGN KEY (message_uuid)
          REFERENCES #{msgs}(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_agent_attachments_user_uuid_fkey FOREIGN KEY (user_uuid)
          REFERENCES #{users}(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_agent_attachments_file_uuid_fkey FOREIGN KEY (file_uuid)
          REFERENCES #{files}(uuid) ON DELETE SET NULL,
        CONSTRAINT phoenix_kit_agent_attachments_kind_check
          CHECK (kind IN ('image', 'pdf', 'sheet', 'text')),
        CONSTRAINT phoenix_kit_agent_attachments_status_check
          CHECK (status IN ('pending', 'ready', 'failed')),
        CONSTRAINT phoenix_kit_agent_attachments_size_bytes_check CHECK (size_bytes >= 0)
      )
      """,
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_attachments_conversation_uuid_index ON #{atts} (conversation_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_attachments_message_uuid_index ON #{atts} (message_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_attachments_user_uuid_index ON #{atts} (user_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_attachments_file_uuid_index ON #{atts} (file_uuid) WHERE file_uuid IS NOT NULL",
      """
      CREATE TABLE IF NOT EXISTS #{settings} (
        user_uuid uuid NOT NULL,
        enabled boolean,
        endpoint_uuid uuid,
        system_prompt text,
        personal_instructions text,
        daily_cost_limit_micro_usd bigint,
        monthly_cost_limit_micro_usd bigint,
        daily_turn_limit integer,
        max_attachment_mb integer,
        max_attachments_per_message integer,
        notify_on_limit boolean DEFAULT false NOT NULL,
        notify_user_uuids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
        busy_since timestamp without time zone,
        busy_turn_ref text,
        updated_by_uuid uuid,
        inserted_at timestamp without time zone DEFAULT now() NOT NULL,
        updated_at timestamp without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_agent_user_settings_pkey PRIMARY KEY (user_uuid),
        CONSTRAINT phoenix_kit_agent_user_settings_user_uuid_fkey FOREIGN KEY (user_uuid)
          REFERENCES #{users}(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_agent_user_settings_endpoint_uuid_fkey FOREIGN KEY (endpoint_uuid)
          REFERENCES #{endpoints}(uuid) ON DELETE SET NULL,
        CONSTRAINT phoenix_kit_agent_user_settings_updated_by_uuid_fkey FOREIGN KEY (updated_by_uuid)
          REFERENCES #{users}(uuid) ON DELETE SET NULL,
        CONSTRAINT phoenix_kit_agent_user_settings_limits_check CHECK (
          (daily_cost_limit_micro_usd IS NULL OR daily_cost_limit_micro_usd >= 0) AND
          (monthly_cost_limit_micro_usd IS NULL OR monthly_cost_limit_micro_usd >= 0) AND
          (daily_turn_limit IS NULL OR daily_turn_limit >= 0) AND
          (max_attachment_mb IS NULL OR max_attachment_mb >= 0) AND
          (max_attachments_per_message IS NULL OR max_attachments_per_message >= 0)
        )
      )
      """,
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_user_settings_endpoint_uuid_index ON #{settings} (endpoint_uuid) WHERE endpoint_uuid IS NOT NULL",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_user_settings_updated_by_uuid_index ON #{settings} (updated_by_uuid) WHERE updated_by_uuid IS NOT NULL",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_user_settings_notify_user_uuids_index ON #{settings} USING gin (notify_user_uuids)",
      """
      CREATE TABLE IF NOT EXISTS #{events} (
        uuid uuid DEFAULT #{uuid7} NOT NULL,
        user_uuid uuid NOT NULL,
        limit_kind character varying(32) NOT NULL,
        period_key character varying(16) NOT NULL,
        used bigint,
        "limit" bigint,
        notified_at timestamp without time zone,
        inserted_at timestamp without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_agent_limit_events_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_agent_limit_events_user_uuid_fkey FOREIGN KEY (user_uuid)
          REFERENCES #{users}(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_agent_limit_events_limit_kind_check
          CHECK (limit_kind IN ('daily_cost', 'monthly_cost', 'daily_turns', 'warn_80', 'ai_budget'))
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_agent_limit_events_user_kind_period_index ON #{events} (user_uuid, limit_kind, period_key)"
    ]
  end

  # ── V2 ────────────────────────────────────────────────────────────────

  defp v2_statements(prefix) do
    msgs = Helpers.qualify_table("phoenix_kit_agent_messages", prefix)

    [
      "ALTER TABLE #{msgs} ADD COLUMN IF NOT EXISTS assistant_message_uuid uuid",
      "ALTER TABLE #{msgs} ADD COLUMN IF NOT EXISTS confirmation_uuid uuid",
      "ALTER TABLE #{msgs} DROP CONSTRAINT IF EXISTS phoenix_kit_agent_messages_tool_outcome_check",
      "ALTER TABLE #{msgs} ADD CONSTRAINT phoenix_kit_agent_messages_tool_outcome_check CHECK (#{outcome_check(@v2_outcomes)})",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_messages_confirmation_uuid_index ON #{msgs} (confirmation_uuid) WHERE confirmation_uuid IS NOT NULL"
    ]
  end

  defp v2_down_statements(prefix) do
    msgs = Helpers.qualify_table("phoenix_kit_agent_messages", prefix)
    index = Helpers.qualify_table("phoenix_kit_agent_messages_confirmation_uuid_index", prefix)
    added = Enum.map_join(@v2_outcomes -- @v1_outcomes, ", ", &"'#{&1}'")

    [
      "DROP INDEX IF EXISTS #{index}",
      "ALTER TABLE #{msgs} DROP CONSTRAINT IF EXISTS phoenix_kit_agent_messages_tool_outcome_check",
      "UPDATE #{msgs} SET tool_outcome = NULL WHERE tool_outcome IN (#{added})",
      "ALTER TABLE #{msgs} ADD CONSTRAINT phoenix_kit_agent_messages_tool_outcome_check CHECK (#{outcome_check(@v1_outcomes)})",
      "ALTER TABLE #{msgs} DROP COLUMN IF EXISTS confirmation_uuid",
      "ALTER TABLE #{msgs} DROP COLUMN IF EXISTS assistant_message_uuid"
    ]
  end

  defp outcome_check(outcomes) do
    "tool_outcome IS NULL OR tool_outcome IN (" <>
      Enum.map_join(outcomes, ", ", &"'#{&1}'") <> ")"
  end

  defp marker_statement(prefix, version) do
    "COMMENT ON TABLE #{Helpers.qualify_table(@version_table, prefix)} IS '#{@marker_prefix}#{version}'"
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{})
    prefix = valid_prefix!(Map.get(opts, :prefix) || @default_prefix)

    opts
    |> Map.put(:prefix, prefix)
    |> Map.put_new(:version, version)
  end

  # Core's rules: the prefix is interpolated into the SQL.
  defp valid_prefix!(prefix) do
    :ok = Helpers.validate_prefix!(prefix)
    prefix
  end

  defp read_version(repo, prefix) do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = $1 AND n.nspname = $2 AND c.relkind = 'r'
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[comment]]}} -> parse_version(comment)
      {:ok, %{rows: []}} -> 0
      {:error, error} -> raise error
    end
  end

  defp parse_version(@marker_prefix <> n) do
    case Integer.parse(n) do
      {version, ""} when version >= 0 -> version
      _ -> 0
    end
  end

  defp parse_version(_), do: 0

  # Stamping a version the chain does not have would make every later version
  # look applied, so it is refused.
  defp validate_target!(target) when target > @current_version do
    raise ArgumentError,
          "PhoenixKitAgent.Migrations has no version #{target} " <>
            "(current_version/0 is #{@current_version})"
  end

  defp validate_target!(_target), do: :ok
end
