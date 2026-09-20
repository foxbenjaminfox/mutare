defmodule Mutare.Test.BindPipe do
  @moduledoc false
  # A custom `|>` *macro*, for a module that displaced `Kernel`'s: it pipes the value inside
  # `{:ok, value}` into the stage and passes anything else along untouched. Applied to an
  # already-unwrapped value it skips the stage — which is what makes a closure that applies the
  # operator twice observable.

  defmacro left |> right do
    piped = Macro.pipe(quote(do: value), right, 0)

    quote do
      case unquote(left) do
        {:ok, value} -> unquote(piped)
        other -> other
      end
    end
  end
end

defmodule Mutare.Test.PairPipe do
  @moduledoc false
  # A custom `|>` *function*: both operands are ordinary values, and nothing is piped anywhere.

  def left |> right, do: {left, right}
end

defmodule Mutare.Test.UsesBindPipe do
  @moduledoc false
  # Displaces `Kernel.|>/2` from inside a `use`, the way a library would.

  defmacro __using__(_opts) do
    quote do
      import Kernel, except: [|>: 2]
      import Mutare.Test.BindPipe
    end
  end
end
