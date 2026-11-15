defmodule Leanler.Generators do
  @moduledoc false
  # Generators that lean on the edges. A property that never draws 0, 2^64-1 or a multi-byte
  # string is decoration, so `test/control_test.exs` checks that these do draw them.

  use ExUnitProperties
  import StreamData

  @max64 0xFFFF_FFFF_FFFF_FFFF
  @two63 0x8000_0000_0000_0000

  def max64, do: @max64

  def u64 do
    frequency([
      {1, constant(0)},
      {1, constant(@max64)},
      {2, member_of([1, 2, @max64 - 1, @two63, @two63 - 1, div(@two63, 2), div(@two63, 2) - 1])},
      {6, integer(0..@max64)}
    ])
  end

  @doc "A valid UTF-8 string: ASCII, every encoded width, NUL, and the empty string."
  def text do
    frequency([
      {1, constant("")},
      {1, constant(<<0>>)},
      {4, string(:printable)},
      {5, codepoints()}
    ])
  end

  defp codepoints do
    frequency([
      {8, integer(0..0x7F)},
      {2, integer(0x80..0x7FF)},
      {2, integer(0x800..0xD7FF)},
      {2, integer(0xE000..0xFFFF)},
      {1, integer(0x10000..0x10FFFF)}
    ])
    |> list_of(max_length: 40)
    |> map(&List.to_string/1)
  end

  @doc "Anything but a binary."
  def not_binary do
    one_of([
      integer(),
      float(),
      atom(:alphanumeric),
      list_of(integer(), max_length: 3),
      tuple({integer()}),
      map_of(atom(:alphanumeric), integer(), max_length: 2),
      bitstring() |> filter(&(not is_binary(&1)))
    ])
  end

  @doc "Anything the wire cannot carry as a u64 or nat."
  def not_u64 do
    one_of([
      integer(-1_000_000..-1),
      integer((@max64 + 1)..(@max64 * 4)),
      float(),
      atom(:alphanumeric),
      binary(),
      list_of(integer(), max_length: 3)
    ])
  end

  @doc "Anything but `true` or `false`."
  def not_bool do
    one_of([integer(), float(), binary(), atom(:alphanumeric) |> filter(&(&1 not in [true, false]))])
  end

  @doc "A valid export type name."
  def type, do: member_of([:string, :nat, :u64, :bool])

  @doc "A valid list of exports for `Leanler.Config`, with distinct names and symbols."
  def exports do
    gen all(
          n <- integer(1..6),
          types <- list_of(tuple({list_of(type(), max_length: 4), type()}), length: n)
        ) do
      for {{args, ret}, i} <- Enum.with_index(types) do
        {:"fn_#{i}", [symbol: "lean_sym_#{i}", args: args, returns: ret]}
      end
    end
  end
end
