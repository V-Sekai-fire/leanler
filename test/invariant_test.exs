defmodule Leanler.InvariantTest do
  # INVARIANT: properties that hold for every input, checked with StreamData against the real
  # NIF and the real C node, and against the generator's own output.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Leanler.Invariants, as: I

  @moduletag :property

  for {name, caller} <- [nif: &Leanler.Fixture.nif/2, cnode: &Leanler.Fixture.cnode/2] do
    describe "#{name} build" do
      for invariant <- [
            :add_wraps,
            :add_commutes_and_has_identity,
            :greet_prefixes_the_input_byte_for_byte,
            :even_matches_remainder,
            :double_is_exact_or_says_too_large,
            :flip_is_an_involution,
            :a_bad_argument_is_refused_and_does_not_poison_the_next_call
          ] do
        property "#{invariant}" do
          I.unquote(invariant)(unquote(caller))
        end
      end
    end
  end

  property "the NIF and the C node agree on every call" do
    I.two_builds_agree(&Leanler.Fixture.nif/2, &Leanler.Fixture.cnode/2)
  end

  describe "generated C" do
    property "both shims bind every export, never raise, and are deterministic" do
      I.shim_binds_every_export(&Leanler.Gen.nif/2)
      I.shim_binds_every_export(&Leanler.Gen.cnode/2)
    end

    property "the NIF table has one row per export with its arity and scheduler flag" do
      I.nif_table_has_one_row_per_export_with_its_arity()
    end

    property "name mangling is C-safe and injective" do
      I.mangle_is_c_safe_and_injective()
    end

    property "Config.parse never raises and answers a tagged tuple" do
      I.config_parse_never_raises_and_answers_a_tagged_tuple()
    end
  end
end
