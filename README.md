# Leanler

Call Lean 4 from Elixir as an OTP NIF or a C node. You write no C.

Mark a Lean function `@[export c_symbol]`, list it in `mix.exs`, and `mix compile` does the rest.
Leanler is modelled on [thanos/mojoler](https://github.com/thanos/mojoler), which does this for
Mojo: a Mix compiler builds the native library, and an Elixir call runs the body in the other
language. Leanler keeps that shape for Lean 4 and adds a C node mode beside the NIF. It shares no
code with mojoler; the design, the compiler-in-`mix.exs` approach and the "no hand-written C
layer" goal are theirs. Thank you to thanos for the idea.

## Use

```lean
@[export persona_ask_json]
def ask (request : String) : String := ...
```

```elixir
# mix.exs
def project do
  [
    app: :persona,
    compilers: [:leanler] ++ Mix.compilers(),
    deps: [{:leanler, github: "V-Sekai-fire/leanler"}],
    leanler: [
      mode: :nif,                       # or :cnode
      module: Persona.Native,
      package: "persona",               # the Lake package
      modules: ["Persona.Guest"],       # the modules that hold the exports
      exports: [
        ask: [symbol: "persona_ask_json", args: [:string], returns: :string]
      ]
    ]
  ]
end

# lib/persona/native.ex
defmodule Persona.Native do
  use Leanler
end
```

```elixir
iex> Persona.Native.ask("")
{:ok, ~s({"goal":"delivered","plan":["recharge",...],"reached":true})}
iex> Persona.Native.ask(:not_a_binary)
{:error, :badarg}
```

A call returns `{:ok, value}` or `{:error, reason}`. Nothing raises into the VM.

## Types

| Leanler   | Elixir                          | Lean       |
| --------- | ------------------------------- | ---------- |
| `:string` | binary                          | `String`   |
| `:nat`    | integer, `0..2^64-1`            | `Nat`      |
| `:u64`    | integer, `0..2^64-1`            | `UInt64`   |
| `:bool`   | `true` / `false`                | `Bool`     |

A `Nat` result of 2^63 or more is `{:error, :nat_too_large}`. A `UInt64` wraps as it does in Lean.

## NIF or C node

|                  | `:nif`                              | `:cnode`                                   |
| ---------------- | ----------------------------------- | ------------------------------------------ |
| Runs in          | the VM, on the dirty CPU schedulers | its own OS process, joined through `ei`    |
| A Lean crash     | takes the VM down                   | costs one process; the supervisor restarts it |
| Start            | loads with the module               | `children = [Persona.Native]`              |
| Needs            | nothing                             | a distributed VM (`--sname`)               |
| Artifact         | `priv/leanler_<app>.so`             | `priv/leanler_<app>_cnode`                 |

The C node exits when its stdin closes, so killing the owner leaves no stray process. Choose
`:cnode` for planners that run on untrusted input, deep recursion, or large memory.

## What `mix compile` does

1. `lake build +Module` for each module you name.
2. Follows the `initialize_*` calls in the C that Lean emitted (`.lake/build/ir/**/*.c`) to get
   the exact import closure, across Lake packages and path dependencies. It does not use Lake's
   static archives, because a `lean_lib` archives only its own globs.
3. Compiles that C, plus a generated shim, with the toolchain from the project's
   `lean-toolchain`.
4. Links against `libInit`, `libleanrt`, `libuv`, `libgmp`, and `libStd`/`libLean` when the
   closure reaches them. A published product is replaced by rename, so a failed build keeps the
   old one.

A build is skipped when no emitted C changed. `mix leanler.gen` prints the shim for review.

Requires elan (`lake` and `lean` on `PATH`), a C compiler, Elixir 1.18+, and OTP with
`erl_interface` for `:cnode`.

## Limits

- Lean `panic!` prints and continues. A stack overflow or out-of-memory inside Lean is a
  process crash, which is why `:cnode` exists.
- Lean runs with the runtime module initialised, not the full `lean_initialize`. Code that
  needs the elaborator (`Lean.Environment`, `Lean.Elab`) is not supported.
- Verified on macOS arm64 (Lean 4.34.1, OTP 29). The Linux link line (`--start-group`,
  `--gc-sections`, `-lstdc++`) is written but not run yet.
- A NIF bundles the Lean runtime in the `.so` (13 MB for the persona); a C node is 100 MB when
  `libLean` is reachable.

## Test

```
mix test              # 61 tests: 4 doctests, 19 properties, 38 examples
mix dialyzer          # types (dialyxir); runs clean
LEANLER_REGOLD=1 mix test test/golden_test.exs   # rewrite golden files; read the diff first
```

The suite builds `test/fixture` (a small Lake project) once, in both modes, and runs everything
against the real NIF and the real C node.

| Kind | File | What it pins |
| ---- | ---- | ------------ |
| **Golden** | `test/golden_test.exs`, `test/golden/` | The generated NIF and C node shims for a fixed config, byte for byte. A table of 23 calls with exact answers, run against both builds. |
| **Invariant** | `test/invariant_test.exs` | [StreamData](https://hex.pm/packages/stream_data) properties, on both builds: `UInt64` wraps, `greet` returns the input byte for byte (valid UTF-8, NUL, 4-byte code points), `Nat` doubles exactly or says `:nat_too_large` at 2^63, a bad argument is `{:error, :badarg}` and does not poison the next call, and the NIF and C node agree. On the generator: every export is bound, braces balance, output is deterministic and never raises into the VM, name mangling is C-safe and injective, `Config.parse` never raises. |
| **Control** | `test/control_test.exs` | The checks can fail. The reference passes every invariant. Each invariant has a planted wrong implementation and must catch it. The generators must reach 0, 2^64-1, multi-byte text and NUL. A changed golden expectation, a wrong implementation and a one-character change to a shim are each reported. |

Changing the Lean fixture's `greet` or the generator's scheduler flag turns the golden and
invariant tests red, and reverting turns them green.

## Licence

MIT.
