defmodule Leanler.E2ETest do
  # Builds test/fixture with the real toolchain and calls it in both modes.
  use ExUnit.Case, async: false

  alias Leanler.{Build, Config}

  @moduletag :e2e
  @moduletag timeout: 600_000
  # The NIF module is compiled by the test itself, after this file.
  @compile {:no_warn_undefined, Leanler.E2ETest.Native}

  @exports [
    add: [symbol: "fixture_add", args: [:u64, :u64], returns: :u64],
    greet: [symbol: "fixture_greet", args: [:string], returns: :string],
    even: [symbol: "fixture_even", args: [:u64], returns: :bool],
    double: [symbol: "fixture_double", args: [:nat], returns: :nat],
    flip: [symbol: "fixture_flip", args: [:bool], returns: :bool]
  ]

  defp config(mode) do
    {:ok, c} =
      Config.parse(
        mode: mode,
        module: Leanler.E2ETest.Native,
        lake_dir: Path.expand("fixture", __DIR__),
        package: "fixture",
        modules: ["Fixture"],
        exports: @exports
      )

    c
  end

  defp tmp(name) do
    dir = Path.join(System.tmp_dir!(), "leanler_#{name}_#{System.unique_integer([:positive])}")
    File.mkdir_p(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "a C node builds, answers every type, refuses bad arguments, and dies with its owner" do
    build = tmp("cnode_build")
    priv = tmp("cnode_priv")
    assert {:ok, :built} = Build.run(config(:cnode), app: :e2e, build_path: build, priv: priv, log: fn _ -> :ok end)
    assert {:ok, :noop} = Build.run(config(:cnode), app: :e2e, build_path: build, priv: priv, log: fn _ -> :ok end)

    if not Node.alive?(), do: {:ok, _} = Node.start(:leanler_e2e, :shortnames)
    exe = Path.join(priv, Build.cnode_basename(:e2e))
    {:ok, pid} = Leanler.CNode.start_link(exe, name: :leanler_e2e_node)

    call = &Leanler.CNode.call(:leanler_e2e_node, &1, &2)
    assert {:ok, 42} = call.(:add, [20, 22])
    assert {:ok, "hello, wörld"} = call.(:greet, ["wörld"])
    assert {:ok, "hello, "} = call.(:greet, [""])
    assert {:ok, true} = call.(:even, [4])
    assert {:ok, false} = call.(:even, [5])
    assert {:ok, 2_000_000_000_000} = call.(:double, [1_000_000_000_000])
    assert {:ok, false} = call.(:flip, [true])
    # wraps like UInt64
    assert {:ok, 0} = call.(:add, [18_446_744_073_709_551_615, 1])

    assert {:error, :badarg} = call.(:add, [1, :two])
    assert {:error, :badarg} = call.(:greet, [123])
    assert {:error, :badarg} = call.(:flip, [:maybe])
    assert {:error, :badarity} = call.(:add, [1])
    assert {:error, :undef} = call.(:nope, [])

    {:ok, os_pid} = os_pid_of(exe)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert eventually(fn -> not alive?(os_pid) end)
    assert {:error, :noproc} = call.(:add, [1, 2])
  end

  test "the NIF builds, answers every type, and refuses bad arguments" do
    build = tmp("nif_build")
    priv = tmp("nif_priv")
    assert {:ok, :built} = Build.run(config(:nif), app: :e2e, build_path: build, priv: priv, log: fn _ -> :ok end)

    # The NIF binds to the module name it was compiled for, so load it from a module of that name.
    Code.compile_string("""
    defmodule Leanler.E2ETest.Native do
      @on_load :load
      def load, do: :erlang.load_nif(~c"#{Path.join(priv, "leanler_e2e")}", 0)
      def add(_, _), do: :erlang.nif_error(:not_loaded)
      def greet(_), do: :erlang.nif_error(:not_loaded)
      def even(_), do: :erlang.nif_error(:not_loaded)
      def double(_), do: :erlang.nif_error(:not_loaded)
      def flip(_), do: :erlang.nif_error(:not_loaded)
    end
    """)

    alias Leanler.E2ETest.Native
    assert {:ok, 42} = Native.add(20, 22)
    assert {:ok, 0} = Native.add(18_446_744_073_709_551_615, 1)
    assert {:ok, "hello, wörld"} = Native.greet("wörld")
    assert {:ok, true} = Native.even(4)
    assert {:ok, 18} = Native.double(9)
    assert {:ok, true} = Native.flip(false)
    assert {:error, :badarg} = Native.add(-1, 2)
    assert {:error, :badarg} = Native.greet(:atom)
    assert {:error, :badarg} = Native.flip(1)

    results =
      1..16
      |> Task.async_stream(fn i -> for n <- 1..2_000, do: Native.add(n, i) end, max_concurrency: 16)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(Enum.with_index(results, 1), fn {r, i} -> r == for(n <- 1..2_000, do: {:ok, n + i}) end)
  end

  test "a missing module is reported by name, not as a crash" do
    c = %{config(:nif) | modules: [{"fixture", "Fixture.Missing"}]}
    assert {:error, msg} = Build.run(c, app: :e2e, build_path: tmp("m"), priv: tmp("p"), log: fn _ -> :ok end)
    assert msg =~ "Fixture.Missing"
  end

  defp os_pid_of(exe) do
    {out, _} = System.cmd("pgrep", ["-f", exe])
    case out |> String.split() |> Enum.map(&Integer.parse/1) do
      [{n, _} | _] -> {:ok, n}
      _ -> {:error, :not_running}
    end
  end

  defp alive?(os_pid), do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(100)
        eventually(fun, tries - 1)
    end
  end
end
