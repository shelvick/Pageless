defmodule Pageless.Governance.VerbTableClassifier do
  @moduledoc """
  Classifies kubectl invocations using a caller-provided verb table.
  """

  @type verb_table :: %{
          read: [String.t()],
          write_dev: [String.t()],
          write_prod_low: [String.t()],
          write_prod_high: [String.t()]
        }

  @type classification :: :read | :write_dev | :write_prod_low | :write_prod_high

  @type classify_error :: :empty_args | :malformed_args

  @classes [:read, :write_dev, :write_prod_low, :write_prod_high]
  @flags_with_values ~w(-n --namespace --context --cluster --user --kubeconfig --as --as-group --request-timeout)

  @doc """
  Extracts the kubectl verb, looks it up in `verb_table`, and returns its class.
  """
  @spec classify([String.t()], verb_table()) ::
          {:ok, classification(), String.t()} | {:error, classify_error()}
  def classify(args, verb_table) when is_list(args) do
    with {:ok, verb} <- extract_verb(args) do
      classified_verb = infer_scale_direction(verb, args)
      {:ok, lookup(classified_verb, verb_table), classified_verb}
    end
  end

  @doc """
  Extracts the single-word or compound kubectl verb from an args list.
  """
  @spec extract_verb([String.t()]) :: {:ok, String.t()} | {:error, classify_error()}
  def extract_verb(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      args
      |> strip_leading_flags()
      |> verb_from_remaining_args()
    else
      {:error, :malformed_args}
    end
  end

  defp strip_leading_flags([]), do: []

  defp strip_leading_flags([flag, _value | rest]) when flag in @flags_with_values do
    strip_leading_flags(rest)
  end

  defp strip_leading_flags(["--" <> _flag | rest]) do
    strip_leading_flags(rest)
  end

  defp strip_leading_flags(["-" <> _flag | rest]) do
    strip_leading_flags(rest)
  end

  defp strip_leading_flags(args), do: args

  defp verb_from_remaining_args([]), do: {:error, :empty_args}

  defp verb_from_remaining_args(["rollout" | rest]) do
    case strip_leading_flags(rest) do
      [subcommand | _] -> {:ok, "rollout #{subcommand}"}
      [] -> {:ok, "rollout"}
    end
  end

  defp verb_from_remaining_args([verb | _]), do: {:ok, verb}

  defp infer_scale_direction("scale", args) do
    case replica_value(args) do
      "+" <> _ -> "scale-up"
      "-" <> _ -> "scale-down"
      _ -> "scale"
    end
  end

  defp infer_scale_direction(verb, _args), do: verb

  defp replica_value([]), do: nil
  defp replica_value(["--replicas=" <> value | _rest]), do: value
  defp replica_value(["--replicas", value | _rest]), do: value
  defp replica_value([_arg | rest]), do: replica_value(rest)

  defp lookup(verb, verb_table) do
    Enum.find(@classes, :write_prod_high, fn class ->
      verb in Map.get(verb_table, class, [])
    end)
  end
end
