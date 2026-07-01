defmodule Mutare.Transform.Analyze.Captures do
  @moduledoc false

  # Capture mutation: a `&Mod.fun/N` **reference** capture is a call value
  # (`&Mod.fun/N ≡ fn a1, …, aN -> Mod.fun(a1, …, aN) end`), so the call-matching families —
  # renames (Collection/StringCall/Numeric/Math/Integer/MapKeyword/MapSet) and removals
  # (CallRemoval) — carry the same signal on it as on a written call. Rather than re-encode any
  # of their swap tables, the capture is **probed**: synthesize the equivalent N-ary call
  # `Mod.fun(v1, …, vN)`, offer it through the ordinary `Dispatch.mutations/3` path (the one
  # every call position uses), and re-capture each mutant back into capture form. So every
  # call-matching mutator — built-in *or* custom — participates with its existing
  # `mutate`/`mutate/2`, with no second list and no capture-specific callback.
  #
  # The synth call is a **transient probe**: it is never emitted. The emitted selector keeps the
  # verbatim `&Mod.fun/N` as its baseline branch — a real external fun (`&M.f/a` compares by
  # MFA), so identity / `==` / map-key / MapSet / handler-id semantics are preserved at mutant 0
  # (the same reason coverage is recorded at value-production; see NOTES "production-site
  # coverage recording"). Each mutant branch is a **re-built** capture, never the probe's
  # eta-expansion (a `fn …` would compare unequal to any `&M.f/a`).
  #
  # Re-capture reads the mutator's choice off the output's shape:
  #
  #   * **rename** → the output is a call `Mod'.fun'(v1…vN)` reusing the placeholders in order
  #     (`swap_call` rebuilds with the arg list verbatim) → `&Mod'.fun'/N`, a real external fun;
  #   * **removal** → the output is the bare first placeholder `v1` (CallRemoval non-piped
  #     returns the first argument) → the arity-N first-argument projection: `&Function.identity/1`
  #     for N = 1 (a named external fun, alias-proofed `Elixir.`-absolute like
  #     `Mutare.Mutators.Helpers`' piped no-op), or `fn a, _… -> a end` for N > 1 (no named
  #     "project first of N" exists; the projection only ever sits in a *mutant* branch, so its
  #     anonymous identity is a *correct* kill, never a baseline divergence);
  #   * anything else — an arity change (CollectionArity/DefaultDrop drop an arg, so the output
  #     reuses *fewer* args), or a non-recapturable custom output — is **dropped**.
  #
  # That recapture filter is what makes the cohort self-selecting (no allow/deny list): it
  # admits exactly the renames + removals and excludes the arg-manipulating families, because
  # those either change the arity (can't re-wrap at N) or never fire on a var placeholder
  # (ModeSwap needs a literal option value).
  #
  # Scope: **remote** captures — `&Mod.fun/N` (Elixir, alias-resolved through the synth call's
  # own node) and `&:mod.fun/N` (Erlang atom module) — plus **bare imported** captures such as
  # `import Enum; &filter/2`. `Resolve` stamps a bare ref when the `fun/N` resolves through an
  # import, so the synth bare call resolves through the same `Calls.resolved_call/1` path as a
  # written `filter(v1, v2)`. A truly local capture (`&local/1`) remains pruned.

  alias Mutare.{AST, Mutator.Dispatch}
  alias Mutare.Transform.{Analyze.Attach, Imports}

  @proj_arg :mutare_capture_arg

  @doc """
  Offer a `&Mod.fun/N` or imported `&fun/N` capture to the call-matching mutators, attaching re-captured
  `Candidate.InPlace`s to the whole `&` node — so emission wraps the *entire* capture in a
  selector and the baseline branch stays the verbatim capture. Returns the node unchanged when
  nothing fires or the capture is a local bare reference.
  """
  @spec offer(Macro.t(), Macro.t(), Macro.t(), [term()]) :: Macro.t()
  def offer(node, left, right, mutators) do
    with {:ok, arity} <- arity(right),
         {:ok, synth, args} <- synth_call(left, arity),
         [_ | _] = muts <- capture_mutations(synth, args, arity, mutators) do
      Attach.put_candidates(node, Attach.build_candidates(node, muts))
    else
      _ -> node
    end
  end

  @doc """
  Whether `&left/right` is a genuine function-reference capture (`&Mod.fun/N`, `&fun/N`)
  rather than an arithmetic `& &1 / 2`: a function reference (remote *or* local) over an
  integer arity. `Mutare.Transform.Analyze` reads this to decide whether to offer the node
  here or recurse into the `/` as division. A local ref counts — so its `/` isn't mistaken
  for division — even though `offer/4` only mutates remote or imported refs (a local capture is
  left raw, not recursed).
  """
  @spec capture_ref?(Macro.t(), Macro.t()) :: boolean()
  def capture_ref?(left, right), do: function_ref?(left) and integer_arity?(right)

  defp function_ref?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp function_ref?({{:., _, _}, _meta, args}) when is_list(args), do: true
  defp function_ref?(_), do: false

  defp integer_arity?(n) when is_integer(n), do: true
  defp integer_arity?({:__block__, _meta, [n]}) when is_integer(n), do: true
  defp integer_arity?(_), do: false

  # The arity literal `N` from the `/N` separator (a bare int or a Sourceror `:__block__`).
  defp arity(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp arity({:__block__, _meta, [n]}) when is_integer(n) and n >= 0, do: {:ok, n}
  defp arity(_other), do: :error

  # Build the equivalent N-ary call from a **remote** ref by filling N placeholder args into the
  # (zero-arg) call node, or from an imported bare ref by turning its stamped `&fun/N` metadata
  # into a synthetic `fun(v1, …, vN)` call. A local bare ref has no import stamp and returns
  # `:error`.
  defp synth_call({{:., _dot_meta, _mod_fun} = head, call_meta, []}, arity) do
    args = placeholders(arity)
    {:ok, {head, call_meta, args}, args}
  end

  defp synth_call({fun, meta, context}, arity)
       when is_atom(fun) and is_list(meta) and is_atom(context) do
    case Imports.resolved_import(meta) do
      nil ->
        :error

      {_module, _kind} ->
        args = placeholders(arity)
        {:ok, {fun, meta, args}, args}
    end
  end

  defp synth_call(_left, _arity), do: :error

  # Distinct, recognisable placeholder vars. Never emitted (a re-built capture has no args, a
  # projection carries its own fresh params) — they exist only so the rename path reuses them
  # verbatim and the removal path can return the first one.
  defp placeholders(0), do: []
  defp placeholders(arity), do: for(i <- 1..arity, do: {:"#{@proj_arg}_#{i}", [], __MODULE__})

  defp capture_mutations(synth, args, arity, mutators) do
    synth
    |> Dispatch.mutations(mutators, %{pipe_mode: :unpiped})
    |> Enum.flat_map(fn {spec, mutated, note, variant} ->
      case recapture(mutated, args, arity) do
        nil -> []
        capture -> [{spec, capture, note, variant}]
      end
    end)
  end

  # Re-capture by reading the mutator's choice off the output's shape (see the moduledoc).
  defp recapture(mutated, args, arity) do
    case rename_capture(mutated, args) do
      nil -> removal_capture(mutated, args, arity)
      capture -> capture
    end
  end

  # A renamed call reusing the synth args in order → strip the args, re-wrap as a capture of the
  # renamed function. The head is reused verbatim, so an aliased written form is preserved (the
  # diff keeps `&E.last/1` for an `alias Enum, as: E`). For a bare imported capture, the ref
  # metadata is also reused; `Calls` has already rewitnessed it to the renamed sibling when that
  # sibling stays bare, and `ImportWitness` reads it back from the recaptured ref.
  defp rename_capture({{:., _dot_meta, [_mod, fun]} = head, meta, args}, synth_args)
       when is_atom(fun) and args == synth_args do
    capture_node({head, meta, []}, length(synth_args))
  end

  defp rename_capture({fun, meta, args}, synth_args)
       when is_atom(fun) and is_list(meta) and args == synth_args do
    capture_node({fun, meta, nil}, length(synth_args))
  end

  defp rename_capture(_mutated, _synth_args), do: nil

  # The removal output (`Helpers.removed_call(:unpiped, args)` returns the first argument) →
  # the arity-N first-argument projection.
  defp removal_capture(mutated, [first | _rest], arity) when arity >= 1 and mutated == first,
    do: projection(arity)

  defp removal_capture(_mutated, _args, _arity), do: nil

  # N = 1 → the named external fun `&Elixir.Function.identity/1` (alias-proof). N > 1 →
  # `fn a, _… -> a end`, the arity-correct first-argument projection (no named form exists;
  # sound only because it lives only in a mutant branch).
  defp projection(1), do: capture_node(identity_ref(), 1)

  defp projection(arity) do
    first = {@proj_arg, [], __MODULE__}
    params = [first | List.duplicate({:_, [], __MODULE__}, arity - 1)]
    {:fn, [], [{:->, [], [params, first]}]}
  end

  defp identity_ref do
    {{:., [], [{:__aliases__, [], [:"Elixir", :Function]}, :identity]}, [], []}
  end

  defp capture_node(ref, arity) when is_integer(arity),
    do: {:&, [], [{:/, [], [ref, AST.literal(arity)]}]}
end
