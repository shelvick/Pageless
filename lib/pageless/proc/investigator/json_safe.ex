defmodule Pageless.Proc.Investigator.JsonSafe do
  @moduledoc "Converts investigator payload values into JSON-safe terms."

  @doc "Recursively converts atoms, tuples, maps, and lists into JSON-serializable values."
  @spec convert(term()) :: term()
  def convert(value) when is_atom(value), do: Atom.to_string(value)

  def convert(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&convert/1)

  def convert(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {json_key(key), convert(val)} end)

  def convert(value) when is_list(value), do: Enum.map(value, &convert/1)
  def convert(value), do: value

  @spec json_key(term()) :: term()
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key
end
