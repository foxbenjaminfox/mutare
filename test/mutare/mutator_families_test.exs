defmodule Mutare.Mutator.FamiliesTest do
  @moduledoc """
  Coverage of the `use Mutare.Mutator.Families` catalog: the generated selection API,
  the `families:` grammar (`:default` / `:all` / list / `{base, except: […]}`), the
  fail-loud validation messages, overridability, and the compile-time declaration checks.
  """
  use ExUnit.Case, async: true

  defmodule Catalog do
    use Mutare.Mutator.Families,
      plugin: "MyPlugin",
      all: [:comparison, :connective, :string_literal, :atom_literal],
      opt_in: [:string_literal, :atom_literal]
  end

  # No :plugin (error messages blame the module) and no :opt_in (default is all).
  defmodule Bare do
    use Mutare.Mutator.Families, all: [:only]
  end

  defmodule Overridden do
    use Mutare.Mutator.Families, all: [:a, :b]

    def default_families, do: [:b]
  end

  describe "the generated catalog" do
    test "all_families/0 is the declared list, ordered" do
      assert Catalog.all_families() == [:comparison, :connective, :string_literal, :atom_literal]
    end

    test "default_families/0 is all minus opt_in" do
      assert Catalog.default_families() == [:comparison, :connective]
    end

    test "without :opt_in the default set is the whole catalog" do
      assert Bare.default_families() == Bare.all_families()
    end

    test "every generated function is overridable" do
      assert Overridden.default_families() == [:b]
      assert Overridden.all_families() == [:a, :b]
    end
  end

  describe "parse_families!/1" do
    test ":default and unset-equivalent" do
      assert Catalog.parse_families!(:default) == MapSet.new([:comparison, :connective])
    end

    test ":all re-adds the opt-in families" do
      assert Catalog.parse_families!(:all) ==
               MapSet.new([:comparison, :connective, :string_literal, :atom_literal])
    end

    test "an explicit list" do
      assert Catalog.parse_families!([:connective, :atom_literal]) ==
               MapSet.new([:connective, :atom_literal])
    end

    test "{:default, except: […]} drops from the default set" do
      assert Catalog.parse_families!({:default, except: [:comparison]}) ==
               MapSet.new([:connective])
    end

    test "{:all, except: […]} drops from the full set" do
      assert Catalog.parse_families!({:all, except: [:string_literal, :comparison]}) ==
               MapSet.new([:connective, :atom_literal])
    end

    test "an unknown family in a list fails loudly with the valid set" do
      message = ~r/unknown MyPlugin families: \[:nope\] — valid families are/

      assert_raise ArgumentError, message, fn ->
        Catalog.parse_families!([:connective, :nope])
      end
    end

    test "an unknown family in :except fails loudly" do
      assert_raise ArgumentError, ~r/unknown MyPlugin families in :except: \[:nope\]/, fn ->
        Catalog.parse_families!({:default, except: [:nope]})
      end
    end

    test "a misspelled :except key fails loudly" do
      assert_raise ArgumentError, ~r/the only option is :except/, fn ->
        Catalog.parse_families!({:default, exept: [:comparison]})
      end
    end

    test "a non-keyword except spec fails loudly" do
      assert_raise ArgumentError, ~r/must be a keyword list with an :except family list/, fn ->
        Catalog.parse_families!({:default, [:comparison]})
      end
    end

    test "an unrecognized value names the accepted grammar" do
      message = ~r/MyPlugin :families must be :all, :default, a list, or/

      assert_raise ArgumentError, message, fn -> Catalog.parse_families!(:sometimes) end
    end

    test "without :plugin, errors blame the using module" do
      module = inspect(Bare)

      assert_raise ArgumentError, ~r/unknown #{module} families: \[:nope\]/, fn ->
        Bare.parse_families!([:nope])
      end
    end
  end

  describe "family_enabled?/2" do
    test "against a parsed MapSet" do
      enabled = Catalog.parse_families!([:connective])
      assert Catalog.family_enabled?(enabled, :connective)
      refute Catalog.family_enabled?(enabled, :comparison)
    end

    test "against raw options, families: unset means :default" do
      assert Catalog.family_enabled?([], :comparison)
      refute Catalog.family_enabled?([], :string_literal)
    end

    test "against raw options with an explicit families: value" do
      opts = [families: {:all, except: [:comparison]}]
      refute Catalog.family_enabled?(opts, :comparison)
      assert Catalog.family_enabled?(opts, :string_literal)
    end
  end

  describe "declaration validation" do
    test "a missing/empty :all is rejected at compile time" do
      assert_raise ArgumentError, ~r/:all must be a non-empty list of family atoms/, fn ->
        defmodule NoAll do
          use Mutare.Mutator.Families, plugin: "X"
        end
      end
    end

    test "a duplicate family in :all is rejected" do
      assert_raise ArgumentError, ~r/:all contains duplicate families: \[:a\]/, fn ->
        defmodule Duplicated do
          use Mutare.Mutator.Families, all: [:a, :b, :a]
        end
      end
    end

    test "an :opt_in family outside :all is rejected" do
      assert_raise ArgumentError, ~r/:opt_in must be a sublist of :all/, fn ->
        defmodule StrayOptIn do
          use Mutare.Mutator.Families, all: [:a], opt_in: [:b]
        end
      end
    end

    test "an unknown declaration option is rejected" do
      assert_raise ArgumentError, ~r/unknown options \[:defaults\]/, fn ->
        defmodule UnknownKey do
          use Mutare.Mutator.Families, all: [:a], defaults: [:a]
        end
      end
    end

    test "a non-string :plugin is rejected" do
      assert_raise ArgumentError, ~r/:plugin must be a string/, fn ->
        defmodule AtomPlugin do
          use Mutare.Mutator.Families, plugin: MyPlugin, all: [:a]
        end
      end
    end
  end
end
