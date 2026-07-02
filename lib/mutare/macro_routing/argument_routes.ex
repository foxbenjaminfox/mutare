defmodule Mutare.MacroRouting.ArgumentRoutes do
  @moduledoc """
  The resolved argument treatments returned by
  `c:Mutare.MacroRouting.route_arguments/2`.

  `visible` aligns exactly with `Mutare.MacroRouting.Call.arguments`. `piped` is `nil` for an
  unpiped call and carries the treatment of the pipe's left side for a piped call. Constructors
  validate this shape immediately; Mutare validates callback results again at the boundary.
  """

  alias Mutare.MacroRouting.Call

  @opaque t :: %__MODULE__{
            visible: [Mutare.MacroRouting.treatment()],
            piped: Mutare.MacroRouting.treatment() | nil
          }

  @enforce_keys [:visible, :piped]
  defstruct [:visible, :piped]

  @doc """
  Build routes in effective-argument order, matching static route declarations.

  For an unpiped call, `routes` must have one entry per visible argument. For a piped call, its
  first entry routes the pipe's left side and the remainder route the visible arguments.
  """
  @spec from_effective(Call.t(), [Mutare.MacroRouting.treatment()]) :: t()
  def from_effective(%Call{} = call, routes) when is_list(routes) do
    expected = call.effective_arity
    validate_length!(routes, expected, :effective)
    Enum.each(routes, &validate_treatment!/1)

    case call.pipe_mode do
      :unpiped -> %__MODULE__{visible: routes, piped: nil}
      :piped -> %__MODULE__{visible: tl(routes), piped: hd(routes)}
    end
  end

  @doc """
  Build routes from the visible arguments.

  A piped call defaults its hidden first argument to `:expression`; pass `piped: treatment` when
  the macro gives that position different semantics.
  """
  @spec from_visible(Call.t(), [Mutare.MacroRouting.treatment()], keyword()) :: t()
  def from_visible(%Call{} = call, routes, opts \\ []) when is_list(routes) do
    validate_length!(routes, length(call.arguments), :visible)
    Enum.each(routes, &validate_treatment!/1)

    piped =
      case call.pipe_mode do
        :unpiped -> nil
        :piped -> Keyword.get(opts, :piped, :expression)
      end

    if piped, do: validate_treatment!(piped)

    %__MODULE__{visible: routes, piped: piped}
  end

  @doc "The treatments aligned with the written call's visible arguments."
  @spec visible(t()) :: [Mutare.MacroRouting.treatment()]
  def visible(%__MODULE__{visible: visible}), do: visible

  @doc "The pipe-left treatment, or `nil` when the call is not piped."
  @spec piped(t()) :: Mutare.MacroRouting.treatment() | nil
  def piped(%__MODULE__{piped: piped}), do: piped

  @doc false
  @spec validate(term(), Call.t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{visible: visible, piped: piped}, %Call{} = call)
      when is_list(visible) do
    cond do
      length(visible) != length(call.arguments) ->
        {:error, "must contain one visible treatment per call argument"}

      call.pipe_mode == :unpiped and not is_nil(piped) ->
        {:error, "must have piped: nil for an unpiped call"}

      call.pipe_mode == :piped and is_nil(piped) ->
        {:error, "must contain a piped treatment for a piped call"}

      not Enum.all?(visible, &valid_treatment?/1) ->
        {:error, "contains an unrecognised treatment in its visible arguments"}

      not is_nil(piped) and not valid_treatment?(piped) ->
        {:error, "contains an unrecognised treatment for the piped argument"}

      true ->
        :ok
    end
  end

  def validate(%__MODULE__{}, _call), do: {:error, "contains a non-list visible field"}

  def validate(_other, _call),
    do: {:error, "must return a Mutare.MacroRouting.ArgumentRoutes value"}

  defp validate_length!(routes, expected, space) do
    if length(routes) != expected do
      raise ArgumentError,
            "expected #{expected} #{space}-argument treatments, got #{length(routes)}: " <>
              inspect(routes)
    end
  end

  defp validate_treatment!(treatment)
       when treatment in [
              :expression,
              :pattern,
              :binding_pattern,
              :skip,
              :hosted,
              :scalar_interpolation
            ],
       do: :ok

  defp validate_treatment!({:keyword, treatments}) when is_list(treatments) do
    Enum.each(treatments, &validate_treatment!/1)
  end

  defp validate_treatment!(other) do
    raise ArgumentError, "invalid macro argument treatment: #{inspect(other)}"
  end

  defp valid_treatment?(treatment)
       when treatment in [
              :expression,
              :pattern,
              :binding_pattern,
              :skip,
              :hosted,
              :scalar_interpolation
            ],
       do: true

  defp valid_treatment?({:keyword, treatments}) when is_list(treatments),
    do: Enum.all?(treatments, &valid_treatment?/1)

  defp valid_treatment?(_other), do: false
end
