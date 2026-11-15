defmodule Leanler.GoldenTest do
  # GOLDEN: exact outputs committed to the repository. A change to either is a decision, made by
  # running `LEANLER_REGOLD=1 mix test` and reading the diff.
  use ExUnit.Case, async: true

  alias Leanler.{Gen, Golden, GoldenConfig}

  describe "generated C" do
    test "the NIF shim equals test/golden/nif_shim.c" do
      assert :ok = Golden.compare_text("nif_shim.c", Gen.nif(GoldenConfig.config(:nif), GoldenConfig.roots()))
    end

    test "the C node shim equals test/golden/cnode_shim.c" do
      assert :ok = Golden.compare_text("cnode_shim.c", Gen.cnode(GoldenConfig.config(:cnode), GoldenConfig.roots()))
    end
  end

  describe "calls into the fixture" do
    for {name, fun} <- [nif: &Leanler.Fixture.nif/2, cnode: &Leanler.Fixture.cnode/2] do
      test "the #{name} build answers every entry of test/golden/calls.golden exactly" do
        assert [] = Golden.call_mismatches(Golden.calls(), unquote(fun))
      end
    end

    test "the table covers every export and every type, success and refusal" do
      table = Golden.calls()
      funs = table |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      assert funs == Enum.sort(Keyword.keys(Leanler.Fixture.exports()))
      assert Enum.any?(table, &match?({_, _, {:error, :badarg}}, &1))
      assert Enum.any?(table, &match?({_, _, {:error, :nat_too_large}}, &1))
    end
  end
end
