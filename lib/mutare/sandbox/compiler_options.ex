defmodule Mutare.Sandbox.CompilerOptions do
  @moduledoc """
  The switches that tune the **one** metamutant compile for speed.

  Mutare compiles the metamutant exactly once before any mutant runs, so it can
  afford to drop compile-time work that would be net-negative if paid per run —
  and everything dropped here is *diagnostics-only*: the metamutant is a build
  artifact whose warnings nobody reads, and none of it changes the compiled
  code a mutant run executes. Three switches, one home (this module), three
  delivery routes:

    * `compiler_env/0` — the `ERL_COMPILER_OPTIONS` entry `Mutare.Runner`
      applies to the single `mix compile` (the SSA alias pass off).
    * `compile_args/1` — extra `mix compile` CLI switches for the same
      invocation (`--no-verification`, Elixir ≥ 1.19: skips the
      `Module.ParallelChecker` verify pass — undefined-remote warnings and
      cross-module type checking).
    * `infer_signatures_off_ast/0` — a snippet `Mutare.Sandbox` prefixes into
      the sandbox `config/config.exs`, turning off type-signature *inference*
      during module compilation (a project-level `elixirc_options` setting with
      no CLI or env form, so it rides the config file Mutare already owns).

  The last two exist because Elixir's type checker (≥ 1.18/1.19) is
  pathological on metamutant-shaped code: measured on phoenix_live_view
  (~23k sites), inference + verification take a 14 s compile past 80 *minutes*;
  with both off it is 14 s again. See NOTES "Type inference and verification
  on the metamutant compile".

  A per-mutant `mix test` never recompiles the lib (sources unchanged), so the
  env and args carry nothing there; the config snippet does load on every boot
  but only affects compilation, so it is equally inert.
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

  @doc """
  AST that turns off type-signature inference for code compiled after it runs.

  `Mutare.Sandbox` prefixes this into the sandbox `config/config.exs` (mix
  evaluates config before the compilers run), because `:infer_signatures` is a
  project-level `elixirc_options` setting with no CLI switch or env var — the
  config file is the one hook Mutare already owns. Inference feeds only type
  *diagnostics*; the compiled code is identical. On metamutant-shaped code it
  is pathological (measured: five phoenix_live_view modules alone push a 14 s
  compile past 80 minutes).

  The `rescue` makes it a no-op wherever the option doesn't exist
  (`Code.put_compiler_option/2` raises on unknown options pre-1.18) — the same
  safe-everywhere property `#{@metamutant_compile_opt}` gets from unknown
  Erlang options being ignored. A target that sets `:infer_signatures`
  explicitly in its own `elixirc_options` still wins: Mix applies project
  options after config is loaded.
  """
  @spec infer_signatures_off_ast() :: Macro.t()
  def infer_signatures_off_ast do
    quote do
      try do
        Code.put_compiler_option(:infer_signatures, false)
      rescue
        # Elixir < 1.18: the option doesn't exist (and inference doesn't either).
        _ -> :ok
      end
    end
  end

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
