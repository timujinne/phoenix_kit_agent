defmodule PhoenixKitAgent.MigrationsTest do
  @moduledoc """
  The module-owned chain, run as the real SQL inside the sandbox: the tables it
  builds, their foreign keys and the list index, the confirmation columns of
  V2, a re-run, and down/up round trips — through the statements and through
  `Ecto.Migrator` with the wrapper a host's generated migration uses.
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKitAgent.Migrations
  alias PhoenixKitAgent.Test.SchemaMigration

  @tables ~w(
    phoenix_kit_agent_conversations
    phoenix_kit_agent_messages
    phoenix_kit_agent_attachments
    phoenix_kit_agent_user_settings
    phoenix_kit_agent_limit_events
  )

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp existing_tables do
    query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name = ANY($1) ORDER BY 1",
      [@tables]
    )
    |> List.flatten()
  end

  defp marker do
    case query("SELECT obj_description('public.phoenix_kit_agent_conversations'::regclass)") do
      [[marker]] -> marker
    end
  end

  # {child table, child column, parent table, ON DELETE action}
  defp foreign_keys do
    query("""
    SELECT c.conrelid::regclass::text, a.attname, c.confrelid::regclass::text, c.confdeltype
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
    WHERE c.contype = 'f' AND c.conrelid::regclass::text LIKE 'phoenix_kit_agent_%'
    ORDER BY 1, 2
    """)
    |> Enum.map(fn [child, column, parent, action] -> {child, column, parent, action} end)
  end

  # "c" = CASCADE, "n" = SET NULL
  @foreign_keys [
    {"phoenix_kit_agent_attachments", "conversation_uuid", "phoenix_kit_agent_conversations",
     "c"},
    {"phoenix_kit_agent_attachments", "file_uuid", "phoenix_kit_files", "n"},
    {"phoenix_kit_agent_attachments", "message_uuid", "phoenix_kit_agent_messages", "c"},
    {"phoenix_kit_agent_attachments", "user_uuid", "phoenix_kit_users", "c"},
    {"phoenix_kit_agent_conversations", "user_uuid", "phoenix_kit_users", "c"},
    {"phoenix_kit_agent_limit_events", "user_uuid", "phoenix_kit_users", "c"},
    {"phoenix_kit_agent_messages", "ai_request_uuid", "phoenix_kit_ai_requests", "n"},
    {"phoenix_kit_agent_messages", "conversation_uuid", "phoenix_kit_agent_conversations", "c"},
    {"phoenix_kit_agent_user_settings", "endpoint_uuid", "phoenix_kit_ai_endpoints", "n"},
    {"phoenix_kit_agent_user_settings", "updated_by_uuid", "phoenix_kit_users", "n"},
    {"phoenix_kit_agent_user_settings", "user_uuid", "phoenix_kit_users", "c"}
  ]

  defp indexdef(name) do
    [[indexdef]] = query("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [name])
    indexdef
  end

  # The foreign keys and the two indexes the module relies on, as the schema
  # in the database has them now.
  defp assert_structure do
    assert foreign_keys() == @foreign_keys

    assert indexdef("phoenix_kit_agent_conversations_user_list_index") =~
             "(user_uuid, status, last_message_at DESC)"

    limit_index = indexdef("phoenix_kit_agent_limit_events_user_kind_period_index")
    assert limit_index =~ "UNIQUE"
    assert limit_index =~ "(user_uuid, limit_kind, period_key)"
  end

  describe "the chain as built at boot" do
    test "is at the current version, with all five tables" do
      assert Migrations.current_version() == 2
      assert marker() == "pk_agent_schema:2"
      assert existing_tables() == Enum.sort(@tables)
      assert Migrations.migrated_version_runtime() == 2
    end

    test "user rows cascade, journal and endpoint links are set to null; the indexes" do
      assert_structure()
    end
  end

  # V2: the two links of a message and the outcomes of a confirmation.
  @v1_outcomes ~w(ok error denied needs_confirmation confirmed rejected)
  @v2_outcomes @v1_outcomes ++ ~w(expired changed failed)

  defp message_columns do
    query("""
    SELECT column_name, data_type FROM information_schema.columns
    WHERE table_name = 'phoenix_kit_agent_messages'
      AND column_name IN ('assistant_message_uuid', 'confirmation_uuid')
    ORDER BY 1
    """)
  end

  defp confirmation_index do
    query(
      "SELECT indexdef FROM pg_indexes WHERE indexname = 'phoenix_kit_agent_messages_confirmation_uuid_index'"
    )
  end

  # Whether the CHECK of the messages table names `outcome`.
  defp outcome_accepted?(outcome) do
    [[definition]] =
      query(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'phoenix_kit_agent_messages_tool_outcome_check'"
      )

    String.contains?(definition, "'#{outcome}'")
  end

  defp assert_v2 do
    assert message_columns() == [
             ["assistant_message_uuid", "uuid"],
             ["confirmation_uuid", "uuid"]
           ]

    assert [[index]] = confirmation_index()
    assert index =~ "(confirmation_uuid)"
    assert index =~ "WHERE (confirmation_uuid IS NOT NULL)"

    for outcome <- @v2_outcomes, do: assert(outcome_accepted?(outcome), outcome)
    refute outcome_accepted?("maybe")
  end

  defp insert_notice(outcome) do
    user = user_fixture()
    chat = conversation_fixture(user)

    Repo.query!(
      "INSERT INTO phoenix_kit_agent_messages (conversation_uuid, role, tool_outcome, confirmation_uuid) VALUES ($1, 'notice', $2, $3) RETURNING uuid",
      [Ecto.UUID.dump!(chat.uuid), outcome, Ecto.UUID.dump!(Ecto.UUID.generate())]
    ).rows
  end

  describe "V2" do
    test "the database refuses an outcome that is not one of the nine" do
      assert_raise Postgrex.Error, ~r/phoenix_kit_agent_messages_tool_outcome_check/, fn ->
        insert_notice("maybe")
      end
    end

    test "down to 1 takes the columns, the index and the new outcomes away; up brings them back" do
      [[uuid]] = insert_notice("expired")

      run(Migrations.down_statements("public", 1))

      assert marker() == "pk_agent_schema:1"
      assert message_columns() == []
      assert confirmation_index() == []
      assert existing_tables() == Enum.sort(@tables)
      for outcome <- @v1_outcomes, do: assert(outcome_accepted?(outcome), outcome)
      refute outcome_accepted?("expired")

      # The notice stays, without the outcome V1 cannot hold.
      assert [[nil]] =
               query("SELECT tool_outcome FROM phoenix_kit_agent_messages WHERE uuid = $1", [uuid])

      # A second down to 1 does not fail.
      run(Migrations.down_statements("public", 1))

      run(Migrations.up_statements("public"))
      assert marker() == "pk_agent_schema:2"
      assert_v2()
      assert_structure()
    end

    test "up from 1 to 2 keeps the chats and messages of V1" do
      [[uuid]] = insert_notice("confirmed")
      run(Migrations.down_statements("public", 1))

      run(Migrations.up_statements("public", 2))

      assert [["confirmed"]] =
               query("SELECT tool_outcome FROM phoenix_kit_agent_messages WHERE uuid = $1", [uuid])

      assert_v2()
    end
  end

  describe "up_statements/2 and down_statements/2" do
    test "a second up changes nothing and does not fail" do
      run(Migrations.up_statements("public"))
      run(Migrations.up_statements("public"))

      assert marker() == "pk_agent_schema:2"
      assert existing_tables() == Enum.sort(@tables)
      assert_v2()
    end

    test "down to 0 drops every table of the module, and up builds them again" do
      run(Migrations.down_statements("public", 0))
      assert existing_tables() == []

      run(Migrations.up_statements("public"))
      assert existing_tables() == Enum.sort(@tables)
      assert marker() == "pk_agent_schema:2"

      # Built here, from the statements as they are now — not the schema a
      # persistent test database kept from an earlier V1.
      assert_structure()
      assert_v2()
    end

    test "down does not touch a table that is not the module's" do
      run(Migrations.down_statements("public", 0))

      assert [[_]] =
               query(
                 "SELECT 1 FROM information_schema.tables WHERE table_name = 'phoenix_kit_users'"
               )
    end

    test "a version the chain does not have is refused in both directions" do
      assert_raise ArgumentError, fn -> Migrations.up_statements("public", 3) end
      assert_raise ArgumentError, fn -> Migrations.down_statements("public", 3) end
    end

    test "an invalid prefix is refused" do
      assert_raise ArgumentError, fn -> Migrations.up_statements("bad prefix; DROP", 1) end
    end

    test "up to 0 applies nothing" do
      assert Migrations.up_statements("public", 0) == []
    end
  end

  describe "through Ecto.Migrator, as a host's generated migration runs it" do
    # The sandbox owns the one connection the test may use; the migrator's lock
    # would want a second one. The version is past every version core's chain
    # recorded, so the migrator does not warn about running an older one.
    @migrator_opts [log: false, migration_lock: false]

    test "down then up again" do
      version = 9_000_000_000_000_000 + System.unique_integer([:positive])

      assert :ok = Ecto.Migrator.up(Repo, version, SchemaMigration, @migrator_opts)
      assert :ok = Ecto.Migrator.down(Repo, version, SchemaMigration, @migrator_opts)
      assert existing_tables() == []
      assert Migrations.migrated_version_runtime() == 0

      assert :ok = Ecto.Migrator.up(Repo, version, SchemaMigration, @migrator_opts)
      assert existing_tables() == Enum.sort(@tables)
      assert Migrations.migrated_version_runtime() == 2
      assert_structure()
      assert_v2()
    end
  end
end
