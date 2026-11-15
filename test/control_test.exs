defmodule Leanler.ControlTest do
  # CONTROL: the other tests can fail. A control passes on a known-good input; a reverse control
  # feeds a planted defect and requires the same check to go red. Without these a green run could
  # mean the generators never reach the edge, or the assertion never runs.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Leanler.{Gen, Generators, Golden, GoldenConfig, Invariants, Mutants}

  describe "control: the oracle and the baseline" do
    test "the reference implementation satisfies every invariant" do
      for {invariant, _mutant} <- Mutants.table() do
        assert :ok = run(invariant, &Mutants.reference/2) |> then(fn _ -> :ok end)
      end
    end

    test "the empty string and zero give the baseline" do
      for {_name, call} <- Leanler.Fixture.callers() do
        assert call.(:greet, [""]) == {:ok, "hello, "}
        assert call.(:add, [0, 0]) == {:ok, 0}
        assert call.(:double, [0]) == {:ok, 0}
      end
    end

    test "the generators reach the edges the properties depend on" do
      u64 = Generators.u64() |> Enum.take(3_000)
      assert 0 in u64
      assert Generators.max64() in u64
      assert Enum.any?(u64, &(&1 >= 0x8000_0000_0000_0000 and &1 < Generators.max64()))

      text = Generators.text() |> Enum.take(3_000)
      assert "" in text
      assert Enum.any?(text, &(byte_size(&1) != String.length(&1)))
      assert Enum.any?(text, &String.contains?(&1, <<0>>))
      assert Enum.all?(text, &String.valid?/1)

      assert Enum.all?(Enum.take(Generators.not_binary(), 500), &(not is_binary(&1)))
      assert Enum.all?(Enum.take(Generators.not_bool(), 500), &(&1 not in [true, false]))
      assert Enum.all?(Enum.take(Generators.not_u64(), 500), &(not (is_integer(&1) and &1 in 0..Generators.max64())))
    end
  end

  describe "reverse control: each invariant catches its planted defect" do
    for {invariant, _} <- Mutants.table() do
      test "#{invariant}" do
        mutant = Keyword.fetch!(Mutants.table(), unquote(invariant))
        assert_raise ExUnit.AssertionError, fn -> run(unquote(invariant), mutant) end
      end
    end

    test "a caller that stays refused after one refusal is caught" do
      assert_raise ExUnit.AssertionError, fn ->
        Invariants.a_bad_argument_is_refused_and_does_not_poison_the_next_call(Mutants.poisoned())
      end
    end

    test "the agreement check catches two builds that differ" do
      different = fn fun, args -> if fun == :even, do: {:ok, true}, else: Mutants.reference(fun, args) end
      assert_raise ExUnit.AssertionError, fn -> Invariants.two_builds_agree(&Mutants.reference/2, different) end
    end

    test "the shim check catches a dropped export and a raising call" do
      drop = fn config, roots -> Gen.nif(%{config | exports: Enum.drop(config.exports, -1)}, roots) end

      raise_in_vm = fn config, roots ->
        Gen.nif(config, roots) <> "\n/* return enif_make_badarg(env); */\n"
      end

      unbalanced = fn config, roots -> Gen.nif(config, roots) <> "\n{\n" end
      varying = fn config, roots -> Gen.nif(config, roots) <> Integer.to_string(System.unique_integer()) end

      for broken <- [drop, raise_in_vm, unbalanced, varying] do
        assert_raise ExUnit.AssertionError, fn -> Invariants.shim_binds_every_export(broken) end
      end
    end

    test "the table check catches a wrong arity and a wrong scheduler flag" do
      wrong_arity = fn config, roots -> String.replace(Gen.nif(config, roots), ~r/", 1, nif_/, ~S(", 9, nif_)) end
      wrong_flag = fn config, roots -> String.replace(Gen.nif(config, roots), "ERL_NIF_DIRTY_JOB_CPU_BOUND", "0") end

      for broken <- [wrong_arity, wrong_flag] do
        assert_raise ExUnit.AssertionError, fn -> Invariants.nif_table_has_one_row_per_export_with_its_arity(broken) end
      end
    end

    test "the mangle check catches a collision and an unsafe character" do
      collides = fn s -> String.replace(s, ~r/[^A-Za-z0-9]/, "_") end
      unsafe = fn s -> s end

      for broken <- [collides, unsafe] do
        assert_raise ExUnit.AssertionError, fn -> Invariants.mangle_is_c_safe_and_injective(broken) end
      end
    end

    test "the parse check catches an error that is not a string" do
      assert_raise ExUnit.AssertionError, fn ->
        Invariants.config_parse_never_raises_and_answers_a_tagged_tuple(fn _ -> {:error, :nope} end)
      end
    end
  end

  describe "reverse control: the golden checks can fail" do
    test "a table entry with one wrong expectation is reported by name" do
      [{fun, args, _} | rest] = Golden.calls()
      broken = [{fun, args, {:ok, :wrong}} | rest]
      assert [{^fun, ^args, {:ok, :wrong}, _got}] = Golden.call_mismatches(broken, &Leanler.Fixture.nif/2)
    end

    test "a wrong implementation is reported against the unchanged table" do
      assert [_ | _] = Golden.call_mismatches(Golden.calls(), fn _f, _a -> {:ok, 0} end)
      assert [_ | _] = Golden.call_mismatches(Golden.calls(), fn f, a -> Mutants.reference(f, a) |> flip_ok() end)
    end

    test "a one-character change to the shim is reported with its line" do
      text = Gen.nif(GoldenConfig.config(:nif), GoldenConfig.roots())
      golden = File.read!(Path.join(Golden.dir(), "nif_shim.c"))
      assert :ok = Golden.compare(golden, text)
      assert {:mismatch, {_line, _expected, _got}} = Golden.compare(golden, String.replace(text, "uint64_t", "uint32_t", global: false))
      assert {:mismatch, _} = Golden.compare(golden, text <> "\n")
    end
  end

  describe "control: the C node cannot be passed off as the NIF" do
    test "the two shims differ and each names its own entry point" do
      nif = Gen.nif(GoldenConfig.config(:nif), GoldenConfig.roots())
      cnode = Gen.cnode(GoldenConfig.config(:cnode), GoldenConfig.roots())
      assert nif =~ "ERL_NIF_INIT" and not (nif =~ "ei_connect")
      assert cnode =~ "ei_connect" and not (cnode =~ "ERL_NIF_INIT")
    end
  end

  # An invariant name runs against a caller. The reference must pass them all.
  defp run(:a_bad_argument_is_refused_and_does_not_poison_the_next_call = inv, caller),
    do: apply(Invariants, inv, [caller])

  defp run(invariant, caller), do: apply(Invariants, invariant, [caller])

  defp flip_ok({:ok, v}) when is_integer(v), do: {:ok, v + 1}
  defp flip_ok(other), do: other
end
