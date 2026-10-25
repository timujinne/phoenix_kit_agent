defmodule PhoenixKitAgent.Test.AISchemaMigration do
  @moduledoc """
  Test-boot wrapper around `phoenix_kit_ai`'s own migration chain (the task
  guard's tables: capabilities, task settings, guard events and blocks), as
  a host's generated migration runs it.

  `test_helper.exs` runs it through `Ecto.Migrator`, keyed on
  `PhoenixKitAI.Migrations.current_version/0` plus an offset, so that its
  key never meets the key of this module's own chain.
  """

  use Ecto.Migration

  alias PhoenixKitAI.Migrations

  def up, do: Migrations.up(prefix: "public")
  def down, do: Migrations.down(prefix: "public")
end
