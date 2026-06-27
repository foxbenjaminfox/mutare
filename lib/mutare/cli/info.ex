defmodule Mutare.CLI.Info do
  @moduledoc false
  # The inspect-and-exit subcommands of `mix mutare`: each prints information and
  # exits, touching neither the sandbox nor the suite. Extracted from
  # `Mix.Tasks.Mutare` so the task holds the run orchestration and this module the
  # discovery/inspection presentation. The scan-backed commands (`--dry-run`,
  # `--list-ignores`) take a pre-built `Mutare.Schema`, so this module never needs
  # to scan/compile the host itself — the task supplies it.

  alias Mutare.{CLI, Ignore, Macros, Mutators, Options, Project, Site}
  alias Mutare.Ignore.Directive
  alias Mutare.Options.Registry
  alias Mutare.Report.Live

  # `--list-mutators`: print the built-in catalog and exit. Derived from the one
  # `Mutare.Mutators` registry (and each family's own `@moduledoc`), so the list
  # can never drift from the families that actually run.
  def print_mutator_catalog do
    registry = Mutators.registry()

    pad =
      registry
      |> Enum.map(fn {family, _module} -> family |> to_string() |> String.length() end)
      |> Enum.max()

    Mix.shell().info("Built-in mutator families (all run by default):\n")

    Enum.each(registry, fn {family, module} ->
      name = family |> to_string() |> String.pad_trailing(pad)
      Mix.shell().info("  #{name}  #{mutator_summary(module)}")
    end)

    Mix.shell().info("""

    Select a subset with --mutators (comma-separated), e.g.

        mix mutare --mutators relational,arithmetic

    Prefix the list with `builtins` to keep the whole set and add your own:

        mix mutare --mutators builtins,MyApp.MyMutator\
    """)
  end

  # A one-line summary for the catalog: the family module's `@moduledoc` flattened
  # to a single line, stripped of Markdown noise (but keeping a lone `*` operator)
  # and truncated. Empty when a module ships without docs (a docs-stripped build).
  @summary_width 78
  defp mutator_summary(module) do
    case fetch_moduledoc(module) do
      {:ok, doc} ->
        doc
        |> String.replace(~r/^[ \t]*\*[ \t]+/m, "")
        |> String.replace(~r/\*\*/, "")
        |> String.replace("`", "")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> Live.truncate(@summary_width)

      :error ->
        ""
    end
  end

  # The module's English `@moduledoc`, or `:error` when it ships without docs (a docs-stripped
  # build) — the single match on the `Code.fetch_docs/1` tuple shape, shared by the catalog
  # summary and `--explain`.
  defp fetch_moduledoc(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) -> {:ok, doc}
      _ -> :error
    end
  end

  # `--version`: the installed mutare version.
  def version_string do
    case Application.spec(:mutare, :vsn) do
      nil -> "mutare (version unknown)"
      vsn -> "mutare #{vsn}"
    end
  end

  # `--explain <family-or-module>`: print one mutator's full `@moduledoc`. Resolves a
  # built-in family name through the registry, or a custom module name directly.
  def explain_mutator(name) do
    case explainable(name) do
      {family, module} ->
        Mix.shell().info("#{family}  (#{inspect(module)})\n")
        Mix.shell().info(full_moduledoc(module))

      nil ->
        Mix.raise(
          "unknown mutator #{inspect(name)} — run `mix mutare --list-mutators` to see the families"
        )
    end
  end

  defp explainable(name) do
    case Enum.find(Mutators.registry(), fn {family, _} -> to_string(family) == name end) do
      {family, module} ->
        {family, module}

      nil ->
        with module when is_atom(module) <- resolve_module(name),
             true <- Code.ensure_loaded?(module) and function_exported?(module, :name, 0) do
          {module.name(), module}
        else
          _ -> nil
        end
    end
  end

  # Resolve a custom-module `--explain` argument to a module atom **without minting
  # one for arbitrary input**. Prefer the *existing* atom: any already-loaded module —
  # including one compiled at runtime via `Code.compile_string/1` or `:code.load_binary/3`,
  # which leaves no `.beam` on the code path — interns its name atom at load time, so
  # `String.to_existing_atom/1` resolves it without growing the table (and the caller's
  # `Code.ensure_loaded?` then confirms it). The beam-file gate alone misses such a module
  # and wrongly returns `nil`, the regression this restores. Only when no such atom exists
  # do we fall back to that gate: `:code.where_is_file/1` searches by filename and interns
  # nothing, so the table grows (via `String.to_atom/1`) only for a module genuinely present
  # on disk, and junk input still falls through to the "unknown mutator" error. Built-in
  # families never reach here — they match the registry above.
  defp resolve_module(name) do
    candidate = qualified_module_name(name)

    try do
      String.to_existing_atom(candidate)
    rescue
      ArgumentError -> resolve_module_from_beam(candidate)
    end
  end

  # The fully `Elixir.`-qualified module-name string, folding an explicit leading `Elixir.`
  # so `--explain Elixir.MyApp.M` and `--explain MyApp.M` name the same module — matching
  # `Module.concat/1` and the qualified form `--mutators` already accepts. Blindly prepending
  # would search for `Elixir.Elixir.MyApp.M` and report a valid mutator as unknown.
  defp qualified_module_name("Elixir." <> _ = name), do: name
  defp qualified_module_name(name), do: "Elixir." <> name

  defp resolve_module_from_beam(candidate) do
    case :code.where_is_file(String.to_charlist(candidate <> ".beam")) do
      :non_existing -> nil
      _path -> String.to_atom(candidate)
    end
  end

  defp full_moduledoc(module) do
    case fetch_moduledoc(module) do
      {:ok, doc} -> String.trim_trailing(doc)
      :error -> "(no documentation available for #{inspect(module)})"
    end
  end

  # `--show-config`: the effective options after merging `.mutare.exs`, CLI flags, and
  # defaults — so config precedence is no longer invisible. The option rows + their
  # formatting come from `Mutare.Options.Registry.display_rows/1` (the single source for
  # visibility and per-field formatting), so every visible option appears and none can be
  # silently forgotten the way `partition_env`/`seed_app_build`/… once were. We only prepend
  # the `target` row, which is run context (the project), not an option.
  def print_effective_config(%Project{} = project, %Options{} = options) do
    rows = [{"target", target_label(project)} | Registry.display_rows(options)]

    Mix.shell().info("Effective configuration (.mutare.exs + CLI flags + defaults):\n")
    print_aligned(rows)
  end

  defp target_label(%Project{umbrella?: true, mutate_scope: scope, copy_root: root}),
    do: "#{root} (umbrella apps: #{CLI.umbrella_apps(scope)})"

  defp target_label(%Project{copy_root: root}), do: root

  defp print_aligned(rows) do
    pad = rows |> Enum.map(fn {k, _} -> String.length(k) end) |> Enum.max()
    Enum.each(rows, fn {k, v} -> Mix.shell().info("  #{String.pad_trailing(k, pad)}  #{v}") end)
  end

  # `--list-macros`: the known-macro registry (built-ins + the `:macros` option + any
  # enabled mutator's `macros/0` + any enabled plugin's `macros/0`) whose arguments the
  # transform routes specially. Threads `options.plugins` into `Macros.build/3` exactly as
  # the real transform does (`Transform`), so the inspected registry is the *effective* one
  # — omitting them would hide every plugin-contributed routing.
  def print_macro_registry(%Options{} = options) do
    specs = Mutators.resolve(options.mutators || Mutators.all())
    registry = Macros.build(options.macros, specs, options.plugins)

    Mix.shell().info(
      "Known macros (arguments routed specially, not mutated as plain expressions):\n"
    )

    registry
    |> Map.values()
    |> Enum.sort_by(fn s ->
      {format_module_key(s.module), to_string(s.name), to_string(s.arity)}
    end)
    |> Enum.each(fn s -> Mix.shell().info("  #{format_macro_spec(s)}") end)
  end

  defp format_macro_spec(spec) do
    sig =
      "#{format_module_key(spec.module)}.#{format_macro_name(spec.name)}/#{format_arity(spec.arity)}"

    via = if spec.host, do: "  (via #{inspect(spec.host)})", else: ""
    "#{String.pad_trailing(sig, 28)}  #{inspect(spec.args)}#{via}"
  end

  defp format_module_key(:*), do: "*"
  defp format_module_key(mod) when is_list(mod), do: Enum.map_join(mod, ".", &Atom.to_string/1)
  defp format_module_key(mod) when is_atom(mod), do: inspect(mod)

  defp format_macro_name(:*), do: "*"
  defp format_macro_name(name), do: to_string(name)

  defp format_arity(a) when a in [:any, :*], do: "any"
  defp format_arity(n), do: to_string(n)

  # `--list-ignores`: every `# mutare:ignore` in scope, flagged active or ineffective
  # (the audit view — a normal run only ever *warns* about the ineffective ones).
  def print_ignores(%Project{} = project, schema) do
    ineffective = MapSet.new(schema.ineffective_ignores)

    entries =
      for {file, source} <- schema.sources,
          String.contains?(source, "mutare:ignore"),
          {_line, directives} <- Ignore.directives(source),
          directive <- directives,
          do: {file, directive}

    if entries == [] do
      Mix.shell().info("No `# mutare:ignore` directives found#{CLI.scope_label(project)}.")
    else
      print_ignore_entries(entries, ineffective)
    end
  end

  defp print_ignore_entries(entries, ineffective) do
    entries
    |> Enum.sort_by(fn {file, d} -> {file, d.line} end)
    |> Enum.group_by(fn {file, _} -> file end)
    |> Enum.sort_by(fn {file, _} -> file end)
    |> Enum.each(fn {file, file_entries} ->
      Mix.shell().info(file)

      Enum.each(file_entries, fn {_file, directive} = entry ->
        status = if MapSet.member?(ineffective, entry), do: "ineffective", else: "active"

        Mix.shell().info(
          "  #{directive.line}  #{String.pad_trailing(status, 11)}  #{format_directive(directive)}"
        )
      end)
    end)

    n = Enum.count(entries, &MapSet.member?(ineffective, &1))

    if n > 0 do
      Mix.shell().info(
        "\n#{n} ineffective directive#{CLI.plural(n)} (suppress nothing — a typo'd family or " <>
          "a stale line); `--strict-ignores` would exit 1."
      )
    end
  end

  defp format_directive(%Directive{mutators: :all, reason: nil}), do: "all families"

  defp format_directive(%Directive{mutators: :all, reason: reason}),
    do: "all families — #{reason}"

  defp format_directive(%Directive{mutators: set, reason: reason}) do
    families = "[#{set |> Enum.sort() |> Enum.join(", ")}]"
    if reason, do: "#{families} — #{reason}", else: families
  end

  # `--dry-run`: list the mutants that would run, by file — no compile, no tests.
  # Honours every scope flag (`--only`/`--since`/`--mutators`/`--line`/…) via the
  # schema, so it answers "what would this exact invocation test?".
  def print_dry_run(%Project{} = project, schema) do
    by_file = Enum.group_by(schema.sites, & &1.file)

    case schema.sites do
      [] ->
        Mix.shell().info("No mutants would be generated#{CLI.scope_label(project)}.")

      sites ->
        n_sites = length(sites)
        n_files = map_size(by_file)

        Mix.shell().info(
          "#{n_sites} mutant#{CLI.plural(n_sites)} across " <>
            "#{n_files} file#{CLI.plural(n_files)} " <>
            "— dry run, nothing compiled or executed:\n"
        )

        by_file
        |> Enum.sort_by(fn {file, _} -> file end)
        |> Enum.each(&print_dry_run_file/1)

        Mix.shell().info(
          "\n(Coverage and survival need a real run; this lists only what would be tested.)"
        )
    end
  end

  defp print_dry_run_file({file, sites}) do
    Mix.shell().info("#{file}  (#{length(sites)})")

    sites
    |> Enum.sort_by(& &1.line)
    |> Enum.each(fn site ->
      ignored = if site.ignored, do: "  [ignored]", else: ""
      Mix.shell().info("  #{site.line}  #{Site.describe(site)}#{ignored}")
    end)
  end
end
