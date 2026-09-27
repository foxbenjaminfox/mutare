defmodule Mutare.TestSelectionTest do
  use ExUnit.Case, async: true

  alias Mutare.TestSelection

  test "constructors require nonempty file, directory, and name selections" do
    # These deliberately violate the constructors' inferred nonempty-list types.
    for {constructor, args} <- [
          {:files, [[]]},
          {:tests, [[], ["test alpha"]]},
          {:tests, [["test/a_test.exs"], []]},
          {:app, [[]]}
        ] do
      assert_raise FunctionClauseError, fn -> apply(TestSelection, constructor, args) end
    end
  end

  test "shape reads the variant, regardless of strings resembling Mix flags" do
    assert TestSelection.shape(:suite) == :suite
    assert TestSelection.shape(TestSelection.files(["--only"])) == :files
    assert TestSelection.shape(TestSelection.tests(["test/a.exs"], ["test alpha"])) == :tests
    assert TestSelection.shape(TestSelection.app(["apps/core/test"])) == :app
    assert TestSelection.shape(:no_coverage) == :no_coverage
  end

  test "constructors sort selections deterministically" do
    assert TestSelection.files(["b", "a"]) == {:files, ["a", "b"]}

    assert TestSelection.tests(["b", "a"], ["beta", "alpha"]) ==
             {:tests, ["a", "b"], ["alpha", "beta"]}

    assert TestSelection.app(["apps/web/test", "apps/core/test"]) ==
             {:app, ["apps/core/test", "apps/web/test"]}
  end

  describe "narrow_to_app/3" do
    @scopes %{core: ["apps/core/test", "apps/web/test"], empty: []}

    test "a suite run selects the owning app and its dependents" do
      assert TestSelection.narrow_to_app(:suite, "apps/core/lib/core.ex", @scopes) ==
               {:app, ["apps/core/test", "apps/web/test"]}
    end

    test "unknown owners and empty scopes retain the whole suite" do
      for file <- ["lib/core.ex", "apps/unknown/lib/core.ex", "apps/empty/lib/core.ex"] do
        assert TestSelection.narrow_to_app(:suite, file, @scopes) == :suite
      end

      assert TestSelection.narrow_to_app(:suite, "apps/core/lib/core.ex", %{}) == :suite
    end

    test "narrowing only affects suite runs, preserving coverage and no-coverage decisions" do
      for selection <- [
            TestSelection.files(["apps/web/test/web_test.exs"]),
            TestSelection.tests(["apps/web/test/web_test.exs"], ["test alpha"]),
            TestSelection.app(["apps/core/test"]),
            :no_coverage
          ] do
        assert TestSelection.narrow_to_app(selection, "apps/core/lib/core.ex", @scopes) ==
                 selection
      end
    end
  end
end
