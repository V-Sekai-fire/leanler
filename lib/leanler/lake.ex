defmodule Leanler.Lake do
  @moduledoc """
  The Lean side of a build: run Lake, find the C that Lean emitted for the modules your
  exports reach, and name the initializers the generated shim has to call.

  Leanler does not link Lake's static archives. A `lean_lib` archives only its own globs, so a
  module imported from another library (a dependency's `Planner.Iso8601Duration`, say) would be
  missing. Lean writes `<root>/.lake/build/ir/<Module>.c` for every module it compiles, and each
  file calls the initializer of every module it imports. Following those calls from the modules
  you name gives the exact import closure, and `Leanler.Build` compiles those files.

  Every function returns `{:ok, value}` or `{:error, message}`.
  """

  alias Leanler.Config

  @typedoc "A module in the closure: initializer symbol, its C file, and the arity it was emitted with."
  @type unit :: %{symbol: String.t(), file: Path.t(), arity: 1 | 2}

  @doc """
  Mangles one Lean name the way the C emitter does: `_` doubles, any other character that is
  not a letter or digit becomes `_xHH`.

      iex> Leanler.Lake.mangle("persona")
      "persona"
      iex> Leanler.Lake.mangle("lean-guest")
      "lean_x2dguest"
      iex> Leanler.Lake.mangle("a_b")
      "a__b"
  """
  @spec mangle(String.t()) :: String.t()
  def mangle(name) do
    name
    |> String.to_charlist()
    |> Enum.map_join(fn
      ?_ ->
        "__"

      c when c in ?a..?z or c in ?A..?Z or c in ?0..?9 ->
        <<c>>

      c ->
        "_x" <> String.pad_leading(c |> Integer.to_string(16) |> String.downcase(), 2, "0")
    end)
  end

  @doc """
  The initializer symbol of a module, `initialize_<package>_<Module>`.

      iex> Leanler.Lake.init_symbol("persona", "Persona.Web")
      "initialize_persona_Persona_Web"
  """
  @spec init_symbol(String.t(), String.t()) :: String.t()
  def init_symbol(package, module) do
    parts = module |> String.split(".") |> Enum.map(&mangle/1)
    Enum.join(["initialize", mangle(package) | parts], "_")
  end

  @doc "The toolchain prefix the project's `lean-toolchain` selects (`lean --print-prefix`)."
  @spec prefix(Config.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def prefix(%Config{lake_dir: dir}) do
    with {:ok, lean} <- find("lean") do
      case System.cmd(lean, ["--print-prefix"], cd: dir, stderr_to_stdout: true) do
        {out, 0} -> {:ok, String.trim(out)}
        {out, code} -> {:error, "lean --print-prefix exited #{code}: #{String.trim(out)}"}
      end
    end
  end

  @doc "Compiles every named module, and what it imports, with `lake build +Module`."
  @spec build(Config.t()) :: :ok | {:error, String.t()}
  def build(%Config{lake_dir: dir, modules: modules}) do
    with {:ok, lake} <- find("lake") do
      args = ["build" | Enum.map(modules, fn {_pkg, module} -> "+" <> module end)]

      case System.cmd(lake, args, cd: dir, stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, code} -> {:error, "lake #{Enum.join(args, " ")} exited #{code}:\n#{out}"}
      end
    end
  end

  @doc """
  The import closure of the configured modules as C units, plus the toolchain libraries
  (`"Init"`, `"Std"`, `"Lean"`) the closure reaches.
  """
  @spec closure(Config.t()) ::
          {:ok, %{units: [unit()], roots: [unit()], toolchain: [String.t()]}} | {:error, String.t()}
  def closure(%Config{} = config) do
    defined = definitions(config)

    with {:ok, roots} <- resolve_roots(config, defined) do
      {units, toolchain} = walk(Enum.map(roots, & &1.symbol), defined, %{}, [])

      {:ok,
       %{
         units: units |> Map.values() |> Enum.sort_by(& &1.symbol),
         roots: roots,
         toolchain: toolchain |> Enum.uniq() |> Enum.sort()
       }}
    end
  end

  defp resolve_roots(config, defined) do
    results =
      Enum.map(config.modules, fn {package, module} ->
        symbol = init_symbol(package, module)

        case Map.fetch(defined, symbol) do
          {:ok, unit} -> {:ok, unit}
          :error -> {:error, "no emitted C defines #{symbol} (module #{module}, package #{package})"}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, u} -> u end)}
      {:error, _} = error -> error
    end
  end

  defp walk([], _defined, seen, toolchain), do: {seen, toolchain}

  defp walk([symbol | rest], defined, seen, toolchain) do
    cond do
      Map.has_key?(seen, symbol) ->
        walk(rest, defined, seen, toolchain)

      Map.has_key?(defined, symbol) ->
        unit = Map.fetch!(defined, symbol)
        {:ok, text} = File.read(unit.file)

        refs =
          ~r/\binitialize_[A-Za-z0-9_]+(?=\()/
          |> Regex.scan(text)
          |> List.flatten()
          |> Enum.uniq()
          |> List.delete(symbol)

        walk(rest ++ refs, defined, Map.put(seen, symbol, unit), toolchain)

      true ->
        walk(rest, defined, seen, [toolchain_lib(symbol) | toolchain])
    end
  end

  defp toolchain_lib("initialize_Lean" <> _), do: "Lean"
  defp toolchain_lib("initialize_Std" <> _), do: "Std"
  defp toolchain_lib(_other), do: "Init"

  # Every `initialize_*` a C file under an ir directory defines, keyed by symbol. The newest
  # file wins when two workspaces emitted the same module.
  defp definitions(%Config{lake_dir: dir}) do
    root = Path.expand(dir)

    roots =
      [root | path_dependencies(root) ++ package_dependencies(root)]
      |> Enum.uniq()

    roots
    |> Enum.flat_map(&Path.wildcard(Path.join([&1, ".lake", "build", "ir", "**", "*.c"]), match_dot: true))
    |> Enum.flat_map(fn file ->
      {:ok, text} = File.read(file)
      {:ok, stat} = File.stat(file, time: :posix)

      ~r/LEAN_EXPORT lean_object\*\s+(initialize_[A-Za-z0-9_]+)\(([^)]*)\)/
      |> Regex.scan(text)
      |> Enum.map(fn [_, symbol, params] ->
        arity = params |> String.split(",", trim: true) |> length()
        {symbol, %{symbol: symbol, file: file, arity: arity, mtime: stat.mtime}}
      end)
    end)
    |> Enum.reduce(%{}, fn {symbol, unit}, acc ->
      Map.update(acc, symbol, unit, fn old -> if unit.mtime > old.mtime, do: unit, else: old end)
    end)
    |> Map.new(fn {symbol, unit} -> {symbol, Map.delete(unit, :mtime)} end)
  end

  defp path_dependencies(root) do
    case File.read(Path.join(root, "lake-manifest.json")) do
      {:ok, text} ->
        text
        |> :json.decode()
        |> Map.get("packages", [])
        |> Enum.filter(&(&1["type"] == "path"))
        |> Enum.map(&Path.expand(&1["dir"], root))

      {:error, _} ->
        []
    end
  end

  defp package_dependencies(root),
    do: Path.wildcard(Path.join([root, ".lake", "packages", "*"]), match_dot: true)

  defp find(program) do
    case System.find_executable(program) do
      nil -> {:error, "`#{program}` is not on PATH; install elan (https://github.com/leanprover/elan)"}
      path -> {:ok, path}
    end
  end
end
