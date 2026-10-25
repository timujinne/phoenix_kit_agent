defmodule PhoenixKitAgent.ModelsTest do
  @moduledoc """
  The choice of a model for a user (spec §7.2): only `phoenix_kit_ai` endpoints
  that can chat, each with whether its model is known to take tools or
  images — what `PhoenixKitAI.Capabilities` knows (a catalogue, or what an
  admin declared on the endpoint), never asked of the provider here.
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKitAgent.Models

  @stub __MODULE__

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  describe "list_endpoints/1" do
    test "enabled endpoints that chat, by name" do
      b = endpoint_fixture(%{name: "B chat", model: "a/chat-b"})
      a = endpoint_fixture(%{name: "A chat", model: "a/chat-a"})
      _off = endpoint_fixture(%{name: "Off", model: "a/off", enabled: false})
      _tts = endpoint_fixture(%{name: "Voice", model: "a/some-tts"})
      _embed = endpoint_fixture(%{name: "Embed", model: "a/text-embedding"})
      _image = endpoint_fixture(%{name: "Image", model: "a/some-image"})

      assert Enum.map(Models.list_endpoints(), & &1.uuid) == [a.uuid, b.uuid]
    end

    test "the endpoint a user has now is listed even when it can no longer be picked" do
      off = endpoint_fixture(%{name: "Off", model: "a/off", enabled: false})
      on = endpoint_fixture(%{name: "On", model: "a/on"})

      assert Enum.map(Models.list_endpoints(include: off.uuid), & &1.uuid) == [off.uuid, on.uuid]
      assert Enum.map(Models.list_endpoints(include: nil), & &1.uuid) == [on.uuid]

      assert Enum.map(Models.list_endpoints(include: Ecto.UUID.generate()), & &1.uuid) == [
               on.uuid
             ]
    end
  end

  # An endpoint whose model's abilities an admin declared (the guard's
  # capabilities, read by `PhoenixKitAI.Capabilities.for_endpoint/1`).
  defp declared(model, flags) do
    endpoint_fixture(%{
      model: model,
      provider_settings: %{"capabilities" => Map.put(flags, "model", model)}
    })
  end

  defp no_network do
    Req.Test.stub(@stub, fn _conn -> flunk("the provider's model list was asked") end)
  end

  describe "image_input_support/1" do
    test "what the AI module knows of the model's images in, and nothing asked of the provider" do
      no_network()
      sees = declared("a/sees", %{"vision" => "yes"})
      blind = declared("a/blind", %{"vision" => "no"})
      unknown = endpoint_fixture(%{model: "a/unknown"})

      assert Models.image_input_support([sees, blind, unknown]) == %{
               sees.uuid => :supported,
               blind.uuid => :unsupported,
               unknown.uuid => :unknown
             }
    end

    test "a model known for its tools but not for its images is unknown for images, not seeing" do
      tools_only = declared("a/tools-only", %{"tools" => "yes"})

      assert Models.image_input_support([tools_only]) == %{tools_only.uuid => :unknown}
      assert Models.image_input(tools_only.uuid) == :unknown
    end

    test "a declaration made for another model counts for nothing" do
      endpoint =
        endpoint_fixture(%{
          model: "a/now",
          provider_settings: %{"capabilities" => %{"model" => "a/before", "vision" => "yes"}}
        })

      assert Models.image_input_support([endpoint]) == %{endpoint.uuid => :unknown}
    end

    test "image_input/1 reads the endpoint again: a change is seen at once" do
      endpoint = declared("a/eyes", %{"vision" => "no"})
      assert Models.image_input(endpoint.uuid) == :unsupported

      {:ok, _} =
        PhoenixKitAI.update_endpoint(endpoint, %{
          provider_settings: %{"capabilities" => %{"model" => "a/eyes", "vision" => "yes"}}
        })

      assert Models.image_input(endpoint.uuid) == :supported
    end

    test "image_input/1: no endpoint is unknown" do
      assert Models.image_input(nil) == :unknown
      assert Models.image_input(Ecto.UUID.generate()) == :unknown
    end
  end

  describe "tools_support/1" do
    test "what the AI module knows of the model's tools, and nothing asked of the provider" do
      no_network()
      with_tools = declared("a/with-tools", %{"tools" => "yes"})
      without = declared("a/without-tools", %{"tools" => "no"})
      unknown = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})

      assert Models.tools_support([with_tools, without, unknown]) == %{
               with_tools.uuid => :supported,
               without.uuid => :unsupported,
               unknown.uuid => :unknown
             }

      assert Models.tools_support_of([with_tools.uuid, Ecto.UUID.generate()]) == %{
               with_tools.uuid => :supported
             }
    end

    test "no endpoints, nothing to say" do
      assert Models.tools_support([]) == %{}
    end
  end

  # An Anthropic endpoint with no base URL of its own: a row saved before the
  # registry knew the provider, say. The key it carries is Anthropic's and must
  # reach no other host: the model list was once asked of OpenRouter whenever
  # the URL was blank. Nothing is asked of any provider here: the stub records
  # a request to any host, openrouter.ai or another, and the tests refute it.
  # The blank is `nil` or `""`, both of which a stored row can hold.
  describe "an Anthropic endpoint with a blank base URL" do
    # Shared, so that a request made outside the test process's callers and
    # ancestors (a task started elsewhere) reaches the stub and is recorded.
    setup {Req.Test, :set_req_test_to_shared}

    # Records what is asked of any host and answers an empty list. A flunk
    # would do, but an error in a task that asks is swallowed into "unknown";
    # a message in the mailbox is not.
    defp record_requests do
      test = self()

      Req.Test.stub(@stub, fn conn ->
        send(test, {:requested, conn.host, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"data" => [], "has_more" => false})
      end)
    end

    defp anthropic_without_base_url(model, blank, flags \\ nil) do
      attrs = %{provider: "anthropic", model: model, api_key: "sk-ant-key-that-stays-home"}

      attrs =
        if flags,
          do:
            Map.put(attrs, :provider_settings, %{"capabilities" => Map.put(flags, "model", model)}),
          else: attrs

      attrs
      |> endpoint_fixture()
      |> Ecto.Changeset.change(base_url: blank)
      |> Repo.update!()
    end

    test "tools and images are what the AI module knows, and no host is asked" do
      record_requests()

      sees =
        anthropic_without_base_url("claude-sees", nil, %{"tools" => "yes", "vision" => "yes"})

      blind = anthropic_without_base_url("claude-blind", "", %{"tools" => "no", "vision" => "no"})

      assert sees.base_url == nil
      assert blind.base_url == ""

      assert Models.tools_support([sees, blind]) == %{
               sees.uuid => :supported,
               blind.uuid => :unsupported
             }

      assert Models.image_input_support([sees, blind]) == %{
               sees.uuid => :supported,
               blind.uuid => :unsupported
             }

      assert Models.tools_support_of([sees.uuid]) == %{sees.uuid => :supported}
      assert Models.image_input(sees.uuid) == :supported
      assert Models.image_input(blind.uuid) == :unsupported
      refute_receive {:requested, _host, _authorization}
    end

    test "a model nobody has declared or listed is unknown, and no host is asked" do
      record_requests()

      for blank <- [nil, ""] do
        claude = anthropic_without_base_url("claude-listed-nowhere", blank)

        assert Models.tools_support([claude]) == %{claude.uuid => :unknown}
        assert Models.image_input_support([claude]) == %{claude.uuid => :unknown}
        assert Models.image_input(claude.uuid) == :unknown
      end

      refute_receive {:requested, _host, _authorization}
    end
  end

  describe "reports_cost?/2" do
    # A manual price on the endpoint: whole micro-dollars per 1M tokens. Setting
    # one needs ai.manage (an Owner).
    defp manual_priced(model) do
      endpoint_fixture(
        %{
          provider: "deepseek",
          model: model,
          provider_settings: %{"pricing" => %{"input" => "0.27", "output" => "1.1"}}
        },
        scope: scope_of(owner_fixture())
      )
    end

    test "OpenRouter reports what a call cost" do
      assert Models.reports_cost?(endpoint_fixture())
    end

    test "an Anthropic model with a list price is counted; one without is not" do
      assert Models.reports_cost?(
               endpoint_fixture(%{provider: "anthropic", model: "claude-sonnet-5-5"})
             )

      refute Models.reports_cost?(
               endpoint_fixture(%{provider: "anthropic", model: "claude-unknown-9"})
             )
    end

    test "a manual price on the endpoint is counted; no price is not" do
      assert Models.reports_cost?(manual_priced("deepseek-chat"))

      refute Models.reports_cost?(
               endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})
             )
    end

    test "a summary carries the answer, never the endpoint's key" do
      priced = manual_priced("deepseek-chat")
      claude = endpoint_fixture(%{provider: "anthropic", model: "claude-sonnet-5-5"})
      bare = endpoint_fixture(%{provider: "deepseek", model: "deepseek-reasoner"})

      for endpoint <- [priced, claude, bare] do
        summary = Models.summary(endpoint)
        assert Models.summaries([endpoint.uuid]) == %{endpoint.uuid => summary}
        refute Map.has_key?(summary, :api_key)
        assert Models.reports_cost?(summary) == Models.reports_cost?(endpoint)
      end

      assert Models.summary(priced).reports_cost?
      assert Models.summary(claude).reports_cost?
      refute Models.summary(bare).reports_cost?
    end

    test "a picture's description is counted where a chat call on the model would be" do
      claude = endpoint_fixture(%{provider: "anthropic", model: "claude-sonnet-5-5"})

      assert Models.reports_cost?(endpoint_fixture(), :vision)
      assert Models.reports_cost?(claude, :vision)
      assert Models.reports_cost?(manual_priced("deepseek-chat"), :vision)

      refute Models.reports_cost?(
               endpoint_fixture(%{provider: "anthropic", model: "claude-unknown-9"}),
               :vision
             )

      refute Models.reports_cost?(
               endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"}),
               :vision
             )
    end

    test "no endpoint is not counted" do
      refute Models.reports_cost?(nil)
      refute Models.reports_cost?(nil, :vision)
    end
  end
end
