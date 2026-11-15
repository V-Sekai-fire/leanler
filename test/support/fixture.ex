defmodule Leanler.Fixture do
  @moduledoc false
  # Builds test/fixture once per run, in both modes, and gives the tests a caller for each.
  # A caller is `fn function, args -> {:ok, v} | {:error, r} end`, so the same property can run
  # against the NIF, the C node, or a planted wrong implementation.

  alias Leanler.{Build, Config}

  @exports [
    add: [symbol: "fixture_add", args: [:u64, :u64], returns: :u64],
    greet: [symbol: "fixture_greet", args: [:string], returns: :string],
    even: [symbol: "fixture_even", args: [:u64], returns: :bool],
    double: [symbol: "fixture_double", args: [:nat], returns: :nat],
    flip: [symbol: "fixture_flip", args: [:bool], returns: :bool]
  ]

  @node_name :leanler_fixture_node

  def exports, do: @exports

  def config(mode) do
    {:ok, config} =
      Config.parse(
        mode: mode,
        module: Leanler.Fixture.Native,
        lake_dir: Path.expand("../fixture", __DIR__),
        package: "fixture",
        modules: ["Fixture"],
        exports: @exports
      )

    config
  end

  @doc "Builds and starts both modes. Returns `:ok`; a failure stops the run with its reason."
  def start do
    root = Path.join(Mix.Project.build_path(), "fixture")

    {:ok, _} = ensure_distributed()
    nif_priv = build(:nif, root)
    cnode_priv = build(:cnode, root)

    {_, _} =
      Code.eval_string("""
      defmodule Leanler.Fixture.Native do
        @on_load :load
        def load, do: :erlang.load_nif(~c"#{Path.join(nif_priv, "leanler_fixture")}", 0)
        def add(_, _), do: :erlang.nif_error(:not_loaded)
        def greet(_), do: :erlang.nif_error(:not_loaded)
        def even(_), do: :erlang.nif_error(:not_loaded)
        def double(_), do: :erlang.nif_error(:not_loaded)
        def flip(_), do: :erlang.nif_error(:not_loaded)
      end
      """)

    exe = Path.join(cnode_priv, Build.cnode_basename(:fixture))
    {:ok, _pid} = Leanler.CNode.start_link(exe, name: @node_name)
    :ok
  end

  defp build(mode, root) do
    priv = Path.join([root, "priv", Atom.to_string(mode)])
    File.mkdir_p!(priv)

    {:ok, _} =
      Build.run(config(mode),
        app: :fixture,
        build_path: Path.join(root, "work_#{mode}"),
        priv: priv,
        log: fn _ -> :ok end
      )

    priv
  end

  defp ensure_distributed do
    if Node.alive?(), do: {:ok, node()}, else: Node.start(:leanler_props, :shortnames)
  end

  @doc "Calls the NIF build."
  def nif(function, args), do: apply(Leanler.Fixture.Native, function, args)

  @doc "Calls the C node build."
  def cnode(function, args), do: Leanler.CNode.call(@node_name, function, args)

  @doc "Both real callers by name, for tests that run on each."
  def callers, do: [nif: &nif/2, cnode: &cnode/2]
end
