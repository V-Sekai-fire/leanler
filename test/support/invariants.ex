defmodule Leanler.Invariants do
  @moduledoc false
  # Each invariant takes a caller and raises ExUnit.AssertionError when the property fails.
  # `Leanler.Mutants` holds one planted wrong caller per invariant, and the control tests
  # require each of them to be caught.

  use ExUnitProperties
  import ExUnit.Assertions

  alias Leanler.Generators, as: G

  @two63 0x8000_0000_0000_0000
  @mod64 0x1_0000_0000_0000_0000


  def add_wraps(call) do
    check all(a <- G.u64(), b <- G.u64(), max_runs: 200) do
      assert call.(:add, [a, b]) == {:ok, rem(a + b, @mod64)}
    end
  end

  def add_commutes_and_has_identity(call) do
    check all(a <- G.u64(), b <- G.u64(), max_runs: 200) do
      assert call.(:add, [a, b]) == call.(:add, [b, a])
      assert call.(:add, [a, 0]) == {:ok, a}
    end
  end

  def greet_prefixes_the_input_byte_for_byte(call) do
    check all(s <- G.text(), max_runs: 200) do
      assert call.(:greet, [s]) == {:ok, "hello, " <> s}
    end
  end

  def even_matches_remainder(call) do
    check all(n <- G.u64(), max_runs: 200) do
      assert call.(:even, [n]) == {:ok, rem(n, 2) == 0}
    end
  end

  @doc "A Nat result below 2^63 is exact; at or above it the call says so instead of truncating."
  def double_is_exact_or_says_too_large(call) do
    check all(n <- G.u64(), max_runs: 200) do
      expected = if 2 * n < @two63, do: {:ok, 2 * n}, else: {:error, :nat_too_large}
      assert call.(:double, [n]) == expected
    end
  end

  def flip_is_an_involution(call) do
    check all(b <- boolean()) do
      assert {:ok, flipped} = call.(:flip, [b])
      assert flipped == not b
      assert call.(:flip, [flipped]) == {:ok, b}
    end
  end

  @doc "A value of the wrong type is refused by name, and the next good call still works."
  def a_bad_argument_is_refused_and_does_not_poison_the_next_call(call) do
    check all(
            bad_bin <- G.not_binary(),
            bad_int <- G.not_u64(),
            bad_bool <- G.not_bool(),
            a <- G.u64(),
            max_runs: 200
          ) do
      assert call.(:greet, [bad_bin]) == {:error, :badarg}
      assert call.(:add, [bad_int, a]) == {:error, :badarg}
      assert call.(:add, [a, bad_int]) == {:error, :badarg}
      assert call.(:even, [bad_int]) == {:error, :badarg}
      assert call.(:double, [bad_int]) == {:error, :badarg}
      assert call.(:flip, [bad_bool]) == {:error, :badarg}
      assert call.(:add, [a, 1]) == {:ok, rem(a + 1, @mod64)}
    end
  end

  @doc "The NIF and the C node agree on every call."
  def two_builds_agree(a, b) do
    calls =
      one_of([
        tuple({constant(:add), fixed_list([G.u64(), G.u64()])}),
        tuple({constant(:greet), fixed_list([G.text()])}),
        tuple({constant(:even), fixed_list([G.u64()])}),
        tuple({constant(:double), fixed_list([G.u64()])}),
        tuple({constant(:flip), fixed_list([boolean()])})
      ])

    check all({fun, args} <- calls, max_runs: 100) do
      assert a.(fun, args) == b.(fun, args)
    end
  end

  # -- generated C --------------------------------------------------------------------------

  @doc "Every export is bound exactly once, in both shims, and nothing raises into the VM."
  def shim_binds_every_export(shim_fun) do
    check all(exports <- G.exports(), dirty <- boolean(), max_runs: 100) do
      {:ok, config} =
        Leanler.Config.parse(
          mode: :nif,
          module: Some.Module,
          package: "p",
          modules: ["P.A"],
          exports: exports,
          dirty: dirty
        )

      roots = [%{symbol: "initialize_p_P_A", file: "x.c", arity: 1}]
      text = shim_fun.(config, roots)

      for {name, spec} <- exports do
        assert occurrences(text, ~s|"#{name}"|) >= 1
        assert text =~ spec[:symbol] <> "("
      end

      refute text =~ "enif_make_badarg"
      refute text =~ "enif_raise_exception"
      assert occurrences(text, "{") == occurrences(text, "}")
      assert occurrences(text, "(") == occurrences(text, ")")
      assert text == shim_fun.(config, roots)
    end
  end

  def nif_table_has_one_row_per_export_with_its_arity(shim_fun \\ &Leanler.Gen.nif/2) do
    check all(exports <- G.exports(), dirty <- boolean(), max_runs: 100) do
      {:ok, config} =
        Leanler.Config.parse(
          mode: :nif,
          module: Some.Module,
          package: "p",
          modules: ["P.A"],
          exports: exports,
          dirty: dirty
        )

      text = shim_fun.(config, [%{symbol: "initialize_p_P_A", file: "x.c", arity: 1}])
      flag = if dirty, do: "ERL_NIF_DIRTY_JOB_CPU_BOUND", else: "0"

      for {name, spec} <- exports do
        assert text =~ ~s|{"#{name}", #{length(spec[:args])}, nif_#{name}, #{flag}}|
      end
    end
  end

  @doc """
  Mangling is C-safe and injective. A random pair almost never collides, so the second string is
  the first with one character swapped for one the mangler must keep apart (`_`, `-`, `x`, `2`).
  """
  def mangle_is_c_safe_and_injective(mangle \\ &Leanler.Lake.mangle/1) do
    check all(
            a <- string([?a..?c, ?x, ?2, ?d, ?_, ?-, ?., ?\s, 0xE9, 0x4E2D], min_length: 1, max_length: 12),
            i <- integer(0..11),
            c <- member_of(["_", "-", "x", "2", "d", "."]),
            max_runs: 300
          ) do
      chars = String.graphemes(a)
      i = rem(i, length(chars))
      b = chars |> List.replace_at(i, c) |> Enum.join()

      assert mangle.(a) =~ ~r/\A[A-Za-z0-9_]*\z/
      if mangle.(a) == mangle.(b), do: assert(a == b)
    end
  end

  def config_parse_never_raises_and_answers_a_tagged_tuple(parse \\ &Leanler.Config.parse/1) do
    check all(term <- term(), max_runs: 300) do
      assert match?({:ok, _}, parse.(term)) or match?({:error, msg} when is_binary(msg), parse.(term))

      opts = [package: term, modules: term, exports: term, mode: term, module: term]
      assert match?({:error, msg} when is_binary(msg), parse.(opts))
    end
  end

  defp occurrences(text, pattern), do: text |> String.split(pattern) |> length() |> Kernel.-(1)
end
