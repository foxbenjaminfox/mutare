defmodule Mutare.Sandbox.DependencyDiagnosticTest do
  use ExUnit.Case, async: true

  alias Mutare.Sandbox.DependencyDiagnostic

  @root "/work/acme"

  test "a fetch failure points deps.get at the original project and preserves Mix output" do
    detail = unchecked("the dependency is not available, run \"mix deps.get\"")
    message = DependencyDiagnostic.format(detail, @root)

    assert message =~ "sandbox dependency validation failed"
    assert message =~ @root
    assert message =~ "MIX_ENV=test mix deps.get"
    assert message =~ "does not run dependency commands automatically"
    assert message =~ "Original Mix dependency diagnostic:\n\n#{detail}"
    refute message =~ "compile-poisoning"
  end

  test "an unresolvable local dependency explains why deps.get is not the fix" do
    message = DependencyDiagnostic.format(unchecked("the dependency is not available"), @root)

    assert message =~ "local/path dependency"
    assert message =~ "outside the copied project or umbrella root"
    assert message =~ "running `deps.get` will not relocate it"
    assert message =~ "Original project root: #{@root}"
  end

  test "compile, divergence, and generic invalid states retain distinct remedies" do
    compile =
      DependencyDiagnostic.format(
        unchecked("please run \"MIX_ENV=test mix deps.compile\""),
        @root
      )

    diverged =
      DependencyDiagnostic.format("Dependencies have diverged:\n* plug: conflicting specs", @root)

    invalid = DependencyDiagnostic.format(unchecked("version requirement mismatch"), @root)

    assert compile =~ "MIX_ENV=test mix deps.compile"
    assert diverged =~ "deps.get` cannot resolve conflicting specs"
    assert diverged =~ "MIX_ENV=test mix deps"
    assert invalid =~ "Apply the remedy shown for each dependency"
  end

  defp unchecked(status) do
    "Unchecked dependencies for environment test:\n* example (Hex package)\n  #{status}\n" <>
      "** (Mix) Can't continue due to errors on dependencies"
  end
end
