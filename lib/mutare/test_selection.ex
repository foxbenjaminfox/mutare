defmodule Mutare.TestSelection do
  @moduledoc """
  Which tests to run for one mutant, before command-line serialization.

  `:suite` runs everything; `{:files, paths}` runs whole files;
  `{:tests, paths, names}` narrows those files to the named tests; and
  `{:app, dirs}` runs an umbrella app and its dependents' test directories.
  `:no_coverage` launches no run. File, directory, and name lists are nonempty:
  an empty attribution must be resolved explicitly to a broader selection, never
  passed along as an accidental whole-suite command.

  The constructors enforce nonemptiness and sort for deterministic execution.
  Coverage summaries and result labels read `shape/1`; only
  `Mutare.Sandbox.Command` serializes a runnable selection to Mix arguments.
  """

  @type files :: {:files, nonempty_list(Path.t())}
  @type tests :: {:tests, nonempty_list(Path.t()), nonempty_list(String.t())}
  @type app :: {:app, nonempty_list(Path.t())}
  @type covered :: :suite | files() | tests()
  @type runnable :: covered() | app()
  @type t :: runnable() | :no_coverage
  @type shape :: :suite | :files | :tests | :app

  @spec files(nonempty_list(Path.t())) :: files()
  def files([_ | _] = paths), do: {:files, Enum.sort(paths)}

  @spec tests(nonempty_list(Path.t()), nonempty_list(String.t())) :: tests()
  def tests([_ | _] = paths, [_ | _] = names),
    do: {:tests, Enum.sort(paths), Enum.sort(names)}

  @spec app(nonempty_list(Path.t())) :: app()
  def app([_ | _] = dirs), do: {:app, Enum.sort(dirs)}

  @spec shape(t()) :: shape() | :no_coverage
  def shape(:suite), do: :suite
  def shape({:files, [_ | _]}), do: :files
  def shape({:tests, [_ | _], [_ | _]}), do: :tests
  def shape({:app, [_ | _]}), do: :app
  def shape(:no_coverage), do: :no_coverage

  @doc """
  Narrow a whole-suite run to the source file's owning app and its dependents.

  `scopes` comes from `Mutare.Project.app_test_scopes/3`. Unknown apps and empty
  scopes retain the whole suite; every other selection passes through unchanged.
  """
  @spec narrow_to_app(t(), Path.t(), %{atom() => [Path.t()]}) :: t()
  def narrow_to_app(:suite, file, scopes) do
    # Match known app atoms by name; never mint an atom from a source path.
    owner =
      case Path.split(file) do
        ["apps", name | _] -> Enum.find(Map.keys(scopes), &(to_string(&1) == name))
        _ -> nil
      end

    case Map.get(scopes, owner, []) do
      [] -> :suite
      [_ | _] = dirs -> app(dirs)
    end
  end

  def narrow_to_app(selection, _file, _scopes), do: selection
end
