defmodule Leanler.Gen do
  @moduledoc """
  Emits the C that joins Lean's exported functions to the BEAM.

  `nif/2` writes an Erlang NIF library. `cnode/2` writes a C node: an executable that
  joins the Erlang cluster through `ei` and answers `{from, ref, function, {arg, ...}}` messages.
  Both call the same Lean `@[export]` symbols and map values the same way:

  | Leanler type | Erlang term                      | Lean / C                |
  | ------------ | -------------------------------- | ----------------------- |
  | `:string`    | binary (UTF-8)                   | `String`, `lean_object*`|
  | `:nat`       | non-negative integer below 2^64  | `Nat`, `lean_object*`   |
  | `:u64`       | non-negative integer below 2^64  | `UInt64`                |
  | `:bool`      | `true` or `false`                | `Bool`, `uint8_t`       |

  A call answers `{:ok, value}` or `{:error, reason}`. A bad argument is `{:error, :badarg}`; the
  generated code never raises into the VM. A `Nat` result of 2^63 or more is
  `{:error, :nat_too_large}`.
  """

  alias Leanler.Config

  @doc "C source for the NIF library. `roots` come from `Leanler.Lake.closure/1`."
  @spec nif(Config.t(), [Leanler.Lake.unit()]) :: String.t()
  def nif(%Config{} = config, roots) do
    flag = if config.dirty, do: "ERL_NIF_DIRTY_JOB_CPU_BOUND", else: "0"

    table =
      Enum.map_join(config.exports, ",\n", fn e ->
        ~s|    {"#{e.name}", #{length(e.args)}, nif_#{e.name}, #{flag}}|
      end)

    functions = Enum.map_join(config.exports, "\n", &nif_function/1)

    """
    #{banner()}
    #include <erl_nif.h>
    #include <string.h>
    #include <stdint.h>
    #include <lean/lean.h>

    #{lean_decls(config, roots)}

    static ERL_NIF_TERM leanler_error(ErlNifEnv *env, const char *reason) {
      return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, reason));
    }

    static ERL_NIF_TERM leanler_ok(ErlNifEnv *env, ERL_NIF_TERM value) {
      return enif_make_tuple2(env, enif_make_atom(env, "ok"), value);
    }

    static ERL_NIF_TERM leanler_string(ErlNifEnv *env, lean_object *s) {
      size_t n = lean_string_size(s) - 1;
      ERL_NIF_TERM bin;
      unsigned char *out = enif_make_new_binary(env, n, &bin);
      if (out == NULL) {
        lean_dec(s);
        return leanler_error(env, "alloc");
      }
      memcpy(out, lean_string_cstr(s), n);
      lean_dec(s);
      return leanler_ok(env, bin);
    }

    static ERL_NIF_TERM leanler_nat(ErlNifEnv *env, lean_object *n) {
      if (!lean_is_scalar(n)) {
        lean_dec(n);
        return leanler_error(env, "nat_too_large");
      }
      return leanler_ok(env, enif_make_uint64(env, (uint64_t)lean_unbox(n)));
    }

    #{lean_init(config, roots)}

    static int leanler_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
      (void)env; (void)priv; (void)info;
      return leanler_init_lean() ? 0 : 1;
    }

    #{functions}

    static ErlNifFunc leanler_funcs[] = {
    #{table}
    };

    ERL_NIF_INIT(Elixir.#{inspect(config.module)}, leanler_funcs, leanler_load, NULL, NULL, NULL)
    """
    |> String.replace("Elixir.Elixir.", "Elixir.")
  end

  @doc "C source for the C node executable."
  @spec cnode(Config.t(), [Leanler.Lake.unit()]) :: String.t()
  def cnode(%Config{} = config, roots) do
    dispatch =
      Enum.map_join(config.exports, "\n", fn e ->
        """
          if (strcmp(fun, "#{e.name}") == 0) return cn_#{e.name}(buf, idx, nargs, out);
        """
      end)

    functions = Enum.map_join(config.exports, "\n", &cnode_function/1)

    """
    #{banner()}
    #include <ei.h>
    #include <pthread.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <stdint.h>
    #include <unistd.h>
    #include <lean/lean.h>

    #{lean_decls(config, roots)}

    #{lean_init(config, roots)}

    static void cn_error(ei_x_buff *out, const char *reason) {
      ei_x_encode_tuple_header(out, 2);
      ei_x_encode_atom(out, "error");
      ei_x_encode_atom(out, reason);
    }

    static void cn_ok_open(ei_x_buff *out) {
      ei_x_encode_tuple_header(out, 2);
      ei_x_encode_atom(out, "ok");
    }

    static void cn_string(ei_x_buff *out, lean_object *s) {
      cn_ok_open(out);
      ei_x_encode_binary(out, lean_string_cstr(s), (long)(lean_string_size(s) - 1));
      lean_dec(s);
    }

    static void cn_nat(ei_x_buff *out, lean_object *n) {
      if (!lean_is_scalar(n)) {
        lean_dec(n);
        cn_error(out, "nat_too_large");
        return;
      }
      cn_ok_open(out);
      ei_x_encode_ulonglong(out, (unsigned long long)lean_unbox(n));
    }

    /* Reads a binary argument into a NUL-free heap copy. NULL on a type mismatch. */
    static char *cn_binary(const char *buf, int *idx, long *len) {
      int type = 0, size = 0;
      if (ei_get_type(buf, idx, &type, &size) != 0 || type != ERL_BINARY_EXT) return NULL;
      char *data = malloc((size_t)size + 1);
      if (data == NULL) return NULL;
      if (ei_decode_binary(buf, idx, data, len) != 0) {
        free(data);
        return NULL;
      }
      return data;
    }

    #{functions}

    static void cn_dispatch(const char *fun, const char *buf, int idx, int nargs, ei_x_buff *out) {
    #{dispatch}
      cn_error(out, "undef");
    }

    /* The BEAM closes our stdin when the owning port closes or the VM dies. Exit then, so a
       killed owner cannot leave this process behind. */
    static void *cn_watch_stdin(void *arg) {
      char c;
      (void)arg;
      while (read(0, &c, 1) > 0) { }
      _exit(0);
      return NULL;
    }

    int main(int argc, char **argv) {
      if (argc != 4) {
        fprintf(stderr, "usage: LEANLER_COOKIE=... %s <alive> <parent-node> <registered-name>\\n", argv[0]);
        return 2;
      }
      const char *alive = argv[1];
      const char *parent = argv[2];
      const char *registered = argv[3];
      const char *cookie = getenv("LEANLER_COOKIE");
      const char *at = strchr(parent, '@');
      if (cookie == NULL || at == NULL) {
        fprintf(stderr, "leanler: need LEANLER_COOKIE and a name@host parent node\\n");
        return 2;
      }
      char thisnode[512];
      snprintf(thisnode, sizeof thisnode, "%s@%s", alive, at + 1);

      if (!leanler_init_lean()) {
        fprintf(stderr, "leanler: Lean initialization failed\\n");
        return 3;
      }
      ei_init();
      ei_cnode ec;
      if (ei_connect_xinit(&ec, at + 1, alive, thisnode, NULL, cookie, 0) < 0) {
        fprintf(stderr, "leanler: ei_connect_xinit failed\\n");
        return 4;
      }
      int fd = ei_connect(&ec, (char *)parent);
      if (fd < 0) {
        fprintf(stderr, "leanler: cannot connect to %s\\n", parent);
        return 5;
      }

      pthread_t watcher;
      if (pthread_create(&watcher, NULL, cn_watch_stdin, NULL) == 0) pthread_detach(watcher);

      ei_x_buff ready;
      ei_x_new_with_version(&ready);
      ei_x_encode_tuple_header(&ready, 2);
      ei_x_encode_atom(&ready, "leanler_ready");
      ei_x_encode_pid(&ready, ei_self(&ec));
      ei_reg_send(&ec, fd, (char *)registered, ready.buff, ready.index);
      ei_x_free(&ready);

      ei_x_buff in;
      ei_x_new(&in);
      for (;;) {
        erlang_msg msg;
        int r = ei_xreceive_msg(fd, &msg, &in);
        if (r == ERL_TICK) continue;
        if (r == ERL_ERROR) break;
        if (msg.msgtype != ERL_SEND && msg.msgtype != ERL_REG_SEND) continue;

        int idx = 0, version = 0, arity = 0, nargs = 0;
        erlang_pid from;
        erlang_ref ref;
        char fun[MAXATOMLEN];
        if (ei_decode_version(in.buff, &idx, &version) != 0) continue;
        if (ei_decode_tuple_header(in.buff, &idx, &arity) != 0 || arity != 4) continue;
        if (ei_decode_pid(in.buff, &idx, &from) != 0) continue;
        if (ei_decode_ref(in.buff, &idx, &ref) != 0) continue;
        if (ei_decode_atom(in.buff, &idx, fun) != 0) continue;
        if (ei_decode_tuple_header(in.buff, &idx, &nargs) != 0) continue;

        ei_x_buff out;
        ei_x_new_with_version(&out);
        ei_x_encode_tuple_header(&out, 2);
        ei_x_encode_ref(&out, &ref);
        if (strcmp(fun, "stop") == 0) {
          cn_ok_open(&out);
          ei_x_encode_atom(&out, "stopped");
          ei_send(fd, &from, out.buff, out.index);
          ei_x_free(&out);
          break;
        }
        cn_dispatch(fun, in.buff, idx, nargs, &out);
        ei_send(fd, &from, out.buff, out.index);
        ei_x_free(&out);
      }
      ei_x_free(&in);
      return 0;
    }
    """
  end

  # -- shared ---------------------------------------------------------------------------------

  defp banner do
    "/* Generated by Leanler. Do not edit: change the :leanler configuration in mix.exs. */"
  end

  defp c_type(:string), do: "lean_object *"
  defp c_type(:nat), do: "lean_object *"
  defp c_type(:u64), do: "uint64_t "
  defp c_type(:bool), do: "uint8_t "

  defp lean_decls(config, roots) do
    inits =
      Enum.map_join(roots, "\n", fn r ->
        "extern lean_object *#{r.symbol}(#{init_params(r.arity)});"
      end)

    exports =
      Enum.map_join(config.exports, "\n", fn e ->
        params = if e.args == [], do: "void", else: Enum.map_join(e.args, ", ", &c_type/1)
        "extern #{c_type(e.returns)}#{e.symbol}(#{params});"
      end)

    inits <> "\n" <> exports <> "\nextern void lean_initialize_runtime_module(void);\nextern void lean_io_mark_end_initialization(void);"
  end

  defp init_params(1), do: "uint8_t builtin"
  defp init_params(2), do: "uint8_t builtin, lean_object *world"

  defp lean_init(_config, roots) do
    calls =
      Enum.map_join(roots, "\n", fn r ->
        args = if r.arity == 1, do: "1", else: "1, lean_io_mk_world()"

        """
          res = #{r.symbol}(#{args});
          if (!lean_io_result_is_ok(res)) {
            lean_io_result_show_error(res);
            lean_dec_ref(res);
            return 0;
          }
          lean_dec_ref(res);
        """
      end)

    """
    static int leanler_init_lean(void) {
      static int done = 0;
      lean_object *res;
      if (done) return 1;
      lean_initialize_runtime_module();
    #{calls}
      lean_io_mark_end_initialization();
      done = 1;
      return 1;
    }
    """
  end

  # -- NIF ------------------------------------------------------------------------------------

  defp nif_function(e) do
    n = length(e.args)

    parse =
      e.args
      |> Enum.with_index()
      |> Enum.map_join("\n", fn
        {:string, i} ->
          "  ErlNifBinary a#{i};\n  if (!enif_inspect_binary(env, argv[#{i}], &a#{i})) return leanler_error(env, \"badarg\");"

        {t, i} when t in [:nat, :u64] ->
          "  ErlNifUInt64 a#{i};\n  if (!enif_get_uint64(env, argv[#{i}], &a#{i})) return leanler_error(env, \"badarg\");"

        {:bool, i} ->
          "  uint8_t a#{i};\n  if (enif_is_identical(argv[#{i}], enif_make_atom(env, \"true\"))) a#{i} = 1;\n  else if (enif_is_identical(argv[#{i}], enif_make_atom(env, \"false\"))) a#{i} = 0;\n  else return leanler_error(env, \"badarg\");"
      end)

    build =
      e.args
      |> Enum.with_index()
      |> Enum.map_join("\n", fn
        {:string, i} ->
          "  lean_object *l#{i} = lean_mk_string_from_bytes(a#{i}.size == 0 ? \"\" : (const char *)a#{i}.data, a#{i}.size);"

        {:nat, i} ->
          "  lean_object *l#{i} = lean_uint64_to_nat((uint64_t)a#{i});"

        {:u64, i} ->
          "  uint64_t l#{i} = (uint64_t)a#{i};"

        {:bool, i} ->
          "  uint8_t l#{i} = a#{i};"
      end)

    call_args = Enum.map_join(0..(n - 1)//1, ", ", &"l#{&1}")

    result =
      case e.returns do
        :string ->
          "  return leanler_string(env, r);"

        :nat ->
          "  return leanler_nat(env, r);"

        :u64 ->
          "  return leanler_ok(env, enif_make_uint64(env, (ErlNifUInt64)r));"

        :bool ->
          "  return leanler_ok(env, enif_make_atom(env, r ? \"true\" : \"false\"));"
      end

    """
    static ERL_NIF_TERM nif_#{e.name}(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
      (void)argc; (void)argv;
    #{parse}
    #{build}
      #{c_type(e.returns)}r = #{e.symbol}(#{call_args});
    #{result}
    }
    """
  end

  # -- C node ---------------------------------------------------------------------------------

  defp cnode_function(e) do
    n = length(e.args)

    parse =
      e.args
      |> Enum.with_index()
      |> Enum.map_join("\n", fn
        {:string, i} ->
          "  long len#{i} = 0;\n  char *a#{i} = cn_binary(buf, &idx, &len#{i});\n  if (a#{i} == NULL) { #{free_prior(i, e.args)} cn_error(out, \"badarg\"); return; }"

        {t, i} when t in [:nat, :u64] ->
          "  unsigned long long a#{i} = 0;\n  if (ei_decode_ulonglong(buf, &idx, &a#{i}) != 0) { #{free_prior(i, e.args)} cn_error(out, \"badarg\"); return; }"

        {:bool, i} ->
          "  int a#{i} = 0;\n  if (ei_decode_boolean(buf, &idx, &a#{i}) != 0) { #{free_prior(i, e.args)} cn_error(out, \"badarg\"); return; }"
      end)

    build =
      e.args
      |> Enum.with_index()
      |> Enum.map_join("\n", fn
        {:string, i} ->
          "  lean_object *l#{i} = lean_mk_string_from_bytes(a#{i}, (size_t)len#{i});\n  free(a#{i});"

        {:nat, i} ->
          "  lean_object *l#{i} = lean_uint64_to_nat((uint64_t)a#{i});"

        {:u64, i} ->
          "  uint64_t l#{i} = (uint64_t)a#{i};"

        {:bool, i} ->
          "  uint8_t l#{i} = (uint8_t)a#{i};"
      end)

    call_args = Enum.map_join(0..(n - 1)//1, ", ", &"l#{&1}")

    result =
      case e.returns do
        :string ->
          "  cn_string(out, r);"

        :nat ->
          "  cn_nat(out, r);"

        :u64 ->
          "  cn_ok_open(out);\n  ei_x_encode_ulonglong(out, (unsigned long long)r);"

        :bool ->
          "  cn_ok_open(out);\n  ei_x_encode_boolean(out, r ? 1 : 0);"
      end

    """
    static void cn_#{e.name}(const char *buf, int idx, int nargs, ei_x_buff *out) {
      if (nargs != #{n}) { cn_error(out, "badarity"); return; }
    #{parse}
    #{build}
      #{c_type(e.returns)}r = #{e.symbol}(#{call_args});
    #{result}
    }
    """
  end

  defp free_prior(i, args) do
    args
    |> Enum.with_index()
    |> Enum.filter(fn {t, j} -> j < i and t == :string end)
    |> Enum.map_join(" ", fn {_t, j} -> "free(a#{j});" end)
  end
end
