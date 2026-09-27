defmodule Mutare.Transform.Diagnostics do
  @moduledoc false

  # One advisory sink for a transform invocation, including adapter re-entry.
  # Dynamic process scope avoids threading printing policy through every semantic helper.
  # Workers are isolated; nested invocations restore their caller's policy even on failure.
  # This is printing wiring only: scan facts still travel through CountReport, never a reparse.
  require Logger

  @key {__MODULE__, :warnings}

  @spec with_warnings(boolean(), (-> result)) :: result when result: var
  def with_warnings(enabled?, fun) do
    previous = Process.get(@key, true)
    Process.put(@key, previous and enabled?)

    try do
      fun.()
    after
      Process.put(@key, previous)
    end
  end

  # Hosts may collect islands in Tasks. Their retained resolution context carries the
  # originating pass's policy across that process boundary, just like its match collector.
  @spec with_context(map(), (-> result)) :: result when result: var
  def with_context(%{resolution: %{diag: %{warn?: enabled?}}}, fun),
    do: with_warnings(enabled?, fun)

  def with_context(_context, fun), do: fun.()

  @spec warn((-> String.t()), :io | :log) :: :ok
  def warn(message, channel \\ :io) do
    if Process.get(@key, true) do
      case channel do
        :io -> IO.warn(message.(), [])
        :log -> Logger.warning(message.())
      end
    end

    :ok
  end
end
