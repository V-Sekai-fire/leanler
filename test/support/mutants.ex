defmodule Leanler.Mutants do
  @moduledoc false
  # One planted wrong caller per invariant. Each is the real behaviour except for one defect,
  # so a mutant that survives its invariant shows the invariant checks nothing.

  @mod64 0x1_0000_0000_0000_0000
  @max64 0xFFFF_FFFF_FFFF_FFFF
  @two63 0x8000_0000_0000_0000

  # The reference: what the fixture's Lean code is specified to do.
  def reference(:add, [a, b]) when a in 0..@max64//1 and b in 0..@max64//1,
    do: {:ok, rem(a + b, @mod64)}

  def reference(:greet, [s]) when is_binary(s), do: {:ok, "hello, " <> s}
  def reference(:even, [n]) when n in 0..@max64//1, do: {:ok, rem(n, 2) == 0}

  def reference(:double, [n]) when n in 0..@max64//1 do
    if 2 * n < @two63, do: {:ok, 2 * n}, else: {:error, :nat_too_large}
  end

  def reference(:flip, [b]) when is_boolean(b), do: {:ok, not b}
  def reference(_fun, _args), do: {:error, :badarg}

  @doc "`{invariant, mutant}` pairs: the mutant breaks exactly what the invariant states."
  def table do
    [
      add_wraps: fn
        :add, [a, b] when is_integer(a) and is_integer(b) -> {:ok, a + b}
        f, a -> reference(f, a)
      end,
      add_commutes_and_has_identity: fn
        :add, [a, b] when is_integer(a) and is_integer(b) -> {:ok, rem(a - b + @mod64, @mod64)}
        f, a -> reference(f, a)
      end,
      greet_prefixes_the_input_byte_for_byte: fn
        :greet, [s] when is_binary(s) and byte_size(s) > 0 ->
          {:ok, "hello, " <> binary_part(s, 0, byte_size(s) - 1)}

        f, a ->
          reference(f, a)
      end,
      even_matches_remainder: fn
        :even, [n] when is_integer(n) -> {:ok, rem(n, 2) == 1}
        f, a -> reference(f, a)
      end,
      double_is_exact_or_says_too_large: fn
        :double, [n] when is_integer(n) -> {:ok, 2 * n}
        f, a -> reference(f, a)
      end,
      flip_is_an_involution: fn
        :flip, [b] when is_boolean(b) -> {:ok, b}
        f, a -> reference(f, a)
      end,
      a_bad_argument_is_refused_and_does_not_poison_the_next_call: fn
        # accepts anything, as a NIF that coerced would
        :greet, [s] -> {:ok, "hello, " <> to_string_safe(s)}
        f, a -> reference(f, a)
      end
    ]
  end

  @doc "A caller that, once it has refused a call, answers every later call with the refusal."
  def poisoned do
    {:ok, flag} = Agent.start_link(fn -> false end)

    fn fun, args ->
      cond do
        Agent.get(flag, & &1) ->
          {:error, :badarg}

        match?({:error, _}, reference(fun, args)) ->
          Agent.update(flag, fn _ -> true end)
          reference(fun, args)

        true ->
          reference(fun, args)
      end
    end
  end

  defp to_string_safe(s) when is_binary(s), do: s
  defp to_string_safe(s), do: inspect(s)
end
