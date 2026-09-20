defmodule Mutare.InvariantError do
  @moduledoc """
  Raised under `verify_invariants: true` (`mix mutare --verify-invariants`) when a rendered
  metamutant breaks a property the run's results depend on.

  Every violation is a bug in Mutare or in a custom mutator, host, or extension enabled for the
  run — never a problem with the project under test. Most would otherwise corrupt the report
  silently: a recorded mutant that the metamutant cannot select runs the unmutated code, so it
  survives whatever the suite checks, and one that no coverage record lists is reported as
  uncovered and never tested.

  `file` is the transformed file; `violations` lists what the checks found, in this order:

    * `{:unparseable_metamutant, message}` — the rendered metamutant is not valid Elixir, so
      no other readback check could run.
    * `{:missing_branch, site}` — no generated code selects the mutant.
    * `{:unreachable_branch, site, enclosing}` — the mutant's only branches sit inside the
      branches of other mutants (`enclosing`), which never run while this one is the only active
      mutant.
    * `{:stray_branch, subject}` — generated code selects an id that the transform did not
      deliver.
    * `{:missing_record, site}` — no coverage record outside every mutant branch lists the
      mutant.
    * `{:stray_record, subject}` — a coverage record lists an id that the transform did not
      deliver.
    * `{:unread_clean_region, decision}` — the transform emitted a clean region
      (`Mutare.Transform.CleanRegion`) whose uninstrumented copy `Mutare.Manifest` cannot find.
      The copy belongs to no mutant, so a compile error inside it could be blamed on nothing
      and would sink the single build.
    * `{:stray_clean_region, range}` — the metamutant holds a clean region the transform did
      not decide on.
    * `{:unchanged_mutant, site}` — the mutant renders identically to its original code, so no
      test can kill it.
    * `{:nondeterministic_render, differences}` — emitting the same source again gave a
      different result, so report-time diffs (which re-render) may describe other mutants than
      the ones that ran.

  A `subject` is `{local_id, site}`: the integer the generated code selects on, and the Site the
  transform recorded under it (`nil` when there is none — then the id belongs to no mutant).
  """

  alias Mutare.Site

  @typedoc "An id the generated code names, and the Site recorded under it, if any."
  @type subject :: {non_neg_integer(), Site.t() | nil}

  @typedoc """
  What the transform decided for one clean region: the `:function` it belongs to, its
  `:delivery` (`:lifted` or `:in_place`), and the `:range` of ids identifying it, among
  other fields.
  """
  @type clean_decision :: %{
          required(:function) => {atom(), arity()},
          required(:delivery) => :lifted | :in_place,
          required(:range) => Mutare.Manifest.clean_range(),
          optional(atom()) => term()
        }

  @type violation ::
          {:unparseable_metamutant, String.t()}
          | {:missing_branch, Site.t()}
          | {:unreachable_branch, Site.t(), [subject()]}
          | {:stray_branch, subject()}
          | {:missing_record, Site.t()}
          | {:stray_record, subject()}
          | {:unread_clean_region, clean_decision()}
          | {:stray_clean_region, Mutare.Manifest.clean_range()}
          | {:unchanged_mutant, Site.t()}
          | {:nondeterministic_render, [String.t()]}

  @type t :: %__MODULE__{message: String.t(), file: String.t(), violations: [violation()]}

  defexception [:message, :file, violations: []]

  @impl true
  def exception(opts) do
    file = Keyword.fetch!(opts, :file)
    violations = Keyword.fetch!(opts, :violations)
    %__MODULE__{file: file, violations: violations, message: message(file, violations)}
  end

  defp message(file, violations) do
    count = length(violations)

    """
    invariant check failed for #{file} (#{count} violation#{if count == 1, do: "", else: "s"}):

    #{Enum.map_join(violations, "\n", &("  * " <> describe(&1)))}

    Each is a bug in Mutare or in a custom mutator, host, or extension enabled for this run, \
    not in the project under test.\
    """
  end

  defp describe({:unparseable_metamutant, message}),
    do: "the rendered metamutant does not parse: #{message}"

  defp describe({:missing_branch, site}),
    do:
      "#{mutant(site)} has no branch in the metamutant: activating it runs the original code, " <>
        "so no test can kill it"

  defp describe({:unreachable_branch, site, enclosing}),
    do:
      "#{mutant(site)} has branches only inside the branch of " <>
        "#{Enum.map_join(enclosing, ", ", &subject/1)}: no run that activates it alone reaches " <>
        "them, so no test can kill it"

  defp describe({:stray_branch, subject}),
    do: "the metamutant has a branch for #{stray(subject)}"

  defp describe({:missing_record, site}),
    do:
      "no coverage record lists #{mutant(site)}, so the run would record it as uncovered " <>
        "and never test it"

  defp describe({:stray_record, subject}),
    do: "a coverage record lists #{stray(subject)}"

  defp describe({:unread_clean_region, decision}) do
    {name, arity} = decision.function
    {first, last} = decision.range

    "the clean region of #{name}/#{arity} (ids #{first}–#{last}, #{decision.delivery}) cannot be " <>
      "read back from the metamutant: a compile error in its uninstrumented copy could not " <>
      "be attributed, so poison recovery could not save the build"
  end

  defp describe({:stray_clean_region, {first, last}}),
    do: "the metamutant holds a clean region (ids #{first}–#{last}) the transform did not emit"

  defp describe({:unchanged_mutant, site}),
    do:
      "#{mutant(site)} renders identically to the original, so no test can kill it (a " <>
        "replacement that keeps the original node's metadata re-renders the original text; " <>
        "build literals with `Mutare.AST.literal/1`)"

  defp describe({:nondeterministic_render, differences}),
    do:
      "emitting the file a second time gave a different result (#{Enum.join(differences, "; ")}); " <>
        "report-time diffs are re-rendered, so they could describe other mutants than the ones " <>
        "that ran"

  defp mutant(%Site{} = site) do
    code =
      if site.original_code,
        do: " `#{one_line(site.original_code)}` → `#{one_line(site.mutated_code)}`",
        else: ""

    "mutant ##{site.id} (#{site.mutator}, #{site.file}:#{site.line})#{code}"
  end

  defp subject({local, nil}), do: "id #{local}, which no mutant records"
  defp subject({_local, %Site{} = site}), do: "#{mutant(site)}#{withheld(site)}"

  # A recorded mutant the generated code should not have named; an id nothing records needs no
  # more said.
  defp stray({_local, nil} = subject), do: subject(subject)
  defp stray(subject), do: "#{subject(subject)}, which the transform did not deliver"

  # Why the transform held a recorded mutant back, when it did.
  defp withheld(%Site{poisoned: true}), do: " (poisoned)"
  defp withheld(%Site{ignored: true}), do: " (ignored)"
  defp withheld(%Site{}), do: ""

  defp one_line(code), do: code |> String.split("\n") |> Enum.map_join(" ", &String.trim/1)
end
