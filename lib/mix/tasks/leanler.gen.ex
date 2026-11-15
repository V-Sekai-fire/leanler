defmodule Mix.Tasks.Leanler.Gen do
  @shortdoc "Prints the generated C shim for the project's Lean exports"
  @moduledoc """
  Prints the C that `mix compile` would build, for review.

      mix leanler.gen            # the shim for the configured :mode
      mix leanler.gen --out dir  # write it to dir/shim.c

  The Lean modules must already be built (`lake build`), since the initializer arity is read from
  the C Lean emitted.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [out: :string])

    with {:ok, config} <- Leanler.Config.parse(Mix.Project.config()[:leanler]),
         {:ok, closure} <- Leanler.Lake.closure(config) do
      text =
        case config.mode do
          :nif -> Leanler.Gen.nif(config, closure.roots)
          :cnode -> Leanler.Gen.cnode(config, closure.roots)
        end

      case Keyword.fetch(opts, :out) do
        {:ok, dir} ->
          :ok = File.mkdir_p(dir)
          :ok = File.write(Path.join(dir, "shim.c"), text)
          Mix.shell().info("wrote #{Path.join(dir, "shim.c")}")

        :error ->
          Mix.shell().info(text)
      end
    else
      {:error, message} -> Mix.shell().error(message)
    end
  end
end
