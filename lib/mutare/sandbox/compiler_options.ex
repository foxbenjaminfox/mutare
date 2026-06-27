defmodule Mutare.Sandbox.CompilerOptions do
  @moduledoc """
  The env that tunes the **one** metamutant compile for speed.

  Mutare compiles the metamutant exactly once before any mutant runs, so it can
  afford a compile-time optimisation that would be net-negative if paid per run.
  `compiler_env/0` is the `ERL_COMPILER_OPTIONS` entry `Mutare.Runner` applies to
  that single `mix compile`; a per-mutant `mix test` never recompiles the lib
  (sources unchanged), so it carries nothing.
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
