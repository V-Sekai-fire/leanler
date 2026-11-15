defmodule Leanler.Build do
  @moduledoc """
  Builds a project's Lean code into a NIF library or a C node executable.

  The steps: `lake build` the configured modules, follow their imports to the C Lean emitted,
  compile that C and a generated shim (`Leanler.Gen`), link against the toolchain's runtime
  archives, and publish by rename so a failed build leaves the previous product in place.

  Everything returns `{:ok, :built | :noop}` or `{:error, message}`.
  """

  alias Leanler.{Config, Gen, Lake}

  @generator_version 1

  @doc "Name of the published NIF library, without extension: `leanler_<app>`."
  @spec nif_basename(atom()) :: String.t()
  def nif_basename(app), do: "leanler_#{app}"

  @doc "Name of the published C node executable: `leanler_<app>_cnode`."
  @spec cnode_basename(atom()) :: String.t()
  def cnode_basename(app), do: "leanler_#{app}_cnode"

  @doc """
  Runs the build for `config` in the current Mix project.

  Options: `:app` (default `Mix.Project.config()[:app]`), `:build_path`, `:priv`, `:log`
  (a 1-arity function, default `Mix.shell().info/1`).
  """
  @spec run(Config.t(), keyword()) :: {:ok, :built | :noop} | {:error, String.t()}
  def run(%Config{} = config, opts \\ []) do
    app = Keyword.get_lazy(opts, :app, fn -> Mix.Project.config()[:app] end)
    build_path = Keyword.get_lazy(opts, :build_path, &Mix.Project.build_path/0)
    priv = Keyword.get_lazy(opts, :priv, fn -> Path.join(Mix.Project.app_path(), "priv") end)
    log = Keyword.get(opts, :log, fn line -> Mix.shell().info(line) end)
    work = Path.join(build_path, "leanler")
    product = Path.join(priv, product_name(config, app))

    with :ok <- Lake.build(config),
         {:ok, prefix} <- Lake.prefix(config),
         {:ok, closure} <- Lake.closure(config) do
      fingerprint = fingerprint(config, prefix, closure)
      stamp = Path.join(work, "FINGERPRINT")

      if File.exists?(product) and File.read(stamp) == {:ok, fingerprint} do
        {:ok, :noop}
      else
        with :ok <- File.mkdir_p(work),
             :ok <- File.mkdir_p(priv),
             {:ok, objects} <- compile_units(config, prefix, closure.units, work, log),
             {:ok, shim} <- compile_shim(config, prefix, closure.roots, work, log),
             {:ok, staged} <- link(config, prefix, closure, [shim | objects], work, app, log),
             :ok <- File.rename(staged, product),
             :ok <- File.write(stamp, fingerprint) do
          {:ok, :built}
        else
          {:error, reason} when is_atom(reason) -> {:error, "leanler: file operation failed: #{reason}"}
          {:error, _} = error -> error
        end
      end
    end
  end

  defp product_name(%Config{mode: :nif}, app), do: nif_basename(app) <> ".so"
  defp product_name(%Config{mode: :cnode}, app), do: cnode_basename(app)

  defp fingerprint(config, prefix, closure) do
    files =
      Enum.map(closure.units, fn u ->
        {:ok, stat} = File.stat(u.file, time: :posix)
        {u.file, stat.size, stat.mtime}
      end)

    generator = Enum.map([Gen, __MODULE__], & &1.module_info(:md5))
    :crypto.hash(:sha256, :erlang.term_to_binary({@generator_version, generator, config, prefix, files}))
    |> Base.encode16(case: :lower)
  end

  # -- compile --------------------------------------------------------------------------------

  defp cflags(prefix), do: ["-O2", "-fPIC", "-w", "-I", Path.join(prefix, "include")]

  defp compile_units(config, prefix, units, work, log) do
    obj_dir = Path.join(work, "obj")

    with :ok <- File.mkdir_p(obj_dir) do
      tag = :crypto.hash(:sha256, :erlang.term_to_binary({config.cc, prefix})) |> Base.encode16(case: :lower) |> binary_part(0, 8)

      results =
        units
        |> Task.async_stream(
          fn u ->
            obj = Path.join(obj_dir, "#{u.symbol}-#{tag}.o")

            if fresh?(obj, u.file) do
              {:ok, obj}
            else
              cc(config, ["-c", u.file, "-o", obj | cflags(prefix)], obj, log)
            end
          end,
          max_concurrency: System.schedulers_online(),
          timeout: :infinity,
          ordered: true
        )
        |> Enum.map(fn {:ok, result} -> result end)

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> {:ok, Enum.map(results, fn {:ok, o} -> o end)}
        {:error, _} = error -> error
      end
    end
  end

  defp fresh?(obj, source) do
    with {:ok, o} <- File.stat(obj, time: :posix),
         {:ok, s} <- File.stat(source, time: :posix) do
      o.mtime >= s.mtime
    else
      _ -> false
    end
  end

  defp compile_shim(config, prefix, roots, work, log) do
    source = Path.join(work, "shim.c")
    obj = Path.join(work, "shim.o")
    text = if config.mode == :nif, do: Gen.nif(config, roots), else: Gen.cnode(config, roots)

    with :ok <- File.write(source, text) do
      extra = if config.mode == :nif, do: ["-I", erts_include()], else: ["-I", ei_dir("include")]
      cc(config, ["-c", source, "-o", obj, "-O2", "-fPIC", "-Wall", "-Wextra", "-Wno-unused-parameter", "-I", Path.join(prefix, "include") | extra], obj, log)
    end
  end

  defp cc(config, args, obj, log) do
    case System.find_executable(config.cc) do
      nil ->
        {:error, "leanler: C compiler `#{config.cc}` not found"}

      cc ->
        case System.cmd(cc, args, stderr_to_stdout: true) do
          {_out, 0} ->
            {:ok, obj}

          {out, code} ->
            log.("leanler: #{config.cc} #{Enum.join(args, " ")}")
            {:error, "leanler: #{config.cc} exited #{code} building #{Path.basename(obj)}:\n#{out}"}
        end
    end
  end

  # -- link -----------------------------------------------------------------------------------

  defp link(config, prefix, closure, objects, work, app, log) do
    staged = Path.join(work, "staged-" <> product_name(config, app))
    lean_lib = Path.join([prefix, "lib", "lean"])

    # Lean imports Std and Init; Lean's C++ half (kernel, util) lives in libleancpp.
    wanted = closure.toolchain ++ ["Init"]
    wanted = if "Lean" in wanted, do: wanted ++ ["Std", "leancpp"], else: wanted

    archives =
      wanted
      |> Enum.uniq()
      |> Enum.sort_by(fn
        "Lean" -> 0
        "leancpp" -> 1
        "Std" -> 2
        "Init" -> 3
      end)
      |> Enum.map(&Path.join(lean_lib, "lib#{&1}.a"))
      |> Kernel.++([
        Path.join(lean_lib, "libleanrt.a"),
        Path.join([prefix, "lib", "libuv.a"]),
        Path.join([prefix, "lib", "libgmp.a"])
      ])

    {flavor, _libs} = platform()

    case {flavor, config.mode} do
      {:linux, :nif} -> link_shared(config, prefix, lean_lib, objects, staged, log)
      _ -> link_static(config, prefix, flavor, archives, objects, staged, log)
    end
  end

  # Lean's static runtime on x86-64 Linux is not position independent (libleanrt.a has
  # local-exec TLS relocations), so a NIF cannot embed it. Link the toolchain's own shared
  # libraries instead, which carry the runtime, Init, Std and Lean, and record their directories
  # as rpath. The NIF then needs the toolchain it was built with at run time.
  defp link_shared(config, prefix, lean_lib, objects, staged, log) do
    shared = ["libInit_shared.so", "libleanshared.so"]
    missing = shared |> Enum.map(&Path.join(lean_lib, &1)) |> Enum.reject(&File.exists?/1)

    if missing != [] do
      {:error, "leanler: toolchain shared libraries missing: #{Enum.join(missing, ", ")}"}
    else
      args =
        ["-shared", "-o", staged | objects] ++
          ["-L", lean_lib, "-lInit_shared", "-lleanshared"] ++
          ["-Wl,-rpath," <> lean_lib, "-Wl,-rpath," <> Path.join(prefix, "lib")] ++
          ["-lm", "-ldl", "-lpthread"]

      with {:ok, _} <- cc(config, args, staged, log), do: {:ok, staged}
    end
  end

  defp link_static(config, prefix, flavor, archives, objects, staged, log) do
    # On Linux the runtime is built against the toolchain's own libc++, not libstdc++.
    cpp =
      case flavor do
        :darwin -> []
        :linux -> Enum.map(["libc++.a", "libc++abi.a", "libunwind.a"], &Path.join([prefix, "lib", &1]))
      end

    needed = archives ++ cpp
    missing = Enum.reject(needed, &File.exists?/1)

    if missing != [] do
      {:error, "leanler: toolchain archives missing: #{Enum.join(missing, ", ")}"}
    else
      system = if flavor == :darwin, do: ["-lc++", "-lpthread"], else: ["-lm", "-ldl", "-lpthread"]

      args =
        case config.mode do
          :nif ->
            ["-dynamiclib", "-undefined", "dynamic_lookup", "-o", staged | objects] ++
              group(flavor, archives) ++ system

          :cnode ->
            strip = if flavor == :darwin, do: ["-Wl,-dead_strip"], else: ["-Wl,--gc-sections"]

            ["-o", staged | objects] ++
              strip ++ group(flavor, needed) ++ ["-L", ei_dir("lib"), "-lei"] ++ system
        end

      with {:ok, _} <- cc(config, args, staged, log), do: {:ok, staged}
    end
  end

  defp group(:linux, archives), do: ["-Wl,--start-group" | archives] ++ ["-Wl,--end-group"]
  defp group(:darwin, archives), do: archives

  defp platform do
    case :os.type() do
      {:unix, :darwin} -> {:darwin, []}
      {:unix, _} -> {:linux, []}
    end
  end

  defp erts_include do
    Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "include"])
  end

  # erl_interface is not an application Mix puts on the code path, so find it by name.
  defp ei_dir(sub) do
    root = to_string(:code.root_dir())

    base =
      [root, "lib", "erl_interface-*"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.sort()
      |> List.last()

    Path.join(base || Path.join([root, "lib", "erl_interface-not-installed"]), sub)
  end
end
