defmodule Mutare.Mutator.Families do
  @moduledoc """
  A declarative family catalog for a family-rich mutator's configuration.

  A plugin that emits many mutation kinds under one mutator module usually exposes a
  `families:` option so users can narrow the catalog. This module generates that option's
  selection-and-validation machinery from one declaration, so every such plugin parses the
  same grammar — the one Mutare's own `{:builtins, except: […]}` uses — and fails loudly in
  the same shapes:

      defmodule MyPlugin.Config do
        use Mutare.Mutator.Families,
          plugin: "MyPlugin",
          all: ~w(comparison connective null_predicate string_literal)a,
          opt_in: ~w(string_literal)a
      end

  `use` options:

    * `:all` (required) — every family the mutator can emit, ordered; duplicates rejected.
    * `:opt_in` (default `[]`) — the subset excluded from the default set; each must be
      in `:all`.
    * `:plugin` (default the using module's name) — the name error messages blame,
      e.g. `"Mutare.Ecto"`.

  The declaration generates, all overridable:

    * `all_families/0` — the `:all` list;
    * `default_families/0` — `all -- opt_in`, the set used when `families:` is unset;
    * `parse_families!/1` — a configured `families:` value (`:default`, `:all`, an explicit
      list, or `{:all | :default, except: […]}`) to the enabled `MapSet`, raising
      `ArgumentError` on an unknown family or a malformed `except:`;
    * `family_enabled?/2` — whether a family is in a parsed set, or in the set a raw
      keyword list's `families:` value parses to;
    * `@type family` — the union of the declared family atoms.

  Only selection and validation are generated. What each family *means* — notes, variant
  labels, delivery — stays the plugin's, typically alongside this `use` in its config module.
  Parse once per run by calling `parse_families!/1` from the mutator's
  `c:Mutare.Mutator.init/1` and reading the result back from `context.config`; then *apply*
  the selection once, in `c:Mutare.Mutator.finalize/2` — Mutare runs it on every produced
  mutation, on both delivery paths, so producers stay pure and no delivery site can forget
  the filter.
  """

  @typedoc """
  The catalog a `use Mutare.Mutator.Families` declaration compiles to — the value the
  generated functions close over and the runtime faces (`parse!/2`, `enabled?/3`) take.
  """
  @type catalog :: %{plugin: String.t(), all: [atom()], default: [atom()]}

  defmacro __using__(opts) do
    opts = Macro.expand_literals(opts, __CALLER__)
    plugin = Keyword.get(opts, :plugin, inspect(__CALLER__.module))
    all = Keyword.get(opts, :all)
    opt_in = Keyword.get(opts, :opt_in, [])
    validate_declaration!(__CALLER__.module, plugin, all, opt_in, Keyword.keys(opts))

    catalog = %{plugin: plugin, all: all, default: all -- opt_in}
    family_union = Enum.reduce(tl(all), hd(all), &{:|, [], [&2, &1]})

    quote do
      @mutare_families_catalog unquote(Macro.escape(catalog))

      @typedoc "A mutation family this mutator can emit (the `families:` vocabulary)."
      @type family :: unquote(family_union)

      @doc "Every family this mutator can emit (the `families: :all` set), ordered."
      @spec all_families() :: [family()]
      def all_families, do: @mutare_families_catalog.all

      @doc """
      The families enabled when `families:` is unset or `:default` — every family except
      the declared opt-in ones.
      """
      @spec default_families() :: [family()]
      def default_families, do: @mutare_families_catalog.default

      @doc """
      Parses a configured `families:` value — `:default`, `:all`, an explicit family list,
      or `{:all | :default, except: [families]}` — into the enabled family `MapSet`.
      Raises `ArgumentError` on an unknown family name or a malformed `except:`.
      """
      @spec parse_families!(term()) :: MapSet.t(family())
      def parse_families!(value),
        do: Mutare.Mutator.Families.parse!(value, @mutare_families_catalog)

      @doc """
      Whether `family` is enabled — by an already-parsed `MapSet`, or by a raw keyword
      option list whose `families:` value is parsed first (defaulting to `:default`).
      """
      @spec family_enabled?(MapSet.t(family()) | keyword(), family()) :: boolean()
      def family_enabled?(enabled, family),
        do: Mutare.Mutator.Families.enabled?(enabled, family, @mutare_families_catalog)

      defoverridable all_families: 0,
                     default_families: 0,
                     parse_families!: 1,
                     family_enabled?: 2
    end
  end

  # Reject a malformed declaration at compile time — the plugin author's error, so it must
  # fail at their `use` line, not at a user's `families:` parse.
  defp validate_declaration!(module, plugin, all, opt_in, keys) do
    check!(module, keys -- [:plugin, :all, :opt_in] == [], fn ->
      "unknown options #{inspect(keys -- [:plugin, :all, :opt_in])} — " <>
        "the options are :plugin, :all, and :opt_in"
    end)

    check!(module, is_binary(plugin), fn ->
      ":plugin must be a string, got: #{inspect(plugin)}"
    end)

    check!(module, is_list(all) and all != [] and Enum.all?(all, &is_atom/1), fn ->
      ":all must be a non-empty list of family atoms, got: #{inspect(all)}"
    end)

    check!(module, Enum.uniq(all) == all, fn ->
      ":all contains duplicate families: #{inspect(all -- Enum.uniq(all))}"
    end)

    check!(module, is_list(opt_in) and opt_in -- all == [], fn ->
      ":opt_in must be a sublist of :all, got families not in :all: " <>
        inspect(if(is_list(opt_in), do: opt_in -- all, else: opt_in))
    end)
  end

  defp check!(_module, true, _message), do: :ok

  defp check!(module, false, message) do
    raise ArgumentError,
          "invalid `use Mutare.Mutator.Families` in #{inspect(module)}: #{message.()}"
  end

  @doc """
  Parses a `families:` value against `catalog` — the runtime behind the generated
  `parse_families!/1`, kept here so the grammar and its error messages are owned once.
  """
  @spec parse!(term(), catalog()) :: MapSet.t(atom())
  def parse!(:all, catalog), do: MapSet.new(catalog.all)
  def parse!(:default, catalog), do: MapSet.new(catalog.default)

  # `{:all | :default, except: [families]}` — the named base set minus a validated `:except`
  # list, the same grammar as core's `{:builtins, except: […]}`.
  def parse!({:all, opts}, catalog), do: catalog.all |> except!(opts, catalog) |> MapSet.new()

  def parse!({:default, opts}, catalog),
    do: catalog.default |> except!(opts, catalog) |> MapSet.new()

  def parse!(families, catalog) when is_list(families) do
    validate_families!(families, catalog, "families")
    MapSet.new(families)
  end

  def parse!(other, catalog) do
    raise ArgumentError,
          "#{catalog.plugin} :families must be :all, :default, a list, or " <>
            "{:all | :default, except: [...]}, got: #{inspect(other)}"
  end

  @doc """
  Whether `family` is enabled — the runtime behind the generated `family_enabled?/2`.
  A `MapSet` is an already-parsed selection; a keyword list is raw options, whose
  `families:` value (default `:default`) is parsed first.
  """
  @spec enabled?(MapSet.t(atom()) | keyword(), atom(), catalog()) :: boolean()
  def enabled?(%MapSet{} = enabled, family, _catalog), do: MapSet.member?(enabled, family)

  def enabled?(opts, family, catalog) when is_list(opts),
    do: opts |> Keyword.get(:families, :default) |> parse!(catalog) |> MapSet.member?(family)

  # The base family list minus a validated `:except` list. The only accepted key is `:except`,
  # and each named family must be real, so a typo (`{:default, exept: …}` /
  # `except: [:integr_literal]`) fails loudly rather than silently keeping a family it meant
  # to drop.
  defp except!(base, opts, catalog) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{catalog.plugin} families {:all | :default, ...} options must be a keyword " <>
              "list with an :except family list, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- [:except] do
      [] ->
        :ok

      bad ->
        raise ArgumentError,
              "unknown #{catalog.plugin} families option: #{inspect(bad)} — the only option " <>
                "is :except"
    end

    except = opts |> Keyword.get(:except, []) |> List.wrap()
    validate_families!(except, catalog, "families in :except")
    base -- except
  end

  defp validate_families!(families, catalog, what) do
    case families -- catalog.all do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown #{catalog.plugin} #{what}: #{inspect(unknown)} — valid families are " <>
                inspect(catalog.all)
    end
  end
end
