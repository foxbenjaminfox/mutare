defmodule Mutare.CLI.Diagnostics do
  @moduledoc false
  # Scan-time diagnostics for the `# mutare:ignore` comment namespace and the `:skip_lifting` escape
  # hatch, extracted from `Mix.Tasks.Mutare`. `surface/2` warns (on stderr) about unknown `mutare:`
  # verbs, directives/entries that suppressed nothing, and skip-lifting entries that matched no
  # function, then enforces `--strict-ignores` as a hard Mix failure. `Mutare.CLI.Info.print_ignores/2`
  # is the inspect-and-exit sibling; this is the run-path counterpart.

  alias Mutare.{CLI, Lifting, Options, Schema}
  alias Mutare.Ignore.Directive

  # Surface every scan-time directive/skip-lifting diagnostic, then enforce `--strict-ignores`.
  # Called from the scan prelude right after the mutant count is announced.
  @spec surface(Schema.t(), Options.t()) :: :ok
  def surface(%Schema{} = schema, %Options{} = options) do
    warn_unknown_directives(schema)
    warn_ineffective_ignores(schema)
    warn_ineffective_skip_lifting(schema)
    warn_ineffective_call_routes(schema)
    warn_ineffective_argument_marks(schema)
    enforce_strict_ignores(schema, options)
  end

  # Warn about every comment that claims the reserved `mutare:` namespace without a
  # recognized directive — a typo'd verb (`# mutare:ingore`), a colon-detached one
  # (`# mutare: ignore`), or a directive from a future Mutare version (see
  # `Mutare.Schema.detect_directive_diagnostics/1`). Onto **stderr**, like the
  # ineffective warnings below; `--strict-ignores` turns these into a hard error too.
  defp warn_unknown_directives(%Schema{unknown_directives: []}), do: :ok

  defp warn_unknown_directives(%Schema{unknown_directives: unknown}) do
    for {file, line, head} <- unknown do
      IO.puts(
        :stderr,
        "warning: # #{head} at #{file}:#{line} is not a recognized directive" <>
          Mutare.Ignore.verb_hint(head)
      )
    end

    :ok
  end

  # Warn about every `# mutare:ignore` that suppressed no mutant — a typo'd family
  # (`[arithmatic]`), an empty `[]`, a misplaced standalone line, or a family that
  # produced no mutant there (see `Mutare.Schema.detect_directive_diagnostics/1`).
  # Onto **stderr** (like `Mutare.Report.Live`), so a machine report on stdout
  # stays clean. `--strict-ignores` then turns these into a hard error.
  defp warn_ineffective_ignores(%Schema{ineffective_ignores: []}), do: :ok

  defp warn_ineffective_ignores(%Schema{ineffective_ignores: ineffective}) do
    for {file, directive, hint} <- ineffective do
      # `Directive.verb/1` echoes the verb as written — `ignore`, `ignore-file`, or
      # `ignore-start` — so a scoped directive's warning points at the right comment.
      IO.puts(
        :stderr,
        "warning: # mutare:#{Directive.verb(directive)}" <>
          "#{Directive.filter_label(directive.mutators)} at " <>
          "#{file}:#{directive.comment_line} suppressed no mutant" <> misplacement_label(hint)
      )
    end

    :ok
  end

  # The `:skip_lifting` mirror of `warn_ineffective_ignores/1`: a configured entry that
  # matched no function anywhere in the scan (`Mutare.Schema.detect_ineffective_skip_lifting`
  # — recorded only on a full scan, so `--since`/`--only`/`--line` never false-positive).
  # Without it a typo'd module or a wrong arity leaves the escape hatch silently inert —
  # the user keeps hitting the baseline failure the entry was meant to avoid. Onto stderr,
  # like the ignore diagnostics. Warning-only: `--strict-ignores` is scoped to the ignore
  # comment namespace, and these entries live in config, not source.
  defp warn_ineffective_skip_lifting(%Schema{ineffective_skip_lifting: []}), do: :ok

  defp warn_ineffective_skip_lifting(%Schema{ineffective_skip_lifting: entries}) do
    for entry <- entries do
      IO.puts(
        :stderr,
        "warning: :skip_lifting entry #{Lifting.format_entry(entry)} matched no function — " <>
          "check the module name and the function's written head arity " <>
          "(default arguments count toward it)"
      )
    end

    :ok
  end

  # The `:call_routes` / `:argument_marks` mirrors of `warn_ineffective_skip_lifting/1`: a configured
  # entry no resolved call hit anywhere in a full scan (`Mutare.Schema.detect_ineffective_config/3`).
  # A `{Mixpanel, :track, 3, :skip}` aimed at a call that is actually `track/2`, or a module name
  # with a typo, would otherwise leave the route silently inert — the opposite of the "nothing in
  # config is silently inert" stance the ignore namespace already takes. Warning-only, like
  # `:skip_lifting`: these live in config, not source, so `--strict-ignores` leaves them alone.
  defp warn_ineffective_call_routes(%Schema{ineffective_call_routes: []}), do: :ok

  defp warn_ineffective_call_routes(%Schema{ineffective_call_routes: specs}) do
    for spec <- specs do
      IO.puts(
        :stderr,
        "warning: :call_routes entry #{format_route(spec)} matched no call — check the module " <>
          "name, the function name, and the arity (a piped receiver counts toward it)"
      )
    end

    :ok
  end

  defp warn_ineffective_argument_marks(%Schema{ineffective_argument_marks: []}), do: :ok

  defp warn_ineffective_argument_marks(%Schema{ineffective_argument_marks: entries}) do
    for {module, fun, arity, _positions, label} <- entries do
      IO.puts(
        :stderr,
        "warning: :argument_marks entry #{inspect(module)}.#{fun}/#{arity} (#{inspect(label)}) " <>
          "matched no call — check the module name, the function name, and the arity (a piped " <>
          "receiver counts toward it)"
      )
    end

    :ok
  end

  # A route as the user would write it: `{Mixpanel, :track, 3}` / `{Ecto.Query, :*, :any}`.
  defp format_route(%Mutare.CallRouting.Spec{module: module, name: name, arity: arity}),
    do: "{#{format_route_module(module)}, #{inspect(name)}, #{inspect(arity)}}"

  defp format_route_module(path) when is_list(path), do: inspect(Module.concat(path))
  defp format_route_module(atom), do: inspect(atom)

  # The "directive on the pipe's first line" miss: the mutants it named sit further
  # down the *same* multi-line expression (`Mutare.Ignore.misplacement_hint/3`).
  # A directive covers exactly one line, so name the line to move it above.
  defp misplacement_label(nil), do: ""

  defp misplacement_label(line),
    do:
      " — its matching mutants are on line #{line} of the same multi-line expression; " <>
        "a directive covers one line, so place it directly above line #{line}"

  # `--strict-ignores`: a directive that suppressed nothing — or an unrecognized
  # `# mutare:` comment — is a hard error (the CI counterpart of the warnings
  # above), surfaced as a clean Mix failure → non-zero exit, mirroring the
  # `--min-score` `gate/2`. The per-comment detail already printed via
  # `warn_unknown_directives/1` / `warn_ineffective_ignores/1`.
  defp enforce_strict_ignores(
         %Schema{ineffective_ignores: [], unknown_directives: []},
         _options
       ),
       do: :ok

  defp enforce_strict_ignores(%Schema{}, %Options{strict_ignores: false}), do: :ok

  defp enforce_strict_ignores(
         %Schema{ineffective_ignores: ineffective, unknown_directives: unknown},
         %Options{strict_ignores: true}
       ) do
    problems =
      Enum.reject([ineffective_problem(ineffective), unknown_problem(unknown)], &is_nil/1)

    Mix.raise("--strict-ignores: " <> Enum.join(problems, "; ") <> " (see the warnings above)")
  end

  defp ineffective_problem([]), do: nil

  defp ineffective_problem(ineffective) do
    n = length(ineffective)
    "#{n} `# mutare:ignore` directive#{CLI.plural(n)} suppressed no mutant"
  end

  defp unknown_problem([]), do: nil

  defp unknown_problem(unknown) do
    n = length(unknown)
    "#{n} `# mutare:` comment#{CLI.plural(n)} named no recognized directive"
  end
end
