defmodule Mix.Tasks.Compile.Leanler do
  @moduledoc """
  Builds the project's Lean code into a NIF library or C node executable.

  Add it to the project:

      compilers: [:leanler] ++ Mix.compilers()

  and configure `leanler:` (see `Leanler.Config`). Lake does its own incremental build, and the
  link step is skipped when no emitted C changed.
  """
  use Mix.Task.Compiler

  alias Mix.Task.Compiler.Diagnostic

  @impl true
  def run(_args) do
    with {:ok, config} <- Leanler.Config.parse(Mix.Project.config()[:leanler]),
         {:ok, result} <- Leanler.Build.run(config) do
      case result do
        :built -> {:ok, []}
        :noop -> {:noop, []}
      end
    else
      {:error, message} ->
        Mix.shell().error(message)

        {:error,
         [
           %Diagnostic{
             compiler_name: "leanler",
             file: "mix.exs",
             message: message,
             position: nil,
             severity: :error
           }
         ]}
    end
  end

  @impl true
  def clean do
    work = Path.join(Mix.Project.build_path(), "leanler")
    File.rm_rf(work)
    :ok
  end
end
