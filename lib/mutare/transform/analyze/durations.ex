defmodule Mutare.Transform.Analyze.Durations do
  @moduledoc false

  # The "duration argument" sub-concern of the analyze pass: recognising that a runtime call
  # sits at a known **timeout/duration position** (the third argument of `Process.send_after/3`,
  # the argument of `Process.sleep/1`, the timeout of `GenServer.call/3`, the `:timeout` option
  # of `Task.async_stream`, …), so the descent can leave a *literal* duration there — an integer
  # count of milliseconds, or `:infinity` — unmutated.
  #
  # Why: a duration literal is a near-unkillable equivalent-mutant factory. No test pins the
  # exact millisecond count, so `Process.sleep(100) → 101` just survives as noise. Worse, a
  # *shrunk* timeout (`… → 0`) can trip a real `:timeout` or a timing-dependent failure — which
  # `Mutare` scores as a **kill** — so leaving these in doesn't merely pad the denominator with
  # unkillable survivors, it can inflate the *numerator* with kills that reflect scheduler timing,
  # not a test assertion. Both directions corrupt the score, so the position is excluded
  # positively here, the same way compile-unsafe positions (struct fields, `for` options) are —
  # this is the first *signal-quality* exclusion rather than a compile-safety one. See NOTES
  # "Duration-argument literals".
  #
  # A pure leaf: given a call node (carrying `Mutare.Transform.Resolve`'s alias/import stamps) it
  # only *classifies* — `classify/2` returns which positions carry a duration and
  # `suppressible_literal?/1` recognises the literal shapes; the descent
  # (`Mutare.Transform.Analyze`) owns the actual leave-it-raw routing. Resolution goes through the
  # same `Mutare.Transform.Calls.resolved_call/1` the call-matching families use, so aliased,
  # imported, and Erlang-atom-module forms (`alias Task, as: T; T.await(t, 5_000)`,
  # `:timer.sleep(n)`) are recognised for free; a shadowing `alias MyApp.Task` resolves elsewhere
  # and is left alone.
  #
  # The table is curated, not exhaustive — a positive list of the high-confidence stdlib/OTP
  # timeouts, trivially extended by a row. It is intentionally *not* configurable (like the other
  # positive positional exclusions); `# mutare:ignore` only *adds* suppressions, and the site here
  # never exists to ignore.

  alias Mutare.Transform.{Aliases, Calls}

  # Positional duration arguments, keyed by `{resolved_module, function, effective_arity}` to the
  # *effective* argument indices whose literal is a duration. "Effective" arity/index count the
  # piped receiver of a `|>` stage as argument 0, so the signature reads naturally here and the
  # pipe shift is applied once, in `build_spec/4`. Every arity is pinned so a same-named sibling at a
  # different arity (with a duration at a different index, or none) can never be mis-suppressed.
  @positional_spec [
    {Process, :sleep, 1, [0]},
    {:timer, :sleep, 1, [0]},
    {Process, :send_after, 3, [2]},
    {Process, :send_after, 4, [2]},
    {GenServer, :call, 3, [2]},
    {GenServer, :stop, 3, [2]},
    {Agent, :stop, 3, [2]},
    {Supervisor, :stop, 3, [2]},
    {Task, :await, 2, [1]},
    {Task, :await_many, 2, [1]},
    {Task, :yield, 2, [1]},
    {Task, :yield_many, 2, [1]},
    {Task, :shutdown, 2, [1]}
  ]

  # Encode the human-readable spec into the `resolved_call/1` key shape once, at compile time —
  # `Aliases.from_module/1` is the same encoder `resolved_call/1` keys on, so a written module
  # (`Process`) becomes the segment path (`[:Process]`) and an Erlang atom (`:timer`) stays an
  # atom. (Same "call a peer in a module attribute" pattern as `AtomLiteral`'s `@convention`.)
  @positional for {module, fun, arity, indices} <- @positional_spec,
                  into: %{},
                  do: {{Aliases.from_module(module), fun, arity}, indices}

  # Keyword duration *options*, keyed by `{resolved_module, function, arity}` to the option keys
  # whose literal is a duration. **Arity-specific**, because only *some* arities carry an options
  # list: `Task.async_stream/3` (fun form) and `/5` (MFA form) end in `options`, but `/4` — the MFA
  # form `(enum, module, function, args)` — ends in the callback `args` *list*, which is ordinary
  # data. A literal `[timeout: 5_000]` written as those `args` must still mutate, so the non-option
  # arity is simply absent here.
  @keyword_spec [
    {Task, :async_stream, 3, [:timeout]},
    {Task, :async_stream, 5, [:timeout]},
    {Task.Supervisor, :async_stream, 4, [:timeout]},
    {Task.Supervisor, :async_stream, 6, [:timeout]},
    # `Task.yield_many/2` accepts its timeout *either* as a bare positional argument *or* inside an
    # options keyword (`limit:` / `timeout:` / `on_timeout:`), so it appears in *both* tables: the
    # bare form via the `{Task, :yield_many, 2, [1]}` positional entry above, the option via this
    # entry. The descent checks the options shape first, so the two never collide (see
    # `recurse_duration_args/3` in `Mutare.Transform.Analyze`).
    {Task, :yield_many, 2, [:timeout]}
  ]

  @keyword for {module, fun, arity, keys} <- @keyword_spec,
               into: %{},
               do: {{Aliases.from_module(module), fun, arity}, keys}

  # Every function name that appears in either table. A call whose written function name is not in
  # this set can never match, so `classify/2` short-circuits on it *before* `resolved_call/1` —
  # which allocates a `rebuild` closure per call — sparing that allocation on the ~all calls that
  # aren't timeouts (the scan is transform-bound and heap-sensitive; NOTES "Scan is
  # transform-bound"). The function name in the AST is never aliased (only the module is), so this
  # pre-filter is sound: it never drops a call resolution would have matched.
  @fun_names MapSet.new(
               Enum.map(@positional_spec, &elem(&1, 1)) ++ Enum.map(@keyword_spec, &elem(&1, 1))
             )

  @typedoc """
  What `classify/2` found: `:none`, or the duration positions of a matched call — the *visible*
  argument indices (pipe shift already applied) and the trailing-keyword option keys.
  """
  @type spec :: :none | %{positional: [non_neg_integer()], keyword_keys: [atom()]}

  @doc """
  Classify a runtime call node as a duration position, resolving it through the shared
  call reader. `pipe_mode` is `:piped` for a `|>` stage (whose visible arguments are shifted
  one place from the call's effective signature) or `:unpiped`.

  Returns `:none` for any node that is not a resolved call to a table entry, or a `spec` naming
  the *visible* positional indices and the trailing-keyword option keys that carry a duration.
  """
  @spec classify(Macro.t(), :piped | :unpiped) :: spec()
  def classify({head, _meta, args} = node, pipe_mode) when is_list(args) do
    with true <- MapSet.member?(@fun_names, call_fun(head)),
         {module_key, fun, _resolved_args, _rebuild} <- Calls.resolved_call(node) do
      build_spec(module_key, fun, length(args), pipe_mode)
    else
      _ -> :none
    end
  end

  def classify(_node, _pipe_mode), do: :none

  # The written function name of a call head — a remote `Mod.fun`/`:mod.fun` (`fun`) or a bare
  # `fun`; `nil` for any other head (never in `@fun_names`, so the pre-filter rejects it).
  defp call_fun({:., _dot_meta, [_recv, fun]}) when is_atom(fun), do: fun
  defp call_fun(fun) when is_atom(fun), do: fun
  defp call_fun(_head), do: nil

  # Assemble the `spec` for a resolved `{module_key, fun}` with `visible_arity` visible arguments.
  # Both tables are keyed by *effective* arity (visible + the piped receiver) — the natural
  # signature. Positional: each effective index is shifted back to a visible index and clamped to
  # the visible range (so a piped receiver that is itself the duration, effective index 0, drops
  # out). Keyword: the arity match is what distinguishes an options-bearing form from an MFA form
  # whose trailing list is callback data (see `@keyword_spec`).
  defp build_spec(module_key, fun, visible_arity, pipe_mode) do
    offset = pipe_offset(pipe_mode)
    effective_arity = visible_arity + offset

    positional =
      @positional
      |> Map.get({module_key, fun, effective_arity}, [])
      |> Enum.map(&(&1 - offset))
      |> Enum.filter(&(&1 >= 0 and &1 < visible_arity))

    keyword_keys = Map.get(@keyword, {module_key, fun, effective_arity}, [])

    if positional == [] and keyword_keys == [],
      do: :none,
      else: %{positional: positional, keyword_keys: keyword_keys}
  end

  defp pipe_offset(:piped), do: 1
  defp pipe_offset(_unpiped), do: 0

  @doc """
  Whether a node is a *literal* duration to leave raw: an integer literal (a millisecond count) or
  the atom `:infinity` (the "wait forever" timeout every one of these positions also accepts). Any
  other argument — a variable, a `@module_attr`, an arithmetic expression like `base * 2` — is not
  a literal and keeps mutating normally.
  """
  @spec suppressible_literal?(Macro.t()) :: boolean()
  def suppressible_literal?({:__block__, _meta, [value]}) when is_integer(value), do: true
  def suppressible_literal?({:__block__, _meta, [:infinity]}), do: true
  def suppressible_literal?(_node), do: false
end
