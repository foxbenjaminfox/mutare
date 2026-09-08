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
      including umbrella children and projects with a custom config path.

  `seed_manifest/1` reconciles the inference option in a transplanted Elixir
  compile manifest with that wrapper. Without it, Elixir 1.18/1.19 sees changed
  `elixirc_options` and discards every seeded app beam on the first compile.

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

  @doc """
  Override inference in the sandbox copy of a Mix project's effective options.

  A `before_compile` hook wraps `project/0`, preserving its computed configuration
  and every other compiler option. Only sandbox project files are rewritten;
  the target's original options remain untouched. Unsupported Elixir versions
  retain the original configuration.

  Project modules defined entirely in externally required files are outside this
  source rewrite; their compiler options must currently disable inference themselves.
  Quoted module definitions are left alone. Parsing and rendering are best-effort:
  an unsupported project source is returned unchanged, so an unused umbrella child
  or scaffolding template cannot abort sandbox preparation. The rendered result is
  re-parsed before it is accepted — a `mix.exs` that Sourceror renders into something
  Elixir will not read back would break the sandbox outright, where keeping inference
  on merely makes its one compile slower.

  Merely setting `Code.put_compiler_option(:infer_signatures, false)` before
  compilation is insufficient: Elixir 1.20 Mix unconditionally derives inference
  from `elixirc_options`, defaulting to true. Updating the current project stack
  also fails when Mix pushes a cached umbrella project again. Wrapping the
  project's return value covers both cases without interpreting its build code.
  """
  @spec project_source(String.t()) :: String.t()
  def project_source(source) do
    wrapped =
      source
      |> Sourceror.parse_string!()
      |> wrap_project_modules()
      |> Sourceror.to_string(Mutare.AST.render_opts())
      |> then(&(Macro.to_string(@project_bootstrap) <> "\n\n" <> &1 <> "\n"))

    # Renders are not guaranteed to round-trip. Accept only what Elixir can read back, since
    # this file is the sandbox's entry point: an unparseable `mix.exs` fails every later
    # command, while the original keeps a working sandbox that merely compiles with inference on.
    Code.string_to_quoted!(wrapped)
    wrapped
  rescue
    _ -> source
  end

  # A quote is data that can leave the sandbox, including through a macro defined
  # in mix.exs. Never give its modules a dependency on our bootstrap.
  defp wrap_project_modules({:quote, _meta, _args} = node), do: node

  defp wrap_project_modules({form, meta, args}) when is_list(args) do
    node = {wrap_project_modules(form), meta, Enum.map(args, &wrap_project_modules/1)}

    case node do
      {form, meta, [name, [{do_key, body}]]} ->
        if module_definition?(form) and Mutare.AST.key_atom(do_key) == :do,
          do: {form, meta, [name, [{do_key, append_project_hook(body)}]]},
          else: node

      _ ->
        node
    end
  end

  defp wrap_project_modules({left, right}),
    do: {wrap_project_modules(left), wrap_project_modules(right)}

  defp wrap_project_modules(list) when is_list(list), do: Enum.map(list, &wrap_project_modules/1)
  defp wrap_project_modules(node), do: node

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
