defmodule PhoenixKitAgent.ModelsTest do
  @moduledoc """
  The choice of a model for a user (spec §7.2): only `phoenix_kit_ai` endpoints
  that can chat, each with whether its model is known to take tools. OpenRouter
  publishes that per model, and so does Anthropic's listing as `phoenix_kit_ai`
  maps it; for other providers `phoenix_kit_ai` has no capability listing, so
  the answer is "unknown".
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKitAgent.Models

  @stub __MODULE__

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  # The OpenRouter `/models` listing.
  defp listing(models) do
    %{
      "data" =>
        Enum.map(models, fn model ->
          {id, parameters, architecture} =
            case model do
              {id, parameters} -> {id, parameters, %{"modality" => "text->text"}}
              {id, parameters, architecture} -> {id, parameters, architecture}
            end

          %{
            "id" => id,
            "name" => id,
            "supported_parameters" => parameters,
            "architecture" => architecture
          }
        end)
    }
  end

  defp serve_models(models, calls \\ 1) do
    test = self()

    Req.Test.expect(
      @stub,
      calls,
      fn conn ->
        send(test, {:models_requested, conn.request_path})
        Req.Test.json(conn, listing(models))
      end
    )
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

  describe "image_input_support/1" do
    test "OpenRouter says per model whether it takes images" do
      sees = endpoint_fixture(%{model: "a/sees"})
      sees_listed = endpoint_fixture(%{model: "a/sees-listed"})
      blind = endpoint_fixture(%{model: "a/blind"})
      missing = endpoint_fixture(%{model: "a/not-listed"})

      serve_models([
        {"a/sees", [], %{"modality" => "text+image->text"}},
        {"a/sees-listed", [], %{"input_modalities" => ["text", "image"], "modality" => "x"}},
        {"a/blind", [], %{"modality" => "text->text", "input_modalities" => ["text"]}}
      ])

      assert Models.image_input_support([sees, sees_listed, blind, missing]) == %{
               sees.uuid => :supported,
               sees_listed.uuid => :supported,
               blind.uuid => :unsupported,
               missing.uuid => :unknown
             }
    end

    test "an image the model can only produce is not an image it takes" do
      draws = endpoint_fixture(%{model: "a/draws"})
      serve_models([{"a/draws", [], %{"modality" => "text->text+image"}}])

      assert Models.image_input_support([draws]) == %{draws.uuid => :unsupported}
    end

    test "other providers are unknown, and nothing is asked of them" do
      deepseek = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})
      Req.Test.stub(@stub, fn _conn -> flunk("a provider without a listing was asked") end)

      assert Models.image_input_support([deepseek]) == %{deepseek.uuid => :unknown}
    end

    test "a model that declares neither input modalities nor a modality is unknown, not blind" do
      bare = endpoint_fixture(%{model: "a/bare"})
      no_architecture = endpoint_fixture(%{model: "a/no-architecture"})

      Req.Test.expect(@stub, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => "a/bare", "architecture" => %{}},
            %{"id" => "a/no-architecture"}
          ]
        })
      end)

      assert Models.image_input_support([bare, no_architecture]) == %{
               bare.uuid => :unknown,
               no_architecture.uuid => :unknown
             }
    end

    test "image_input/1 keeps its answer for a few minutes instead of asking the provider again" do
      Models.clear_cache()
      sees = endpoint_fixture(%{model: "a/sees"})
      serve_models([{"a/sees", [], %{"modality" => "text+image->text"}}], 2)

      assert Models.image_input(sees.uuid) == :supported
      assert Models.image_input(sees.uuid) == :supported
      assert_received {:models_requested, "/api/v1/models"}
      refute_received {:models_requested, _}

      # Forgotten, it is asked again.
      Models.clear_cache()
      assert Models.image_input(sees.uuid) == :supported
      assert_received {:models_requested, "/api/v1/models"}
    end

    test "image_input/1 does not keep an answer across a change of the endpoint's model" do
      Models.clear_cache()
      endpoint = endpoint_fixture(%{model: "a/blind"})

      serve_models(
        [
          {"a/blind", [], %{"modality" => "text->text"}},
          {"a/sees", [], %{"modality" => "text+image->text"}}
        ],
        2
      )

      assert Models.image_input(endpoint.uuid) == :unsupported
      {:ok, _} = PhoenixKitAI.update_endpoint(endpoint, %{model: "a/sees"})
      assert Models.image_input(endpoint.uuid) == :supported
    end

    test "image_input/1 does not keep an answer across a change of the endpoint's connection" do
      Models.clear_cache()
      endpoint = endpoint_fixture(%{model: "a/sees"})
      serve_models([{"a/sees", [], %{"modality" => "text+image->text"}}], 2)

      assert Models.image_input(endpoint.uuid) == :supported

      {:ok, _} =
        PhoenixKitAI.update_endpoint(endpoint, %{base_url: "https://proxy.example/api/v1"})

      assert Models.image_input(endpoint.uuid) == :supported

      assert_received {:models_requested, "/api/v1/models"}
      assert_received {:models_requested, _}
    end

    test "image_input/1 answers for one endpoint by its uuid; no endpoint is unknown" do
      sees = endpoint_fixture(%{model: "a/sees"})
      serve_models([{"a/sees", [], %{"modality" => "text+image->text"}}])

      assert Models.image_input(sees.uuid) == :supported
      assert Models.image_input(nil) == :unknown
      assert Models.image_input(Ecto.UUID.generate()) == :unknown
    end
  end

  describe "tools_support/1" do
    test "OpenRouter says per model whether it takes tools" do
      with_tools = endpoint_fixture(%{model: "a/with-tools"})
      without = endpoint_fixture(%{model: "a/without-tools"})
      missing = endpoint_fixture(%{model: "a/not-listed"})

      serve_models([
        {"a/with-tools", ["temperature", "tools"]},
        {"a/without-tools", ["temperature"]}
      ])

      assert Models.tools_support([with_tools, without, missing]) == %{
               with_tools.uuid => :supported,
               without.uuid => :unsupported,
               missing.uuid => :unknown
             }
    end

    test "endpoints that share a connection are answered by one request" do
      one = endpoint_fixture(%{model: "a/one", api_key: "sk-or-v1-shared"})
      two = endpoint_fixture(%{model: "a/two", api_key: "sk-or-v1-shared"})

      serve_models([{"a/one", ["tools"]}, {"a/two", []}], 1)

      assert %{} = Models.tools_support([one, two])
      assert_received {:models_requested, "/api/v1/models"}
      refute_received {:models_requested, _}
    end

    test "an Anthropic endpoint is answered from its provider's listing" do
      claude =
        endpoint_fixture(%{
          provider: "anthropic",
          base_url: "https://api.anthropic.com/v1",
          model: "claude-opus-5-5"
        })

      serve_models([{"claude-opus-5-5", ["max_tokens", "tools"]}])

      assert Models.tools_support([claude]) == %{claude.uuid => :supported}
      assert_received {:models_requested, "/v1/models"}
    end

    test "other providers are unknown, and nothing is asked of them" do
      deepseek = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})

      Req.Test.stub(@stub, fn _conn -> flunk("a provider without a listing was asked") end)

      assert Models.tools_support([deepseek]) == %{deepseek.uuid => :unknown}
    end

    test "a listing that cannot be had leaves the answer unknown" do
      endpoint = endpoint_fixture(%{model: "a/one"})

      Req.Test.expect(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, "{}")
      end)

      assert Models.tools_support([endpoint]) == %{endpoint.uuid => :unknown}
    end

    test "a transport failure leaves the answer unknown" do
      endpoint = endpoint_fixture(%{model: "a/one"})
      Req.Test.expect(@stub, &Req.Test.transport_error(&1, :econnrefused))

      assert Models.tools_support([endpoint]) == %{endpoint.uuid => :unknown}
    end

    test "no endpoints, no request" do
      Req.Test.stub(@stub, fn _conn -> flunk("nothing to ask") end)
      assert Models.tools_support([]) == %{}
    end
  end

  describe "the cache" do
    alias PhoenixKitAgent.Models.Cache

    test "an entry past its time is dropped when another one is kept" do
      Cache.clear()
      on_exit(&Cache.clear/0)

      assert Cache.fetch({:old, 1}, fn _ -> 0 end, fn -> :old end) == :old
      assert Cache.fetch({:new, 1}, fn _ -> 60_000 end, fn -> :new end) == :new

      assert :ets.lookup(Cache, {:old, 1}) == []
      assert [{{:new, 1}, _expires, :new}] = :ets.lookup(Cache, {:new, 1})
    end
  end
end
