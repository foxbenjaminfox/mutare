defmodule Mutare.Test.CustomKernel do
  @moduledoc false
  # Kernel-shaped DSL calls: a pattern stays syntax even though its head looks familiar.
  for op <- [:!, :not, :abs] do
    defmacro unquote(op)(pattern) do
      quote do
        case {:ok, 42} do
          unquote(pattern) -> true
          _ -> false
        end
      end
    end
  end

  for op <- [:and, :or, :&&, :||, :+, :==, :===, :++, :div, :min] do
    defmacro unquote(op)(value, pattern) do
      quote do
        case unquote(value) do
          unquote(pattern) -> true
          _ -> false
        end
      end
    end
  end

  # A guard macro with a tuple of DSL syntax on its right.
  defmacro value in {:limit, limit}, do: quote(do: unquote(value) == unquote(limit))

  for form <- [:defmodule, :defimpl, :defprotocol] do
    defmacro unquote(form)(_name, do: pattern) do
      quote do
        case {:ok, 42} do
          unquote(pattern) -> true
        end
      end
    end
  end

  for form <- [:def, :defp] do
    defmacro unquote(form)({_name, _, [1]}, do: _body), do: nil
  end

  for sigil <- [:sigil_r, :sigil_s, :sigil_S, :sigil_c, :sigil_C, :sigil_w, :sigil_W] do
    defmacro unquote(sigil)({:<<>>, _, ["valid"]}, []), do: :valid
  end

  for {sigil, payload} <- [
        sigil_D: "2020-01-01",
        sigil_T: "12:00:00",
        sigil_N: "2020-01-01 12:00:00",
        sigil_U: "2020-01-01 12:00:00Z"
      ] do
    defmacro unquote(sigil)({:<<>>, _, [unquote(payload)]}, []), do: :valid
  end
end

defmodule Mutare.Test.CustomNegationMutator do
  @moduledoc false
  @behaviour Mutare.Mutator
  def name, do: :custom_negation
  def mutate({:!, _, [_]}), do: [Mutare.AST.literal(:changed)]
  def mutate(_), do: :skip
end

defmodule Mutare.Test.IntegerSigil do
  @moduledoc false
  defmacro sigil_s({:<<>>, _, ["valid"]}, []), do: 65
end
