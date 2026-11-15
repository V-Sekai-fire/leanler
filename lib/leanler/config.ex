defmodule Leanler.Config do
  @moduledoc """
  The `leanler:` keyword of a project's `mix.exs`, validated.

  Every function returns `{:ok, value}` or `{:error, message}`. Nothing here raises.

  ## Keys

    * `:mode` - `:nif` (default) or `:cnode`.
    * `:module` - the Elixir module that does `use Leanler`. Required for `:nif`: the NIF
      library is bound to a module name when it is compiled.
    * `:lake_dir` - the directory holding `lakefile.lean`. Default `"."`.
    * `:package` - the Lake package name that owns the modules. Required.
    * `:modules` - Lean modules whose initializer runs at load, `"Persona.Web"`. A module
      of another package is `{"taskweft", "Planner.Types"}`. Importing modules are initialized
      by their importer, so naming the leaves that hold your exports is enough. Required.
    * `:exports` - a keyword list, `name: [symbol: "c_symbol", args: [types], returns: type]`.
      Types are `:string`, `:nat` (a non-negative integer below 2^64), `:u64` and `:bool`.
    * `:dirty` - run NIF calls on the dirty CPU schedulers. Default `true`.
    * `:cc` - the C compiler. Default `"cc"`.
  """

  @types [:string, :nat, :u64, :bool]

  @enforce_keys [:mode, :lake_dir, :package, :modules, :exports]
  defstruct [
    :mode,
    :module,
    :lake_dir,
    :package,
    :modules,
    :exports,
    dirty: true,
    cc: "cc"
  ]

  @type type :: :string | :nat | :u64 | :bool
  @type export :: %{
          name: atom(),
          symbol: String.t(),
          args: [type()],
          returns: type()
        }
  @type t :: %__MODULE__{}

  @doc "The Lean-side types an export may use."
  @spec types() :: [type()]
  def types, do: @types

  @doc """
  Validates a keyword list.

      iex> {:ok, c} = Leanler.Config.parse(package: "p", modules: ["P.A"],
      ...>   module: P.Native, exports: [ask: [symbol: "p_ask", args: [:string], returns: :string]])
      iex> {c.mode, hd(c.exports).name}
      {:nif, :ask}

      iex> Leanler.Config.parse([])
      {:error, "leanler: :package is required"}
  """
  @spec parse(keyword() | nil) :: {:ok, t()} | {:error, String.t()}
  def parse(nil), do: {:error, "leanler: no :leanler configuration in mix.exs"}

  def parse(opts) when is_list(opts) do
    with {:ok, package} <- fetch_string(opts, :package),
         {:ok, modules} <- fetch_modules(opts, package),
         {:ok, exports} <- fetch_exports(opts),
         {:ok, mode} <- fetch_mode(opts),
         {:ok, module} <- fetch_module(opts, mode) do
      {:ok,
       %__MODULE__{
         mode: mode,
         module: module,
         lake_dir: Keyword.get(opts, :lake_dir, "."),
         package: package,
         modules: modules,
         exports: exports,
         dirty: Keyword.get(opts, :dirty, true),
         cc: Keyword.get(opts, :cc, "cc")
       }}
    end
  end

  def parse(_other), do: {:error, "leanler: the configuration must be a keyword list"}

  defp fetch_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "leanler: #{inspect(key)} is required"}
    end
  end

  defp fetch_modules(opts, package) do
    case Keyword.get(opts, :modules) do
      [_ | _] = list ->
        normalized =
          Enum.map(list, fn
            name when is_binary(name) -> {package, name}
            {pkg, name} when is_binary(pkg) and is_binary(name) -> {pkg, name}
            _ -> :bad
          end)

        if Enum.member?(normalized, :bad),
          do: {:error, "leanler: :modules entries are \"Mod\" or {\"package\", \"Mod\"}"},
          else: {:ok, normalized}

      _ ->
        {:error, "leanler: :modules is required"}
    end
  end

  defp fetch_exports(opts) do
    case Keyword.get(opts, :exports) do
      [_ | _] = list ->
        results = Enum.map(list, &export/1)

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil -> {:ok, Enum.map(results, fn {:ok, e} -> e end)}
          {:error, _} = error -> error
        end

      _ ->
        {:error, "leanler: :exports is required"}
    end
  end

  defp export({name, spec}) when is_atom(name) and is_list(spec) do
    symbol = Keyword.get(spec, :symbol)
    args = Keyword.get(spec, :args, [])
    returns = Keyword.get(spec, :returns)

    cond do
      not (is_binary(symbol) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, symbol)) ->
        {:error, "leanler: export #{name} needs a C identifier as :symbol"}

      not Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, Atom.to_string(name)) ->
        {:error, "leanler: export name #{inspect(name)} must be snake_case"}

      not (is_list(args) and Enum.all?(args, &(&1 in @types))) ->
        {:error, "leanler: export #{name} :args must be drawn from #{inspect(@types)}"}

      returns not in @types ->
        {:error, "leanler: export #{name} :returns must be one of #{inspect(@types)}"}

      true ->
        {:ok, %{name: name, symbol: symbol, args: args, returns: returns}}
    end
  end

  defp export(other), do: {:error, "leanler: bad export entry #{inspect(other)}"}

  defp fetch_mode(opts) do
    case Keyword.get(opts, :mode, :nif) do
      mode when mode in [:nif, :cnode] -> {:ok, mode}
      other -> {:error, "leanler: :mode must be :nif or :cnode, got #{inspect(other)}"}
    end
  end

  defp fetch_module(opts, :nif) do
    case Keyword.get(opts, :module) do
      mod when is_atom(mod) and not is_nil(mod) -> {:ok, mod}
      _ -> {:error, "leanler: :module is required for :nif mode"}
    end
  end

  defp fetch_module(opts, :cnode), do: {:ok, Keyword.get(opts, :module)}
end
