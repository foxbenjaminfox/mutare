defmodule Mutare.Test.Project do
  @moduledoc """
  Lays down a throwaway target project in a unique temp dir for the
  `:runner`-tagged end-to-end tests, and registers its cleanup.

  Every runner test needs the same scaffold — a unique base dir holding a
  `project/` (named for its app) and a sibling `sandbox/`, a minimal `mix.exs`,
  a `test/test_helper.exs`, and `File.rm_rf!` on exit — differing only in the
  lib sources and test suite actually under test. This builds that scaffold so
  each test spells out just what is unique to it.
  """

  @doc """
  A unique, not-yet-created temp path tagged for easy identification in
  `System.tmp_dir!()` (e.g. `mutare_calc_17`).
  """
  @spec tmp_dir(atom() | String.t()) :: Path.t()
  def tmp_dir(tag) do
    Path.join(System.tmp_dir!(), "mutare_#{tag}_#{System.unique_integer([:positive])}")
  end

  @doc """
  Build a target project named `app` from `files` and register its cleanup.

  `files` is a map of `relative_path => contents`. A boilerplate `mix.exs` and a
  `test/test_helper.exs` are supplied automatically — override either by listing
  it in `files`. Returns `%{base:, project:, sandbox:}` paths, where `project`
  is ready to hand to `Mutare.run/2` and `sandbox` is its scratch dir.

  Cleanup runs via ExUnit's `on_exit`, so call this from a `setup` block or a
  test body.
  """
  @spec build(atom(), %{optional(String.t()) => iodata()}) :: %{
          base: Path.t(),
          project: Path.t(),
          sandbox: Path.t()
        }
  def build(app, files) do
    base = tmp_dir(app)
    project = Path.join(base, to_string(app))
    sandbox = Path.join(base, "sandbox")

    %{"mix.exs" => mix_exs(app), "test/test_helper.exs" => "ExUnit.start()\n"}
    |> Map.merge(files)
    |> Enum.each(fn {rel, contents} -> write(project, rel, contents) end)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, project: project, sandbox: sandbox}
  end

  defp mix_exs(app) do
    module = app |> to_string() |> Macro.camelize()

    """
    defmodule #{module}.MixProject do
      use Mix.Project
      def project, do: [app: :#{app}, version: "0.1.0", elixir: "~> 1.15"]
      def application, do: []
    end
    """
  end

  defp write(project, rel, contents) do
    path = Path.join(project, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
