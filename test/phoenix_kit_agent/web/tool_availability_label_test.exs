defmodule PhoenixKitAgent.Web.ToolAvailabilityLabelTest do
  @moduledoc """
  The card names each module the way Settings -> API does: by the gettext backend the
  module declares in its `permission_metadata/0` first, then by core's catalogue.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitAgent.Web.ToolAvailability

  defmodule LabelledModule do
    @moduledoc false
    # A msgid of core's "errors" domain only: translated through the declared backend and
    # domain, never through core's "default" catalogue.
    def module_key, do: "agentlabeltest"
    def module_name, do: "can't be blank"
    def enabled?, do: true

    def permission_metadata do
      %{
        key: "agentlabeltest",
        label: "can't be blank",
        icon: "hero-cube",
        description: "",
        gettext_backend: PhoenixKitWeb.Gettext,
        gettext_domain: "errors"
      }
    end
  end

  setup do
    ModuleRegistry.register(LabelledModule)
    previous = Gettext.get_locale(PhoenixKitWeb.Gettext)

    on_exit(fn ->
      ModuleRegistry.unregister(LabelledModule)
      Gettext.put_locale(PhoenixKitWeb.Gettext, previous)
    end)

    Gettext.put_locale(PhoenixKitWeb.Gettext, "ru")
    :ok
  end

  test "a module with its own backend is named in that backend's translation" do
    assert ToolAvailability.module_label("agentlabeltest", "can't be blank") ==
             "не может быть пустым"
  end

  test "a module without a backend is named through core's catalogue" do
    assert ToolAvailability.module_label("nobackend", "Users") ==
             Gettext.gettext(PhoenixKitWeb.Gettext, "Users")

    refute ToolAvailability.module_label("nobackend", "Users") == "Users"
  end

  test "a name the module's backend does not translate falls back to core's catalogue" do
    assert ToolAvailability.module_label("agentlabeltest", "Users") ==
             Gettext.gettext(PhoenixKitWeb.Gettext, "Users")
  end
end
