defmodule Mutare.Transform.KeywordRouting do
  @moduledoc """
  Interprets a normalized keyword route against one concrete argument, without walking it.

  A literal keyword list becomes ordered pairs of `{node, treatment}` entries plus a
  shape-preserving rebuilder. A non-keyword argument gets its whole-argument fallback:
  the leading treatment for a keyed refinement, or `:raw` for positional keyword routing.
  Positional routing requires exactly one treatment per pair; it never silently truncates.

  Keyed refinements choose each value's final treatment before any descent. Unnamed values
  and data keys inherit the leading treatment, except that `:interior` becomes `:expression`
  below the container. Block keys are always raw. Positional keyword routes leave all keys
  raw and assign treatments to values by order, including duplicate keys.

  Resolve, body analysis, guard tagging, self-call rewriting and binding analysis share
  this interpretation, not a traversal. Each pass still decides what a treatment means for
  its task; the container's own offer and nested syntax scopes also remain with that pass.
  In particular, withholding mutation does not establish whether an expression executes.
  """

  alias Mutare.AST
  alias Mutare.Transform.Analyze.{CallOptions, Syntax}

  # Resolve may already have attached hosts, including to a keyed leading treatment.
  @type treatment :: atom() | {:hosted, [module()]}
  @type position :: treatment() | routing()
  @type routing :: {:keyed, treatment(), [{atom(), position()}]} | {:keyword, [position()]}
  @type routed_node :: {Macro.t(), position()}
  @type rewrap :: ([{Macro.t(), Macro.t()}] -> Macro.t())
  @type decoded ::
          {:pairs, [{routed_node(), routed_node()}], rewrap()} | {:whole, position()}

  @spec decode(Macro.t(), routing()) :: decoded()
  def decode(arg, {:keyed, leading, refinements}) do
    case CallOptions.keyword_pairs(arg) do
      {:ok, pairs, rewrap} ->
        inner = descendant(leading)

        routed =
          Enum.map(pairs, fn {key, value} ->
            key_treatment = if Syntax.block_key?(key), do: :raw, else: inner
            value_treatment = Keyword.get(refinements, AST.key_atom(key), inner)
            {{key, key_treatment}, {value, value_treatment}}
          end)

        {:pairs, routed, rewrap}

      :error ->
        {:whole, leading}
    end
  end

  def decode(arg, {:keyword, treatments}) do
    case CallOptions.keyword_pairs(arg) do
      {:ok, pairs, rewrap} ->
        CallOptions.validate_keyword_treatments!(pairs, treatments)

        routed =
          Enum.zip_with(pairs, treatments, fn {key, value}, treatment ->
            {{key, :raw}, {value, treatment}}
          end)

        {:pairs, routed, rewrap}

      :error ->
        {:whole, :raw}
    end
  end

  defp descendant(:interior), do: :expression
  defp descendant(treatment), do: treatment
end
