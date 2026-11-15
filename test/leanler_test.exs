defmodule LeanlerTest do
  use ExUnit.Case, async: true

  alias Leanler.{Config, Gen, Lake}

  doctest Leanler.Config
  doctest Leanler.Lake

  @exports [
    add: [symbol: "fixture_add", args: [:u64, :u64], returns: :u64],
    greet: [symbol: "fixture_greet", args: [:string], returns: :string],
    even: [symbol: "fixture_even", args: [:u64], returns: :bool],
    double: [symbol: "fixture_double", args: [:nat], returns: :nat],
    flip: [symbol: "fixture_flip", args: [:bool], returns: :bool]
  ]

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        mode: :nif,
        module: Leanler.FixtureNative,
        lake_dir: Path.expand("fixture", __DIR__),
        package: "fixture",
        modules: ["Fixture"],
        exports: @exports
      ],
      extra
    )
  end

  describe "Config" do
    test "accepts a complete configuration" do
      assert {:ok, %Config{mode: :nif, modules: [{"fixture", "Fixture"}]}} = Config.parse(opts())
    end

    test "names what is missing" do
      assert {:error, "leanler: :package is required"} = Config.parse(Keyword.delete(opts(), :package))
      assert {:error, "leanler: :exports is required"} = Config.parse(Keyword.delete(opts(), :exports))
      assert {:error, "leanler: :modules is required"} = Config.parse(Keyword.delete(opts(), :modules))
      assert {:error, msg} = Config.parse(Keyword.delete(opts(), :module))
      assert msg =~ ":module is required"
    end

    test "rejects an unknown type, symbol or mode" do
      assert {:error, msg} = Config.parse(opts(exports: [f: [symbol: "x", args: [:float], returns: :string]]))
      assert msg =~ ":args must be drawn from"
      assert {:error, msg} = Config.parse(opts(exports: [f: [symbol: "x; rm", args: [], returns: :string]]))
      assert msg =~ "C identifier"
      assert {:error, msg} = Config.parse(opts(mode: :port))
      assert msg =~ ":mode must be"
    end

    test "a C node needs no module name" do
      assert {:ok, %Config{mode: :cnode}} = Config.parse(opts(mode: :cnode) |> Keyword.delete(:module))
    end
  end

  describe "Lake" do
    test "mangles the way Lean's C emitter does" do
      assert Lake.init_symbol("lean-guest", "A.B_c") == "initialize_lean_x2dguest_A_B__c"
    end
  end

  describe "Gen" do
    setup do
      {:ok, config} = Config.parse(opts())
      %{config: config, roots: [%{symbol: "initialize_fixture_Fixture", file: "x.c", arity: 1}]}
    end

    test "the NIF shim binds every export, dirty, to the named module", %{config: c, roots: r} do
      c_source = Gen.nif(c, r)
      for e <- c.exports, do: assert(c_source =~ ~s({"#{e.name}", #{length(e.args)}, nif_#{e.name}, ERL_NIF_DIRTY_JOB_CPU_BOUND}))
      assert c_source =~ "ERL_NIF_INIT(Elixir.Leanler.FixtureNative,"
      assert c_source =~ "initialize_fixture_Fixture(1)"
    end

    test "an initializer that takes the world is called with it", %{config: c} do
      roots = [%{symbol: "initialize_fixture_Fixture", file: "x.c", arity: 2}]
      assert Gen.nif(c, roots) =~ "initialize_fixture_Fixture(1, lean_io_mk_world())"
    end

    test "the C node shim dispatches every export", %{config: c, roots: r} do
      c_source = Gen.cnode(c, r)
      for e <- c.exports, do: assert(c_source =~ ~s|strcmp(fun, "#{e.name}") == 0|)
      assert c_source =~ "ei_connect_xinit"
    end

    test "no generated code raises into the VM", %{config: c, roots: r} do
      refute Gen.nif(c, r) =~ "enif_make_badarg"
      refute Gen.nif(c, r) =~ "enif_raise_exception"
    end
  end

  describe "the source blocklist" do
    test "lib/ never traps or raises (a planted control must match)" do
      pattern = ~r/^\s*(try|rescue|catch|throw)\b/m
      assert "  rescue e ->" =~ pattern

      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.filter(fn f -> File.read!(f) =~ pattern end)

      assert offenders == []
    end
  end
end
