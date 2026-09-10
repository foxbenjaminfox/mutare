defmodule Mutare.Sandbox.CompilerOptions do
  @moduledoc """
  The switches that tune the **one** metamutant compile for speed.

  Mutare compiles the metamutant exactly once before any mutant runs. Inference
  and verification feed diagnostics, so disabling them changes no runtime
  behavior. The SSA alias optimization does affect generated code; measurements
  found its compile cost bought no meaningful runtime benefit for the mutant
  workload. Three switches, one home (this module), three delivery routes:

    * `compiler_env/0` — the `ERL_COMPILER_OPTIONS` entry `Mutare.Runner`
      applies to the single `mix compile` (the SSA alias pass off).
    * `compile_args/1` — extra `mix compile` CLI switches for the same
      invocation (`--no-verification`, Elixir ≥ 1.19: skips the
      `Module.ParallelChecker` verify pass — undefined-remote warnings and
      cross-module type checking).
    * `project_source/1` — wraps project modules declared in the sandbox's `mix.exs` so their
      effective `elixirc_options` always disable type-signature *inference*.
      This survives Mix's project cache and applies on every sandbox boot,
      including umbrella children and projects with a custom config path. It
      reports whether the wrap landed and, when it did not, why: several shapes
      decline it, and a declined project compiles with inference on.

  `seed_manifest/1` reconciles the inference option in a transplanted Elixir
  compile manifest with that wrapper. Without it, Elixir 1.18/1.19 sees changed
  `elixirc_options` and discards every seeded app beam on the first compile. It
  must run only for an app `project_source/1` reported wrapping: applied to one
  compiling with inference on, it manufactures the very mismatch it exists to
  prevent, and the seed reports reuse for a build Mix discards.

  The last two exist because Elixir's type checker (≥ 1.18/1.19) is
  pathological on metamutant-shaped code: measured on phoenix_live_view
  (~23k sites), inference + verification take a 14 s compile past 80 *minutes*;
  with both off it is 14 s again. See NOTES "Type inference and verification
  on the metamutant compile".

  A per-mutant `mix test` never recompiles the lib (sources unchanged), so the
  env and args carry nothing there. The project option remains the same on later
  baseline/probe boots, preventing inference configuration changes from making
  Mix recheck the metamutant.
  """

  @erl_compiler_options_env "ERL_COMPILER_OPTIONS"

  # Disable only the SSA *alias-analysis* sub-pass (`beam_ssa_alias`, which proves
  # term uniqueness to enable destructive in-place updates) on the one metamutant
  # compile. It is the dominant cost when compiling the metamutant's tuple-heavy
  # generated selectors (~45% of `beam_ssa_opt` on a tuple-heavy module), yet
  # measurably free at runtime — the metamutant runs the suite, not a tight
  # in-place-update loop, so the optimisation buys nothing there. (Contrast
  # `no_ssa_opt`, all SSA optimisation off: a bigger compile win but ~5% slower per
  # mutant run, paid N times — net-negative, like disabling protocol consolidation.)
  # Safe on every OTP: an unknown compiler option is silently ignored, so this is a
  # no-op before the pass existed (pre-OTP-25). See NOTES "Compiler options for the
  # one metamutant compile".
  @metamutant_compile_opt "no_ssa_opt_alias"

  @doc """
  Env entries that tune the **one** metamutant compile for speed: an
  `ERL_COMPILER_OPTIONS` disabling the SSA alias-analysis pass
  (`#{@metamutant_compile_opt}`).

  Read by `Mutare.Runner` for the single `mix compile`. Scoped there on purpose: a
  per-mutant `mix test` never recompiles the lib (sources unchanged), so it carries
  nothing. Merges with any `ERL_COMPILER_OPTIONS` already in the environment so a
  user's own compiler options survive — ours is prepended (`erl_compiler_options/1`).
  """
  @spec compiler_env() :: [{String.t(), String.t()}]
  def compiler_env do
    inherited = System.get_env(@erl_compiler_options_env)
    [{@erl_compiler_options_env, erl_compiler_options(inherited)}]
  end

  # `mix compile --no-verification` exists since Elixir 1.19 (the release that
  # split verification into its own pass). Passing an unknown switch makes `mix
  # compile` abort, which would sink the one build — so the flag is version-gated,
  # not probed. Pre-1.19 verification is also far cheaper (no cross-module type
  # checking), so nothing meaningful is forgone there.
  @no_verification_since "1.19.0"

  @doc """
  Extra `mix compile` CLI switches for the metamutant compile.

  `--no-verification` (Elixir ≥ #{@no_verification_since}) skips the
  `Module.ParallelChecker` verify pass — undefined-remote-function warnings and
  cross-module type checking. Warnings on a build artifact are noise, and the
  type checker is pathological on metamutant-shaped code (measured: ~12 minutes
  on phoenix_live_view *with inference already off*). Poison detection is
  unaffected: it reads hard compile **errors**, which are raised during
  compilation, not verification.

  `version` defaults to the running Elixir; it is a parameter so the gate is
  unit-testable.
  """
  @spec compile_args(String.t()) :: [String.t()]
  def compile_args(version \\ System.version()) do
    if Version.match?(version, ">= #{@no_verification_since}"),
      do: ["--no-verification"],
      else: []
  end

  # Loaded once per sandbox VM, even when an umbrella loads many mix.exs files.
  # The before-compile hook runs after the target's own hooks, so project/0 may
  # itself be macro-generated. Only a module registered as a Mix project *that
  # already defines* project/0 changes — `use Mix.Project` alone does not define
  # it, and `defoverridable` on a missing function would abort the sandbox mix.exs
  # rather than the target's own later failure. No Mutare dependency or
  # undocumented Mix.ProjectStack API is needed.
  @project_hook :mutare_sandbox_compiler_options
  @project_bootstrap (quote do
                        unless Code.ensure_loaded?(unquote(@project_hook)) do
                          defmodule unquote(@project_hook) do
                            defmacro __before_compile__(env) do
                              if {Mix.Project, :__after_compile__} in Module.get_attribute(
                                   env.module,
                                   :after_compile
                                 ) and Module.defines?(env.module, {:project, 0}) do
                                quote do
                                  defoverridable project: 0

                                  def project do
                                    project = super()

                                    if :infer_signatures in Code.available_compiler_options() do
                                      options =
                                        Keyword.put(
                                          project[:elixirc_options] || [],
                                          :infer_signatures,
                                          false
                                        )

                                      Keyword.put(project, :elixirc_options, options)
                                    else
                                      project
                                    end
                                  end
                                end
                              end
                            end
                          end
                        end
                      end)

  @bootstrap_source Macro.to_string(@project_bootstrap)
  @bootstrap_quoted Code.string_to_quoted!(@bootstrap_source)

  @doc """
  Override inference in the sandbox copy of a Mix project's effective options.

  Returns `{:hooked, source}` when a hook was attached to a module defined in this file,
  and `{:declined, source, reason}` otherwise, `reason` being a short phrase that says why.
  The caller needs both. `Mutare.Sandbox.Seed` may only realign the compile manifest of an
  app that really will compile with inference off, and the source alone cannot answer that:
  a file that defines no module of its own still comes back *changed* (the bootstrap is
  prepended unconditionally), so `!=` is not a proxy for it. And a declined project compiles
  with inference on, which on metamutant-shaped code can stretch the one compile from
  seconds to hours, so `Mutare.Sandbox` narrates the reason.

  A `before_compile` hook wraps `project/0`, preserving its computed configuration
  and every other compiler option. Only sandbox project files are rewritten;
  the target's original options remain untouched. Unsupported Elixir versions
  retain the original configuration. Quoted module definitions are left alone.

  The rewrite declines and returns the original source byte-for-byte when:

    * the source does not parse;
    * the rewritten file does not parse, or Elixir reads it back as anything other than
      the bootstrap followed by the original with a hook appended to each module body.
      The two are compared as parsed programs, ignoring only spellings that evaluate
      alike (metadata, block nesting, an empty block as `nil`, a charlist as a `~c`
      sigil), so a render that still parses but moved an expression, altered a literal,
      or lost a hook is caught instead of becoming the sandbox's entry point;
    * the rewrite raises, throws, or exits.

  Parsing and rendering are best-effort, so an unused umbrella child or a scaffolding
  template cannot abort sandbox preparation. Keeping the original merely leaves inference
  on, where a `mix.exs` rendered into a different program would break the sandbox or
  change what it builds.

  A `mix.exs` defining no module of its own also declines, but comes back rewritten (the
  bootstrap is inert there): a project module built entirely in an externally required
  file is outside this source rewrite, and its compiler options must currently disable
  inference themselves.

  `:hooked` reports the source rewrite, which is one step short of certainty: the hook
  itself checks at compile time that the module is a Mix project defining `project/0`, so
  a `mix.exs` holding only an unrelated helper module alongside a required-in project
  reports `:hooked` and is nonetheless declined. Nothing observable before the compile can
  close that gap, and the manifest is stamped before it.

  Merely setting `Code.put_compiler_option(:infer_signatures, false)` before
  compilation is insufficient: Elixir 1.20 Mix unconditionally derives inference
  from `elixirc_options`, defaulting to true. Updating the current project stack
  also fails when Mix pushes a cached umbrella project again. Wrapping the
  project's return value covers both cases without interpreting its build code.
  """
  @spec project_source(String.t()) :: {:hooked, String.t()} | {:declined, String.t(), String.t()}
  def project_source(source), do: project_source(source, &render/1)

  # The seam the declining paths are tested through: `render` stands in for Sourceror's
  # renderer, so a test can make the rewrite unfaithful, unparseable, or abort.
  @doc false
  @spec project_source(String.t(), (Macro.t() -> String.t())) ::
          {:hooked, String.t()} | {:declined, String.t(), String.t()}
  def project_source(source, render) do
    with {:ok, ast} <- read(Sourceror.parse_string(source), "it does not parse"),
         {ast, hooked?} = wrap_project_modules(ast, false),
         rendered = @bootstrap_source <> "\n\n" <> render.(ast) <> "\n",
         :ok <- same_program(rendered, source) do
      if hooked?,
        do: {:hooked, rendered},
        else: {:declined, rendered, "it defines no module of its own to hook"}
    else
      {:error, reason} -> {:declined, source, reason}
    end
  rescue
    e -> {:declined, source, "the rewrite raised: " <> Exception.message(e)}
  catch
    kind, reason -> {:declined, source, "the rewrite aborted (#{kind} #{inspect(reason)})"}
  end

  defp render(ast), do: Sourceror.to_string(ast, Mutare.AST.render_opts())

  # Renders are not guaranteed to round-trip, and this file is the sandbox's entry point, so
  # parsing is not enough: a render that still parses but moved an expression, altered a
  # literal, or dropped a hook would ship a `mix.exs` that builds something else, or claim a
  # hook `Seed` then trusts. Accept it only if Elixir reads back the program we meant — the
  # bootstrap, then the original as Elixir reads it, hooked by the same walk.
  defp same_program(rendered, source) do
    with {:ok, actual} <- read(quoted(rendered), "the rewritten file does not parse"),
         {:ok, original} <- read(quoted(source), "it does not parse") do
      {expected, _hooked?} = wrap_project_modules(original, false)

      if normalize(actual) == normalize({:__block__, [], [@bootstrap_quoted, expected]}),
        do: :ok,
        else: {:error, "rewriting it would change its meaning"}
    end
  end

  defp quoted(string), do: Code.string_to_quoted(string, emit_warnings: false)

  # Either parser's result, a syntax error reduced to one line. Sourceror and
  # `Code.string_to_quoted/2` report the same `{location, message, token}` triple, where the
  # raising variants would put a multi-line snippet into a progress note.
  defp read({:ok, ast}, _failure), do: {:ok, ast}

  defp read({:error, {location, message, token}}, failure),
    do: {:error, "#{failure} (line #{location[:line]}: #{syntax_error(message, token)})"}

  defp syntax_error({prefix, suffix}, token), do: prefix <> token <> suffix
  defp syntax_error(message, token), do: message <> token

  # Two readings of one program may differ in metadata and in how a few things are spelled, and
  # in nothing else that evaluation can see. A render may parenthesise a module body into a
  # block of its own, whose statements run exactly as they would inline, the last still giving
  # the value; it spells an empty body as the `nil` that body evaluates to; and it may spell a
  # single-quoted charlist as the `~c` sigil that expands to the same list at compile time
  # (seen in call arguments and statements, not inside a keyword value). So blocks splice into
  # their parent, a one-statement block is its statement (which also unwraps the hook's literal
  # encoding), an empty block is `nil`, and a `~c` sigil without interpolation or modifiers is
  # its charlist. An interpolated one stays a sigil, so a render that re-spells it declines.
  defp normalize(ast) do
    Macro.postwalk(ast, fn
      {:__block__, _meta, exprs} ->
        exprs |> Enum.flat_map(&statements/1) |> block()

      {:sigil_c, _meta, [{:<<>>, _, [chars]}, []]} when is_binary(chars) ->
        chars |> Macro.unescape_string() |> String.to_charlist()

      {form, _meta, args} ->
        {form, [], args}

      node ->
        node
    end)
  end

  # Children are already normalised, so any block left here holds two or more statements.
  defp statements({:__block__, _meta, exprs}), do: exprs
  defp statements(expr), do: [expr]

  defp block([]), do: nil
  defp block([expr]), do: expr
  defp block(exprs), do: {:__block__, [], exprs}

  # Walks the source, appending the hook to every module defined in it, and reports whether
  # it appended any. The flag rides along rather than being recovered from the result,
  # because the rendered string cannot distinguish "no module here" from "hook attached".

  # A quote is data that can leave the sandbox, including through a macro defined
  # in mix.exs. Never give its modules a dependency on our bootstrap. The bare form is
  # the only one to guard, and the asymmetry with `module_definition?/1` — which does
  # recognise a qualified `Kernel.defmodule` — is deliberate: `quote` is a special form
  # with no qualified spelling, so `Kernel.quote` names no macro. It is an undefined
  # remote call that evaluates its `do:` block eagerly, making a `defmodule` inside it a
  # real definition that must be hooked like any other.
  defp wrap_project_modules({:quote, _meta, _args} = node, hooked?), do: {node, hooked?}

  defp wrap_project_modules({form, meta, args}, hooked?) when is_list(args) do
    {form, hooked?} = wrap_project_modules(form, hooked?)
    {args, hooked?} = wrap_project_modules(args, hooked?)
    node = {form, meta, args}

    case node do
      {form, meta, [name, [{do_key, body}]]} ->
        if module_definition?(form) and Mutare.AST.key_atom(do_key) == :do,
          do: {{form, meta, [name, [{do_key, append_project_hook(body)}]]}, true},
          else: {node, hooked?}

      _ ->
        {node, hooked?}
    end
  end

  defp wrap_project_modules({left, right}, hooked?) do
    {left, hooked?} = wrap_project_modules(left, hooked?)
    {right, hooked?} = wrap_project_modules(right, hooked?)
    {{left, right}, hooked?}
  end

  defp wrap_project_modules(list, hooked?) when is_list(list),
    do: Enum.map_reduce(list, hooked?, &wrap_project_modules/2)

  defp wrap_project_modules(node, hooked?), do: {node, hooked?}

  defp module_definition?(:defmodule), do: true

  defp module_definition?({:., _, [{:__aliases__, _, parts}, :defmodule]}),
    do: parts in [[:Kernel], [:"Elixir", :Kernel]]

  defp module_definition?(_), do: false

  defp append_project_hook(body) do
    hook = Mutare.AST.literal(@project_hook)

    quote do
      unquote(body)
      @before_compile unquote(hook)
    end
  end

  @doc """
  Align a freshly seeded Elixir manifest with the sandbox inference override.

  Only the inference entry of the compiler cache key changes. Existing beams
  remain valid with inference disabled; all other options, source paths and
  dependency/configuration records retain their ordinary invalidation behavior.
  This must only run when transplanting the target's build, never on a retained
  sandbox build or a dependency build.

  Mix's manifest is private: recognize the 1.18/1.19 layouts (versions 26–29),
  and leave unknown layouts alone, allowing Mix to cold-compile if necessary.
  Elixir 1.20 removes inference from this key and needs no adjustment here.
  """
  @spec seed_manifest(term()) :: term()
  def seed_manifest(manifest)
      when is_tuple(manifest) and tuple_size(manifest) in 9..11 and
             elem(manifest, 0) in 26..29 and is_map(elem(manifest, 1)) and
             is_map(elem(manifest, 2)) do
    if :infer_signatures in Code.available_compiler_options() do
      put_elem(manifest, 5, seed_cache_key(elem(manifest, 5)))
    else
      manifest
    end
  end

  def seed_manifest(manifest), do: manifest

  defp seed_cache_key({options, paths, optional?})
       when is_list(options) and is_list(paths) and is_boolean(optional?),
       do: {seed_options(options), paths, optional?}

  defp seed_cache_key({options, paths, cwd, optional?})
       when is_list(options) and is_list(paths) and is_binary(cwd) and is_boolean(optional?),
       do: {seed_options(options), paths, cwd, optional?}

  defp seed_cache_key(key), do: key

  # Same ordering as project_source/1, including when Mix merges an xref
  # :no_warn_undefined entry to the options before forming its cache key.
  defp seed_options(options),
    do: Keyword.put(options, :infer_signatures, false)

  @doc """
  Build the `ERL_COMPILER_OPTIONS` value for the metamutant compile: prepend
  `#{@metamutant_compile_opt}` to any `inherited` value (an Erlang term-list string,
  or `nil`/`""` for none), always returning a well-formed `[...]` list string. Pure,
  so the merge is unit-testable.
  """
  @spec erl_compiler_options(String.t() | nil) :: String.t()
  def erl_compiler_options(inherited) do
    case inherited && String.trim(inherited) do
      blank when blank in [nil, ""] ->
        "[#{@metamutant_compile_opt}]"

      trimmed ->
        # Strip the inherited list's outer brackets only (`binary_part`, not `trim` —
        # a nested `[…]` or a trailing `]` inside a term must survive) and splice our
        # option in front; a bare term gets wrapped into a list with it.
        inner =
          if bracketed_list?(trimmed) do
            trimmed |> binary_part(1, byte_size(trimmed) - 2) |> String.trim()
          else
            trimmed
          end

        if inner == "",
          do: "[#{@metamutant_compile_opt}]",
          else: "[#{@metamutant_compile_opt}, #{inner}]"
    end
  end

  defp bracketed_list?(str),
    do: String.starts_with?(str, "[") and String.ends_with?(str, "]")
end
