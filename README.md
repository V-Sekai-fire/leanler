# Leanler

Call Lean 4 from Elixir as an OTP NIF or a C node. You write no C.

Mark a Lean function `@[export c_symbol]`, list it in `mix.exs`, and `mix compile` does the rest.
Leanler is the Lean counterpart of [thanos/mojoler](https://github.com/thanos/mojoler): same idea,
different language, and a C node mode as well as a NIF.

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
mix test        # unit tests, plus an end-to-end build of test/fixture in both modes
```

The end-to-end test builds a small Lake project, calls every type through the NIF and the C
node, sends bad arguments, and checks that the C node process dies with its owner.

## Licence

MIT.
