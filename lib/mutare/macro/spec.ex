defmodule Mutare.Macro.Spec do
  @moduledoc """
  A resolved **known-macro** entry: a macro the transform should route the
  arguments of by a declared treatment, instead of the default all-runtime
  descent.

  Mutare classifies each position's context *positionally* — `:runtime` (mutate
  in place), `:pattern` (descend but don't mutate), and so on. Ordinary calls are
  routed by the lexical resolution pre-pass, but a *macro* whose argument is a
  pattern or an opaque DSL body looks like an ordinary call, so its args would be
  mutated as runtime values (a literal in `match?`'s pattern arg is a pattern, not
  a value — splicing a selector there is illegal and poisons the single build). A
  `Spec` teaches the transform how to treat each argument.

  ## Identity

  `module` is the resolved module **key** the way the rest of the transform keys
  modules (`Mutare.Transform.Calls.module_key`): an Elixir-module path as an atom
  list *without* the `Elixir.` prefix (`[:Kernel]`, `[:Ecto, :Query]`), or an
  Erlang-module atom (`:binary`). A user writes the module the natural way
  (`Kernel`, `Ecto.Query`, `:binary`); `normalize_module/1` converts it to the key.
  `arity` is a non-negative integer or `:any` (matches a call of any arity).

  ## Argument treatments

  `args` is either a single treatment atom (applied uniformly to every argument)
  or a per-position list (padded with `:expression`). The treatments and how the
  analyzer routes each:

    * `:expression` (default) — analyze as `:runtime` (mutate normally).
    * `:pattern` — analyze as `:pattern` (descend so nested runtime escapes are
      still reached, but never mutate the pattern itself). `match?`. The bindings the
      pattern makes are **local** to the macro's expansion (a `case`/`fn`), so they do
      not escape and the structural families have no observable swap to offer here.
    * `:binding_pattern` — a `:pattern` whose bindings **escape into the enclosing
      scope** (`destructure([x, y], v)` binds `x`/`y` for the rest of the block). Routed
      exactly like `:pattern` for the in-place descent, but **additionally** offered to the
      structural pattern families (swap/wildcard) when the macro call sits in a
      *value-discarded* position — a non-final block statement or a `with` clause — where
      the mutant is delivered by re-exporting the escaping bindings through a tuple
      (`Mutare.Transform.emit_macro_pattern_site/3`), the `=`-match analogue. The
      registrant vouches that the macro binds every variable named in the pattern and
      accepts pattern-legal swap/wildcard rewrites (`destructure` does).
    * `:skip` — leave the argument **raw**: no descent, no mutation. The opaque
      DSL case (`Ecto.Query.from`'s body), and the mechanism behind "handled only
      by a custom mutator" — core skips the args, while the whole macro node is
      still offered to every mutator, so a registering library's mutator fires.

  `routing/2` expands `args` to a per-position list for a concrete arity.
  """

  @typedoc "A resolved module key: an Elixir-module atom path or an Erlang-module atom."
  @type module_key :: [atom()] | atom()

  @typedoc "How one argument is routed."
  @type treatment :: :expression | :pattern | :binding_pattern | :skip

  @type t :: %__MODULE__{
          module: module_key(),
          name: atom(),
          arity: non_neg_integer() | :any,
          args: treatment() | [treatment()]
        }

  @enforce_keys [:module, :name, :arity, :args]
  defstruct [:module, :name, :arity, :args]

  @treatments [:expression, :pattern, :binding_pattern, :skip]

  @doc "The valid argument treatments — the single source of truth for validation."
  @spec treatments() :: [treatment()]
  def treatments, do: @treatments

  @doc """
  Build a validated spec from a user-written `{module, name, arity, args}`.

  Normalizes `module` to its key and validates `name`/`arity`/`args`, raising
  `ArgumentError` on a malformed entry. Purely syntactic — never reflects on the
  module — so a spec for a module that is not a dependency of the Mutare process
  (e.g. `Ecto.Query`) resolves without `Ecto` loaded.
  """
  @spec new(term(), term(), term(), term()) :: t()
  def new(module, name, arity, args) do
    %__MODULE__{
      module: normalize_module(module),
      name: validate_name(name),
      arity: validate_arity(arity),
      args: validate_args(args)
    }
  end

  @doc """
  The lookup key `{module_key, name, arity}` — what `Mutare.Macros` keys its
  registry map on.
  """
  @spec key(t()) :: {module_key(), atom(), non_neg_integer() | :any}
  def key(%__MODULE__{module: module, name: name, arity: arity}), do: {module, name, arity}

  @doc """
  The per-position treatment list for a call of `count` visible arguments. A
  uniform-atom `args` repeats; a list `args` is padded with `:expression` (and
  truncated to `count`).
  """
  @spec routing(t(), non_neg_integer()) :: [treatment()]
  def routing(%__MODULE__{args: args}, count), do: expand_args(args, count)

  defp expand_args(treatment, count) when is_atom(treatment), do: List.duplicate(treatment, count)

  defp expand_args(list, count) when is_list(list),
    do: Enum.map(0..(count - 1)//1, &Enum.at(list, &1, :expression))

  @doc """
  Normalize a user-written module reference to a key.

    * an Elixir-module alias atom (`Ecto.Query`, `Kernel`) → its `Module.split/1`
      path as atoms (`[:Ecto, :Query]`, `[:Kernel]`);
    * an Erlang-module atom (`:binary`) → itself;
    * an already-normalized atom list (`[:Ecto, :Query]`) → itself.
  """
  @spec normalize_module(term()) :: module_key()
  def normalize_module(module) when is_atom(module) do
    case Macro.classify_atom(module) do
      :alias -> module |> Module.split() |> Enum.map(&String.to_atom/1)
      _ -> module
    end
  end

  def normalize_module(list) when is_list(list) and list != [] do
    if Enum.all?(list, &is_atom/1) do
      list
    else
      raise ArgumentError, "macro module path must be a list of atoms, got: #{inspect(list)}"
    end
  end

  def normalize_module(other) do
    raise ArgumentError,
          "macro module must be a module (Kernel, Ecto.Query), an Erlang atom " <>
            "(:binary), or an atom path ([:Ecto, :Query]), got: #{inspect(other)}"
  end

  defp validate_name(name) when is_atom(name), do: name

  defp validate_name(other),
    do: raise(ArgumentError, "macro name must be an atom, got: #{inspect(other)}")

  defp validate_arity(:any), do: :any
  defp validate_arity(arity) when is_integer(arity) and arity >= 0, do: arity

  defp validate_arity(other) do
    raise ArgumentError,
          "macro arity must be a non-negative integer or :any, got: #{inspect(other)}"
  end

  defp validate_args(treatment) when treatment in @treatments, do: treatment

  defp validate_args(list) when is_list(list) do
    Enum.each(list, fn
      t when t in @treatments -> :ok
      other -> raise ArgumentError, bad_treatment_message(other)
    end)

    list
  end

  defp validate_args(other), do: raise(ArgumentError, bad_treatment_message(other))

  defp bad_treatment_message(other) do
    "macro arg treatment must be one of #{inspect(@treatments)} " <>
      "(or a list of them), got: #{inspect(other)}"
  end
end
