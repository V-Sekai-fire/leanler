defmodule Leanler do
  @moduledoc """
  Lean 4 functions as OTP NIFs or C nodes, with no hand-written C.

  Mark a Lean function `@[export c_symbol]`, list it in `mix.exs`, and call it from Elixir.

  ## Setup

      # mix.exs
      def project do
        [
          app: :persona,
          compilers: [:leanler] ++ Mix.compilers(),
          deps: [{:leanler, github: "V-Sekai-fire/leanler"}],
          leanler: [
            mode: :nif,                       # or :cnode
            module: Persona.Native,
            package: "persona",
            modules: ["Persona.Web"],
            exports: [
              plan: [symbol: "persona_plan_jsonld_text", args: [:string, :string, :string], returns: :string]
            ]
          ]
        ]
      end

      # lib/persona/native.ex
      defmodule Persona.Native do
        use Leanler
      end

      Persona.Native.plan(domain, problem, "")   #=> {:ok, json} | {:error, reason}

  `mix compile` runs `lake build`, compiles the C Lean emitted for the modules' import closure
  with a generated shim, and links against the toolchain's runtime archives.

  ## Which mode

    * `:nif` loads in the VM. It is the fastest path and the simplest to ship, and calls run on
      the dirty CPU schedulers. A Lean crash (stack overflow, `panic` with `LEAN_ABORT_ON_PANIC`,
      out of memory) takes the whole VM with it.
    * `:cnode` runs Lean in its own OS process that joins the cluster through `ei`. A crash
      costs one process, and the supervisor restarts it. Start it under your supervisor with
      `Persona.Native.start_link/1`; the VM must be distributed (`--sname`).

  Both modes have the same calling convention. See `Leanler.Config` for the options and
  `Leanler.Gen` for the type mapping.
  """

  alias Leanler.Config

  @doc false
  defmacro __using__(_opts) do
    app = Mix.Project.config()[:app]

    case Config.parse(Mix.Project.config()[:leanler]) do
      {:ok, %Config{mode: :nif} = config} -> nif_module(app, config)
      {:ok, %Config{mode: :cnode} = config} -> cnode_module(app, config)
      {:error, message} -> unconfigured(message)
    end
  end

  defp unconfigured(message) do
    quote do
      IO.warn(unquote(message))

      @doc false
      def __leanler__, do: {:error, unquote(message)}
    end
  end

  defp nif_module(app, config) do
    basename = Leanler.Build.nif_basename(app)
    expected = config.module

    stubs =
      for e <- config.exports do
        vars = for i <- 0..(length(e.args) - 1)//1, do: Macro.var(:"_a#{i}", __MODULE__)
        types = Enum.map(e.args, &spec_type/1)
        ret = spec_type(e.returns)
        name = e.name

        quote do
          @spec unquote(name)(unquote_splicing(types)) :: {:ok, unquote(ret)} | {:error, atom()}
          def unquote(name)(unquote_splicing(vars)), do: :erlang.nif_error(:not_loaded)
        end
      end

    quote do
      @on_load :__leanler_load__

      @doc false
      def __leanler_load__ do
        if __MODULE__ == unquote(expected) do
          case :code.priv_dir(unquote(app)) do
            {:error, reason} -> {:error, {:no_priv_dir, reason}}
            dir -> :erlang.load_nif(:filename.join(dir, ~c"#{unquote(basename)}"), 0)
          end
        else
          {:error, {:module_mismatch, [expected: unquote(expected), got: __MODULE__]}}
        end
      end

      unquote_splicing(stubs)
    end
  end

  defp cnode_module(app, config) do
    basename = Leanler.Build.cnode_basename(app)

    calls =
      for e <- config.exports do
        vars = for i <- 0..(length(e.args) - 1)//1, do: Macro.var(:"a#{i}", __MODULE__)
        types = Enum.map(e.args, &spec_type/1)
        ret = spec_type(e.returns)
        name = e.name

        quote do
          @spec unquote(name)(unquote_splicing(types)) :: {:ok, unquote(ret)} | {:error, atom()}
          def unquote(name)(unquote_splicing(vars)),
            do: Leanler.CNode.call(__MODULE__, unquote(name), [unquote_splicing(vars)])
        end
      end

    quote do
      @doc """
      Starts the C node. It registers under this module's name unless `:name` is given.
      Options: `:name`, `:timeout` (startup, ms).
      """
      def start_link(opts \\ []) do
        opts = Keyword.put_new(opts, :name, __MODULE__)
        exe = Path.join(:code.priv_dir(unquote(app)), unquote(basename))
        Leanler.CNode.start_link(exe, opts)
      end

      @doc false
      def child_spec(opts) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
      end

      unquote_splicing(calls)
    end
  end

  defp spec_type(:string), do: quote(do: binary())
  defp spec_type(:nat), do: quote(do: non_neg_integer())
  defp spec_type(:u64), do: quote(do: non_neg_integer())
  defp spec_type(:bool), do: quote(do: boolean())
end
