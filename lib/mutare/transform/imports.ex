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
  #   * Like `alias`, `use`-injected and macro-generated imports are invisible — and unlike the
  #     visible cases this can be *wrong*, not just missed: a `use` that re-imports a module we
  #     target with `except:` (removing a function) and supplies it from elsewhere makes us
  #     mis-resolve the bare call to the wrong module (see NOTES "Correctness boundary").
  #     Each stamped imported call therefore also carries a resolution witness: generated
  #     mutant branches can re-import the believed provider in an unreachable expression,
  #     turning that hidden replacement into an ambiguity compile error instead of a wrong
  #     surviving mutant.

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
  local/default-`Kernel` call. `piped?` recovers the effective arity (a pipe stage carries
  one fewer written arg than the source reads).
  """
  @spec stamp(atom(), keyword(), [Macro.t()], map(), selector(), boolean()) :: keyword()
  def stamp(fun, meta, args, imports, kernel, piped?) do
    arity = Mutator.effective_arity(args, piped?)

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
    case to_module(module_key) do
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

  defp to_module(path) when is_list(path), do: Module.concat(path)
  defp to_module(atom) when is_atom(atom), do: atom
  defp to_module(_path), do: nil

  # A bare `Kernel`-named call is displaced only when the Kernel selector has been narrowed
  # (`import Kernel, only:/except:`) and no longer provides it. With the default whole import
  # (`{:all, ∅}`), nothing is displaced — the common path, and free of reflection.
  defp displaced_from_kernel?(kernel, fun, arity) do
    not whole?(kernel) and kernel_function?(fun, arity) and
      not provides?([:Kernel], kernel, fun, arity)
  end

  # A selection that imports everything (an unmodified `import Mod`): base `:all`, nothing
  # excepted.
  defp whole?({:all, except}), do: MapSet.size(except) == 0
  defp whole?(_selector), do: false

  defp kernel_function?(fun, arity),
    do: function_exported?(Kernel, fun, arity) or macro_exported?(Kernel, fun, arity)

  # --- import directives -----------------------------------------------------

  # `import Mod` / `import E` (an Elixir module, possibly an alias) — resolve the written
  # path through the alias env, so `import E` (and `import B` where `B` aliases an Erlang
  # atom module) lands on the real module key.
  defp register_import([{:__aliases__, _meta, path}], aliases, imports, kernel)
       when is_list(path),
       do: put_import(Aliases.resolve_path(path, aliases), :all, imports, kernel)

  defp register_import([{:__aliases__, _meta, path}, opts], aliases, imports, kernel)
       when is_list(path) and is_list(opts),
       do:
         put_import(
           Aliases.resolve_path(path, aliases),
           op_from_opts(opts),
           imports,
           kernel
         )

  # `import :erlang_module` (a Sourceror-wrapped atom) — the module key is the atom itself.
  defp register_import([{:__block__, _meta, [atom]}], _aliases, imports, kernel)
       when is_atom(atom),
       do: put_import(atom, :all, imports, kernel)

  defp register_import([{:__block__, _meta, [atom]}, opts], _aliases, imports, kernel)
       when is_atom(atom) and is_list(opts),
       do: put_import(atom, op_from_opts(opts), imports, kernel)

  defp register_import(_args, _aliases, imports, kernel), do: {imports, kernel}

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
  defp module_key?(key) when is_list(key), do: atoms?(key)
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
      kind when kind in [:functions, :macros, :sigils] -> {:only_kind, kind}
      _other -> {:only, pairs_set(value)}
    end
  end

  defp kind_atom({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  defp kind_atom(_value), do: nil

  # The value node for an option key, or `:none`. Reads Sourceror's wrapped key.
  defp opt_value(opts, name) do
    Enum.find_value(opts, :none, fn
      {key, value} -> if AST.key_atom(key) == name, do: value
      _pair -> nil
    end)
  end

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
  defp unwrap_list(list) when is_list(list), do: list
  defp unwrap_list(_value), do: []

  defp unwrap_int({:__block__, _meta, [n]}) when is_integer(n), do: n
  defp unwrap_int(n) when is_integer(n), do: n
  defp unwrap_int(_node), do: nil

  defp atoms?(list) when is_list(list), do: Enum.all?(list, &is_atom/1)
  defp atoms?(_other), do: false
end
