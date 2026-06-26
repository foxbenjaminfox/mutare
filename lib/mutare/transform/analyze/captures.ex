defmodule Mutare.Transform.Analyze.Captures do
  @moduledoc false

  # Capture mutation: a `&Mod.fun/N` **reference** capture is a call value
  # (`&Mod.fun/N ≡ fn a1, …, aN -> Mod.fun(a1, …, aN) end`), so the call-matching families —
  # renames (Collection/StringCall/Numeric/Math/Integer/MapKeyword/MapSet) and removals
  # (CallRemoval) — carry the same signal on it as on a written call. Rather than re-encode any
  # of their swap tables, the capture is **probed**: synthesize the equivalent N-ary call
  # `Mod.fun(v1, …, vN)`, offer it through the ordinary `Mutator.mutations/3` path (the one
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
  # Scope: **remote** captures only — `&Mod.fun/N` (Elixir, alias-resolved through the synth
  # call's own node) and `&:mod.fun/N` (Erlang atom module). A **bare/local** capture
  # (`&reject/2` after `import Enum`, `&local/1`) is left pruned: its ref carries no import stamp
  # (`Resolve` stamps bare *calls*, and a capture ref is not one), so the synth bare call would
  # not resolve. Deferred — see NOTES "Capture mutation".

  alias Mutare.{AST, Mutator}
  alias Mutare.Transform.Analyze

  @proj_arg :mutare_capture_arg

  @doc """
  Offer a `&Mod.fun/N` capture to the call-matching mutators, attaching re-captured
  `Candidate.InPlace`s to the whole `&` node — so emission wraps the *entire* capture in a
  selector and the baseline branch stays the verbatim capture. Returns the node unchanged when
  nothing fires or the capture is not a remote reference (bare/local — deferred).
  """
  @spec offer(Macro.t(), Macro.t(), Macro.t(), [term()]) :: Macro.t()
  def offer(node, left, right, mutators) do
    with {:ok, arity} <- arity(right),
         {:ok, synth, args} <- synth_call(left, arity),
         [_ | _] = muts <- capture_mutations(synth, args, arity, mutators) do
      Analyze.put_candidates(node, Analyze.build_candidates(node, muts))
    else
      _ -> node
    end
  end

  # The arity literal `N` from the `/N` separator (a bare int or a Sourceror `:__block__`).
  defp arity(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp arity({:__block__, _meta, [n]}) when is_integer(n) and n >= 0, do: {:ok, n}
  defp arity(_other), do: :error

  # Build the equivalent N-ary call from a **remote** ref by filling N placeholder args into the
  # (zero-arg) call node. A bare/local ref (`{name, _meta, ctx_atom}`) returns `:error`.
  defp synth_call({{:., _dot_meta, _mod_fun} = head, call_meta, []}, arity) do
    args = placeholders(arity)
    {:ok, {head, call_meta, args}, args}
  end

  defp synth_call(_left, _arity), do: :error

  # Distinct, recognisable placeholder vars. Never emitted (a re-built capture has no args, a
  # projection carries its own fresh params) — they exist only so the rename path reuses them
  # verbatim and the removal path can return the first one.
  defp placeholders(0), do: []
  defp placeholders(arity), do: for(i <- 1..arity, do: {:"#{@proj_arg}_#{i}", [], __MODULE__})

  defp capture_mutations(synth, args, arity, mutators) do
    synth
    |> Mutator.mutations(mutators, %{pipe_mode: :unpiped})
    |> Enum.flat_map(fn {spec, mutated, note} ->
      case recapture(mutated, args, arity) do
        nil -> []
        capture -> [{spec, capture, note}]
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

  # A renamed remote call reusing the synth args in order → strip the args, re-wrap as a capture
  # of the renamed function. The head is reused verbatim, so an aliased written form is
  # preserved (the diff keeps `&E.last/1` for an `alias Enum, as: E`).
  defp rename_capture({{:., _dot_meta, [_mod, fun]} = head, meta, args}, synth_args)
       when is_atom(fun) and args == synth_args do
    capture_node({head, meta, []}, length(synth_args))
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
