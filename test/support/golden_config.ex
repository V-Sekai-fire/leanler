defmodule Leanler.GoldenConfig do
  @moduledoc false
  # A fixed configuration and fixed roots, so the generated C is the same text on every machine.

  def config(mode) do
    {:ok, config} =
      Leanler.Config.parse(
        mode: mode,
        module: Golden.Native,
        package: "golden",
        modules: ["Golden.Main", {"other", "Other.Lib"}],
        exports: [
          add: [symbol: "golden_add", args: [:u64, :u64], returns: :u64],
          greet: [symbol: "golden_greet", args: [:string], returns: :string],
          scale: [symbol: "golden_scale", args: [:nat, :bool], returns: :nat],
          version: [symbol: "golden_version", args: [], returns: :string]
        ]
      )

    config
  end

  def roots do
    [
      %{symbol: "initialize_golden_Golden_Main", file: "Main.c", arity: 1},
      %{symbol: "initialize_other_Other_Lib", file: "Lib.c", arity: 2}
    ]
  end
end
