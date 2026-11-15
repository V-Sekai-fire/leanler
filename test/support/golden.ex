defmodule Leanler.Golden do
  @moduledoc false
  # Golden files: exact outputs committed to the repository. A mismatch names the entry. Set
  # LEANLER_REGOLD=1 to rewrite them, then read the diff before committing.

  @dir Path.expand("../golden", __DIR__)

  def dir, do: @dir
  def regold?, do: System.get_env("LEANLER_REGOLD") == "1"

  @doc "Reads the call table: `[{function, args, expected}]`."
  def calls do
    {table, _binding} = Code.eval_file(Path.join(@dir, "calls.golden"))
    table
  end

  @doc "Runs every entry through `call`. Returns the entries whose answer differs."
  def call_mismatches(table, call) do
    Enum.flat_map(table, fn {fun, args, expected} ->
      case call.(fun, args) do
        ^expected -> []
        got -> [{fun, args, expected, got}]
      end
    end)
  end

  @doc "Compares `text` with the file. Returns `:ok` or `{:mismatch, first_differing_line}`."
  def compare_text(name, text) do
    path = Path.join(@dir, name)

    if regold?() do
      File.write!(path, text)
      :ok
    else
      compare(File.read!(path), text)
    end
  end

  def compare(expected, expected), do: :ok

  def compare(expected, got) do
    line =
      Enum.zip(String.split(expected, "\n"), String.split(got, "\n"))
      |> Enum.with_index(1)
      |> Enum.find_value(fn {{a, b}, n} -> if a != b, do: {n, a, b} end)

    {:mismatch, line || :length}
  end
end
