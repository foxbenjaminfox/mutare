defmodule Mutare.Test.PatternConditional do
  @moduledoc """
  Custom `if`/`unless` macros whose first argument is a pattern, not a condition.
  """

  for form <- [:if, :unless] do
    defmacro unquote(form)(pattern, do: body) do
      quote do
        case {:ok, 42} do
          unquote(pattern) -> unquote(body)
        end
      end
    end
  end
end

defmodule Mutare.Test.PatternBodyConditional do
  @moduledoc """
  Custom `if`/`unless` macros whose `do:` argument is a pattern, not a return path.
  """

  for form <- [:if, :unless] do
    defmacro unquote(form)(value, do: pattern) do
      quote do
        case unquote(value) do
          unquote(pattern) -> :matched
          _ -> :missed
        end
      end
    end
  end
end

defmodule Mutare.Test.LazyConditional do
  @moduledoc """
  Custom `if`/`unless` macros that discard their first argument, including its bindings.
  """

  for form <- [:if, :unless] do
    defmacro unquote(form)(_unused, do: body), do: body
  end
end
