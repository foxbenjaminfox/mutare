defmodule Mutare.Transform.Imports do
  @moduledoc false
  # The `import` *vocabulary* — the env-building, resolution, stamping, and reading rules for
  # `import`, the bare-call counterpart to `Mutare.Transform.Aliases`. The unified lexical
  # walk in `Mutare.Transform.Resolve` folds the import env (`register/4`) interleaved with
  # the alias env, and stamps each bare call (`stamp/6`) as it descends; this module is pure
  # rules.
  #
  # The call-matching mutator families recognise a call by its module — `Enum.reject`,
  # `String.upcase`. `Aliases` lets them see through an `alias` (`S.upcase` →
  # `String.upcase`). But a *bare* call after an `import` (`import Enum; reject(xs, f)`)
  # has no module written at all, so every one of them misses it. This supplies the missing
  # module: `Resolve` stamps each *bare-call* node with the module it resolves to
  # (`meta[:mutare_import]`), so the same families mutate it.
  # `Mutare.Transform.Calls.resolved_call/1` is the reader.
  #
  # ## What makes this sound without reconstructing the compiler
  #
  # We never resolve an import to a *definition* — only to a *module*. The compiler does
  # the hard part for us: any **compiling** bare call is unambiguous. Specifically (all
  # verified against Elixir):
  #
  #   * `import Enum` then a local `def reject/2`, or two whole imports of `reject/2`, or
  #     shadowing a `Kernel` name via a plain import, are **compile errors**. So if the
  #     source compiles and `import Enum` is in scope and Enum exports `reject/2`, then a
  #     bare `reject(x, y)` *is* `Enum.reject/2` — nothing else could be.
  #   * Resolution is strictly **per-arity** (`import M, only: [f: 1]` then `f(1, 2)` is a
  #     compile error). So we must know a module's exported *arities*; we learn them by
  #     **runtime reflection** (`function_exported?`/`macro_exported?`) — precise for the
  #     stdlib (always loaded, and the only modules our mutators target), and conservatively
  #     skipped for any module that isn't loadable (a target/dep module — never targeted).
  #   * The **only** way to displace a `Kernel` function is `import Kernel, except:/only:`.
  #     A plain import can't silently shadow it. So a bare `Kernel` call (`abs`, `min`) is
  #     the `Kernel` one unless the tracked `Kernel` selector says otherwise — in which case
  #     we stamp `meta[:mutare_kernel_displaced]` so the bare-`Kernel` mutator families
  #     (`Numeric`, `CallRemoval`) skip it.
  #
  # ## Diff: bare vs qualified rebuild
  #
  # The stamp carries a `rebuild_kind`. `:bare` keeps the clean diff (`reject`→`filter`) but is
  # only sound when the swap's sibling is unambiguously bare-callable to the same module — so
  # it is used only for the **sole whole import** with an unmanipulated `Kernel` (`rebuild_kind/3`).
  # Otherwise (`:only`/`:except`/`only: :functions`, *or* a whole import that isn't the only one
  # in scope) the mutant is `:qualify`'d (`reject`→`Elixir.Enum.filter(...)`): a selective
  # import's sibling may not be imported, and a second import can make a bare sibling ambiguous
  # or point it at the wrong module. `Mutare.Transform.Calls` builds the matching rebuild closure
  # and makes the qualifier **alias-proof** (the `Elixir.` prefix / Erlang atom), so it always
  # names the captured module regardless of aliases or imports at the call site.
  #
  # Erlang atom modules import the same way (`import :binary`; `import :binary, only: …`).
  # The module key is then the atom itself (`:binary`), and reflection works on it just as
  # for an Elixir module (`function_exported?(:binary, …)`); a bare `split` after
  # `import :binary` resolves to `{:binary, …}`.
  #
  # ## Scope and limits (beyond the inherited `alias` limits)
  #
  #   * Operator displacement (`import Kernel, except: [+: 2]` + a custom `+`) is out of
  #     scope: the operator families (Arithmetic/Relational/Logical) don't read the stamp.
  #   * A `use`-injected import is surfaced by `Mutare.Transform.Uses` when the `use` is
  #     expandable (static args, loadable module): its directives are folded through `register/4`
  #     like a textual import. A *non-expandable* `use` (dynamic args, non-loadable target) or a
  #     non-`use` macro-generated import is still invisible — and unlike the visible cases this
  #     can be *wrong*, not just missed: a `use` that re-imports a module we target with `except:`
  #     (removing a function) and supplies it from elsewhere makes us mis-resolve the bare call to
  #     the wrong module (see NOTES "Correctness boundary"). Each stamped imported call therefore
  #     also carries a resolution witness: generated mutant branches can re-import the believed
  #     provider in an unreachable expression, turning that hidden replacement into an ambiguity
  #     compile error instead of a wrong surviving mutant.

  alias Mutare.AST
  alias Mutare.Mutator
  alias Mutare.Transform.Aliases

  @import_key :mutare_import
  @import_witness_key :mutare_import_witness
  @kernel_displaced_key :mutare_kernel_displaced

  @typedoc """
  A module's in-scope import selection: a `{base, except}` pair (the `kernel` slot uses the
  same shape). `base` is `:all`, `{:only, set}`, or `{:kind, :functions|:macros|:sigils}`;
  `except` is the cumulative `{fun, arity}` set subtracted from it. Modelling `except` as a
  *subtraction from the prior selection* — not "all minus except" — is what makes repeated
  imports of the same module correct, per Elixir: `import Enum, only: [a, b]; import Enum,
  except: [a]` leaves only `b`, and `import Enum; import Enum, except: [a]` leaves all-but-`a`.
  """
  @type selector :: {:all | {:only, MapSet.t()} | {:kind, atom()}, MapSet.t()}

  @doc "The default whole-import selection (`import Mod` with no options); seeds the Kernel slot."
  @spec default_selector() :: selector()
  def default_selector, do: {:all, MapSet.new()}

  @doc """
  Fold an `import` directive into the `{imports, kernel}` environment, given the alias env in
  force (to resolve `import E` where `E` is an alias). The directive's own selection
  (`:all`/`only:`/`except:`/`only: :functions`) is **combined** with any prior import of the
  same module: `only:`/a plain `import` replace the selection, `except:` subtracts from it (so
  repeated imports of one module compose as Elixir does). `import Kernel, …` combines into the
  tracked Kernel selector likewise. Every non-import statement passes the env through unchanged.
  Resolution is by *module*; exported arities are checked later, at the call, by `stamp/6`.
  """
  @spec register(Macro.t(), map(), map(), selector()) :: {map(), selector()}
  def register({:import, _meta, args}, aliases, imports, kernel),
    do: register_import(args, aliases, imports, kernel)

  def register(_stmt, _aliases, imports, kernel), do: {imports, kernel}

  @doc """
  The metadata for a bare call, stamped with the module it resolves to (`:mutare_import` —
  the useful, positive resolution) or marked `:mutare_kernel_displaced` (a `Kernel` name no
  longer in `Kernel`, so the bare-`Kernel` families skip it), or returned unchanged for a
  local/default-`Kernel` call. `pipe_mode` (`:piped`/`:unpiped`) recovers the effective arity
  (a pipe stage carries one fewer written arg than the source reads).
  """
  @spec stamp(atom(), keyword(), [Macro.t()], map(), selector(), Mutator.pipe_mode()) :: keyword()
  def stamp(fun, meta, args, imports, kernel, pipe_mode) do
    arity = Mutator.effective_arity(args, pipe_mode)

    case resolve_import(imports, fun, arity) do
      {module_key, selector} ->
        [
          {@import_key, {module_key, rebuild_kind(selector, imports, kernel)}},
          {@import_witness_key, {module_key, fun, arity}}
          | meta
        ]

      nil ->
        if displaced_from_kernel?(kernel, fun, arity),
          do: [{@kernel_displaced_key, true} | meta],
          else: meta
    end
  end

  # A **bare** rebuild (the clean diff `reject`→`filter`) is safe only when the swap's sibling
  # is unambiguously bare-callable to the *same* module. That holds exactly when the resolved
  # module is the **sole whole import** and `Kernel` is unmanipulated: the only other in-scope
  # provider is then `Kernel`, and since a mutator's sibling is always an export of the
  # resolved module, a bare sibling either resolves to that module (correct) or clashes with
  # `Kernel` and won't compile (poison — never a wrong result). With *any other* import in
  # scope a sibling can be ambiguous (`import Stream, except: [filter: 2]; import Enum` makes a
  # bare `reject` both Stream's and Enum's) or resolve to the wrong module, so **qualify**
  # instead — `Calls` makes the qualifier alias-proof, so it always names the resolved module.
  defp rebuild_kind(selector, imports, kernel) do
    if whole?(selector) and map_size(imports) == 1 and whole?(kernel),
      do: :bare,
      else: :qualify
  end

  @doc """
  Strip the import **witness** stamp from `meta`, keeping the `:mutare_import` resolution stamp.

  The witness (`Mutare.Transform.ImportWitness`) reconstructs the call as a dead-code
  `fn a1, …, aN -> fun(a1, …, aN) end` to prove the bare name still resolves to the believed
  provider. That is sound for a function and for an ordinary macro whose arguments are plain
  expressions (`Integer.is_even(n)`), but **not** for a macro that constrains an argument away
  from a runtime expression — `Ecto.Query.from/2`'s compile-time keyword list, `match?`'s pattern —
  where the reconstruction would not compile, poisoning the build for *every* mutation of an
  expression containing the call. `Mutare.Transform.Resolve` calls this for a call it recognises as
  a **known macro** (one in the macro registry, whose arguments it routes specially): such a call
  keeps its resolution stamp (for `Calls`) but loses the witness it could never satisfy. (The
  displacement guard the witness gives isn't expressible for such a macro anyway — there is no
  universally-valid call shape to reference it by.)
  """
  @spec drop_witness(keyword()) :: keyword()
  def drop_witness(meta) when is_list(meta), do: Keyword.delete(meta, @import_witness_key)

  @doc """
  The import a bare call resolves to: `{module, :bare | :qualify}` (module an Elixir path
  `[:Enum]` or an Erlang atom `:binary`) stamped by `stamp/6`, or `nil` when the call resolves
  to nothing imported (a local, or the default `Kernel`). The reader half of the
  `:mutare_import` contract.
  """
  @spec resolved_import(keyword() | term()) :: {[atom()] | atom(), :bare | :qualify} | nil
  def resolved_import(meta) when is_list(meta), do: Keyword.get(meta, @import_key)
  def resolved_import(_meta), do: nil

  @doc """
  A compile-time witness for a stamped bare import: `{module, fun, effective_arity}`.

  Emission can splice this into a generated mutant branch as an unreachable import/call check.
  If macro expansion has secretly removed `fun/arity` from `module` and supplied it from another
  import, the witness makes the conflict ambiguous at compile time instead of letting the mutant
  silently call the wrong provider.
  """
  @spec import_witness(keyword() | term()) :: {[atom()] | atom(), atom(), non_neg_integer()} | nil
  def import_witness(meta) when is_list(meta), do: Keyword.get(meta, @import_witness_key)
  def import_witness(_meta), do: nil

  @doc """
  Whether a bare `Kernel`-named call has been displaced out of `Kernel` here (by
  `import Kernel, except:/only:`). The bare-`Kernel` mutator families read this to
  skip a call that is no longer the `Kernel` function they assume.
  """
  @spec kernel_displaced?(keyword() | term()) :: boolean()
  def kernel_displaced?(meta) when is_list(meta),
    do: Keyword.get(meta, @kernel_displaced_key, false)

  def kernel_displaced?(_meta), do: false

  # --- resolution ------------------------------------------------------------

  # Find the in-scope import that provides `fun/arity`. In compiling code at most one can
  # (two would be an ambiguous-call compile error), so the first match is authoritative.
  defp resolve_import(imports, fun, arity) do
    Enum.find_value(imports, fn {module_key, selector} ->
      if provides?(module_key, selector, fun, arity), do: {module_key, selector}
    end)
  end

  # Does this import selection bring `fun/arity` into scope? The function must be in `base`
  # and not in the cumulative `except`. `{:only, set}` is definitive from the source (no
  # reflection); `:all`/`{:kind, …}` need the module's real exports.
  defp provides?(module_key, {base, except}, fun, arity) do
    not MapSet.member?(except, {fun, arity}) and base_provides?(base, module_key, fun, arity)
  end

  defp base_provides?(:all, module_key, fun, arity), do: exports?(module_key, fun, arity, :any)

  defp base_provides?({:only, set}, _module_key, fun, arity),
    do: MapSet.member?(set, {fun, arity})

  defp base_provides?({:kind, kind}, module_key, fun, arity),
    do: exports?(module_key, fun, arity, kind)

  # Reflection. Conservative: a module that isn't loadable (a target/dep module, never one
  # our mutators target) exports nothing as far as we can prove, so it is left unresolved.
  defp exports?(module_key, fun, arity, kind) do
    case Aliases.to_module(module_key) do
      nil ->
        false

      module ->
        Code.ensure_loaded?(module) and exported?(module, fun, arity, kind)
    end
  end

  defp exported?(module, fun, arity, :functions), do: function_exported?(module, fun, arity)
  defp exported?(module, fun, arity, :macros), do: macro_exported?(module, fun, arity)
  defp exported?(_module, _fun, _arity, :sigils), do: false

  defp exported?(module, fun, arity, :any),
    do: function_exported?(module, fun, arity) or macro_exported?(module, fun, arity)

  # A bare `Kernel`-named call is displaced only when the Kernel selector has been narrowed
  # (`import Kernel, only:/except:`) and no longer provides it. With the default whole import
  # (`{:all, ∅}`), nothing is displaced — the common path, and free of reflection.
  defp displaced_from_kernel?(kernel, fun, arity) do
    # NOTE (suspected-equivalent survivor, deliberately not `# mutare:ignore`d): the
    # `conditional` mutant that forces `not whole?(kernel)` to `true` is equivalent — when the
    # kernel is whole, `kernel_function?(f,a)` and `provides?([:Kernel], whole, f,a)` are equal,
    # so the tail collapses to `X and not X` = false (same as a false first conjunct). We do
    # NOT ignore it, because the *other* conditional mutants on this expression (the larger
    # conjunctions, and the `false` variant) are genuinely killed, and a line-level
    # `# mutare:ignore[conditional]` would hide those real kills too.
    not whole?(kernel) and kernel_function?(fun, arity) and
      not provides?([:Kernel], kernel, fun, arity)
  end

  @doc """
  Whether a selection imports a module **wholesale** — an unmodified `import Mod` (base `:all`,
  nothing excepted). `Mutare.Transform.Resolve` reads this to fall back to the known-macro
  registry for a macro reached through a whole import of a module it can't reflect on.
  """
  @spec whole?(selector() | term()) :: boolean()
  def whole?({:all, except}), do: MapSet.size(except) == 0
  def whole?(_selector), do: false

  defp kernel_function?(fun, arity),
    do: function_exported?(Kernel, fun, arity) or macro_exported?(Kernel, fun, arity)

  # --- import directives -----------------------------------------------------

  # Parse the directive args to a resolved `{module_key, op}` (or `nil` for an unrecognised
  # form) and bind it. `put_import` is reached from one place, so the bind logic — the `Kernel`
  # special-case, the `module_key?` guard, the op-combining — lives in exactly one path.
  defp register_import(args, aliases, imports, kernel) do
    case parse_import_args(args, aliases) do
      {module_key, op} -> put_import(module_key, op, imports, kernel)
      nil -> {imports, kernel}
    end
  end

  # `import Mod` / `import E` (an Elixir module, possibly an alias) — resolve the written
  # path through the alias env, so `import E` (and `import B` where `B` aliases an Erlang
  # atom module) lands on the real module key.
  # mutare:ignore[guard_drop] equivalent — an `__aliases__` segment list is always a list, so the guard can't fail.
  defp parse_import_args([{:__aliases__, _meta, path}], aliases) when is_list(path),
    do: {Aliases.resolve_path(path, aliases), :all}

  defp parse_import_args([{:__aliases__, _meta, path}, opts], aliases)
       when is_list(path) and is_list(opts),
       do: {Aliases.resolve_path(path, aliases), op_from_opts(opts)}

  # `import :erlang_module` (a Sourceror-wrapped atom) — the module key is the atom itself.
  # Dropping `when is_atom(atom)` lets a non-atom single-literal import (`import "x"`) reach
  # `put_import`, but `module_key?` rejects it there exactly as the fallback clause would.
  # mutare:ignore[guard_drop] equivalent — `module_key?` masks the difference downstream.
  defp parse_import_args([{:__block__, _meta, [atom]}], _aliases) when is_atom(atom),
    do: {atom, :all}

  defp parse_import_args([{:__block__, _meta, [atom]}, opts], _aliases)
       when is_atom(atom) and is_list(opts),
       do: {atom, op_from_opts(opts)}

  defp parse_import_args(_args, _aliases), do: nil

  # Bind a resolved module key (an Elixir path `[:Enum]` or an Erlang atom `:binary`) to its
  # selection, **combining** the directive's op with any prior import of that module. `Kernel`
  # is special — it lives in the `kernel` slot (an implicit default whole import that a
  # narrowing combines into); a `__MODULE__`-relative or otherwise non-module path is skipped.
  defp put_import([:Kernel], op, imports, kernel), do: {imports, combine(kernel, op)}

  defp put_import(module_key, op, imports, kernel) do
    if module_key?(module_key),
      do:
        {Map.update(imports, module_key, combine(default_selector(), op), &combine(&1, op)),
         kernel},
      else: {imports, kernel}
  end

  # Combine an import directive's op with the module's prior selection. `:all` / `only:` /
  # `only: :kind` *replace* the selection (clearing any prior except); `except:` *subtracts*
  # from the prior base, accumulating the excluded set — the rule that makes repeated imports
  # of one module compose correctly.
  defp combine(_prior, :all), do: {:all, MapSet.new()}
  defp combine(_prior, {:only, set}), do: {{:only, set}, MapSet.new()}
  defp combine(_prior, {:only_kind, kind}), do: {{:kind, kind}, MapSet.new()}
  defp combine({base, except}, {:except, e}), do: {base, MapSet.union(except, e)}

  defp module_key?(key) when is_atom(key), do: true

  # mutare:ignore[guard_drop] equivalent — only reached with a list key (atoms taken above), so the guard can't fail.
  defp module_key?(key) when is_list(key), do: Aliases.atoms?(key)

  # mutare:ignore[clause_drop] equivalent — every key is an atom or list, so this fallback is unreachable.
  defp module_key?(_key), do: false

  # The directive's own op: `only:` wins over `except:` (a directive can't carry both); a
  # directive with neither (`import M, warn: false`) is a whole import.
  defp op_from_opts(opts) do
    case opt_value(opts, :only) do
      :none ->
        case opt_value(opts, :except) do
          :none -> :all
          value -> {:except, pairs_set(value)}
        end

      value ->
        only_op(value)
    end
  end

  # `only: :functions`/`:macros`/`:sigils` is a kind filter; `only: [f: 1, ...]` is an
  # explicit name/arity set.
  defp only_op(value) do
    case kind_atom(value) do
      # NOTE (suspected-equivalent survivor, deliberately not `# mutare:ignore`d): the `atom`
      # mutant that rewrites `:sigils` here is equivalent — it routes `only: :sigils` to the
      # `{:only, ∅}` arm, but a `{:kind, :sigils}` selector resolves nothing anyway (sigil
      # reflection is hard-wired false), so both attribute nothing for every call. We do NOT
      # ignore it: the sibling `:functions`/`:macros`/`:only_kind` atom mutants on this line are
      # genuinely killed, and a line-level `# mutare:ignore[atom]` would hide those real kills.
      kind when kind in [:functions, :macros, :sigils] -> {:only_kind, kind}
      _other -> {:only, pairs_set(value)}
    end
  end

  # Only an atom result can match `[:functions, :macros, :sigils]` in `only_op`; a non-atom
  # result behaves like the `nil` the guard would otherwise yield.
  # mutare:ignore[guard_drop] equivalent — a non-atom result is indistinguishable from `nil` downstream.
  defp kind_atom({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  defp kind_atom(_value), do: nil

  # The value node for an option key, or `:none` (the sentinel `op_from_opts/1` distinguishes
  # from a present-but-`nil` value). Reads Sourceror's wrapped key via the shared `AST.opts_get/3`.
  defp opt_value(opts, name), do: AST.opts_get(opts, name, :none)

  # The `{fun, arity}` set from an `only:`/`except:` value — a (Sourceror-wrapped) keyword
  # list of `name: arity`. Unparseable entries are dropped (fail safe — nothing resolved).
  defp pairs_set(value) do
    value
    |> unwrap_list()
    |> Enum.reduce(MapSet.new(), fn
      {key, arity_node}, acc ->
        with f when is_atom(f) <- AST.key_atom(key),
             a when is_integer(a) <- unwrap_int(arity_node) do
          MapSet.put(acc, {f, a})
        else
          _ -> acc
        end

      _entry, acc ->
        acc
    end)
  end

  defp unwrap_list({:__block__, _meta, [list]}) when is_list(list), do: list

  # mutare:ignore[clause_drop] equivalent — Sourceror always wraps a list literal (clause above), so a bare list never reaches here.
  defp unwrap_list(list) when is_list(list), do: list
  defp unwrap_list(_value), do: []

  # mutare:ignore[guard_drop] equivalent — `pairs_set` re-checks `is_integer` on the result, so a non-integer here is dropped just like `nil`.
  defp unwrap_int({:__block__, _meta, [n]}) when is_integer(n), do: n

  # mutare:ignore[clause_drop, guard_drop] equivalent — ints are always Sourceror-wrapped (clause above), and `pairs_set` re-filters by `is_integer`.
  defp unwrap_int(n) when is_integer(n), do: n
  defp unwrap_int(_node), do: nil
end
