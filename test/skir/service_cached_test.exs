defmodule Skir.ServiceCachedTest do
  # :persistent_term has global state
  use ExUnit.Case, async: false

  defmodule Methods do
    use Skir.Methods
    method :foo, 1, request: :int32, response: :int32
    method :bar, 2, request: :string, response: :string
  end

  defmodule ConfiguredMethods do
    use Skir.Methods
    method :foo, 1, request: :int32, response: :int32
  end

  defmodule CachedService do
    use Skir.Service, methods: Methods

    @impl true
    def foo(n, _meta), do: {:ok, n + 1}

    @impl true
    def bar(s, _meta), do: {:ok, String.upcase(s)}
  end

  defmodule ConfiguredCachedService do
    use Skir.Service,
      methods: ConfiguredMethods,
      disable_studio: true,
      expose_internal_errors: true

    @impl true
    def foo(n, _meta), do: {:ok, n}
  end

  setup do
    :persistent_term.erase({CachedService, :__skir_service__})
    :persistent_term.erase({ConfiguredCachedService, :__skir_service__})
    :ok
  end

  test "service/0 returns a %Skir.Service{}" do
    assert %Skir.Service{} = CachedService.service()
  end

  test "service has both registered methods" do
    svc = CachedService.service()
    assert map_size(svc.by_name) == 2
    assert Map.has_key?(svc.by_name, "Foo")
    assert Map.has_key?(svc.by_name, "Bar")
  end

  test "subsequent calls return the same instance (cached)" do
    s1 = CachedService.service()
    s2 = CachedService.service()
    assert s1 == s2
  end

  test "options pass through" do
    svc = ConfiguredCachedService.service()
    assert svc.disable_studio == true
    assert svc.expose_internal_errors == true
  end

  test "cached service dispatches correctly" do
    {resp, _} =
      Skir.Service.handle_request(CachedService.service(), "Foo:1::5", nil, nil)

    assert resp.status_code == 200
    assert resp.data == "6"
  end

  test "two cached modules don't collide" do
    s1 = CachedService.service()
    s2 = ConfiguredCachedService.service()
    refute s1 == s2
    assert map_size(s1.by_name) == 2
    assert map_size(s2.by_name) == 1
  end
end
