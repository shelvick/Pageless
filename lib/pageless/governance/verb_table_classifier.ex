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

  @type classify_error ::
          :empty_args
          | :malformed_args
          | {:forbidden_flag, String.t()}
          | {:forbidden_verb, String.t()}
          | {:forbidden_namespace, String.t()}
          | {:forbidden_resource, String.t()}
          | {:forbidden_replicas, String.t()}

  @classes [:read, :write_dev, :write_prod_low, :write_prod_high]
  @namespace_flags ~w(-n --namespace)
  @safe_skip_flags ~w(-v --v --verbose --quiet)
  @safe_skip_flags_with_values ~w(-v --v)
  @resource_flags_with_values ~w(-n --namespace --container -c --selector -l --field-selector --since --since-time --tail --limit -o --output)
  @forbidden_flag_stems ~w(--raw --token --as --as-group --kubeconfig --server --insecure-skip-tls-verify --certificate-authority --client-key --client-certificate --token-file --proxy-url --context --cluster --user --request-timeout -A --all-namespaces)
  @forbidden_resource_types ~w(secrets secret serviceaccounts serviceaccount sa tokens token bootstraptokens)
  # Shell/pivot primitives that can land arbitrary code execution inside the
  # cluster. Rejected structurally regardless of the caller-provided verb
  # table — the (intentionally) unauthenticated approve modal means we cannot
  # rely on "gated" to keep these safe.
  @forbidden_verbs ~w(exec cp port-forward debug attach)
  @allowed_read_namespaces ~w(prod monitoring default)
  @replicas_max_delta 10
  @replicas_max_absolute 20

  @doc """
  Extracts the kubectl verb, looks it up in `verb_table`, and returns its class.
  """
  @spec classify([String.t()], verb_table()) ::
          {:ok, classification(), String.t()} | {:error, classify_error()}
  def classify(args, verb_table) when is_list(args) do
    with :ok <- validate_args(args),
         :ok <- reject_forbidden_flags(args),
         {:ok, namespaces} <- extract_namespaces(args),
         {:ok, verb} <- extract_verb(args),
         :ok <- reject_forbidden_verb(verb),
         :ok <- reject_forbidden_resource(args, verb),
         {:ok, classified_verb} <- classify_scale_verb(args, verb) do
      class = lookup(classified_verb, verb_table)

      with :ok <- authorize_read_namespace(class, namespaces) do
        {:ok, class, classified_verb}
      end
    end
  end

  defp reject_forbidden_verb(verb) when is_binary(verb) do
    if String.downcase(verb) in @forbidden_verbs do
      {:error, {:forbidden_verb, verb}}
    else
      :ok
    end
  end

  @doc """
  Extracts the single-word or compound kubectl verb from an args list.
  """
  @spec extract_verb([String.t()]) :: {:ok, String.t()} | {:error, :empty_args | :malformed_args}
  def extract_verb(args) when is_list(args) do
    with :ok <- validate_args(args),
         {:ok, _namespaces} <- extract_namespaces(args) do
      args
      |> strip_leading_flags()
      |> verb_from_remaining_args()
    end
  end

  defp validate_args(args) do
    if Enum.all?(args, &is_binary/1), do: :ok, else: {:error, :malformed_args}
  end

  defp reject_forbidden_flags(args) do
    case Enum.find(args, &forbidden_flag?/1) do
      nil -> :ok
      token -> {:error, {:forbidden_flag, token}}
    end
  end

  defp forbidden_flag?(token) do
    Enum.any?(@forbidden_flag_stems, fn stem ->
      token == stem or String.starts_with?(token, stem <> "=")
    end)
  end

  defp extract_namespaces(args) do
    args
    |> do_extract_namespaces([])
    |> normalize_namespace_result()
  end

  defp do_extract_namespaces([], namespaces), do: {:ok, Enum.reverse(namespaces)}

  defp do_extract_namespaces([flag], _namespaces) when flag in @namespace_flags do
    {:error, :malformed_args}
  end

  defp do_extract_namespaces([flag, namespace | rest], namespaces)
       when flag in @namespace_flags do
    if String.starts_with?(namespace, "-") do
      {:error, :malformed_args}
    else
      do_extract_namespaces(rest, [namespace | namespaces])
    end
  end

  defp do_extract_namespaces(["--namespace=" <> namespace | rest], namespaces) do
    if namespace == "" do
      {:error, :malformed_args}
    else
      do_extract_namespaces(rest, [namespace | namespaces])
    end
  end

  defp do_extract_namespaces([_arg | rest], namespaces),
    do: do_extract_namespaces(rest, namespaces)

  defp normalize_namespace_result({:ok, []}), do: {:ok, []}
  defp normalize_namespace_result({:ok, [_namespace] = namespaces}), do: {:ok, namespaces}
  defp normalize_namespace_result({:ok, _multiple}), do: {:error, :malformed_args}
  defp normalize_namespace_result({:error, reason}), do: {:error, reason}

  defp authorize_read_namespace(:read, []), do: :ok

  defp authorize_read_namespace(:read, [namespace]) when namespace in @allowed_read_namespaces do
    :ok
  end

  defp authorize_read_namespace(:read, [namespace]),
    do: {:error, {:forbidden_namespace, namespace}}

  defp authorize_read_namespace(_class, _namespaces), do: :ok

  defp reject_forbidden_resource(args, verb) do
    args
    |> resource_tail(verb)
    |> resource_candidates()
    |> Enum.find(&forbidden_resource?/1)
    |> forbidden_resource_result()
  end

  defp resource_tail(args, "rollout " <> _subcommand) do
    case strip_leading_flags(args) do
      ["rollout" | rest] ->
        case strip_leading_flags(rest) do
          [_subcommand | tail] -> tail
          [] -> []
        end

      _other ->
        []
    end
  end

  defp resource_tail(args, _verb) do
    case strip_leading_flags(args) do
      [_verb | tail] -> tail
      [] -> []
    end
  end

  defp resource_candidates([]), do: []

  defp resource_candidates([flag, _value | rest]) when flag in @resource_flags_with_values do
    resource_candidates(rest)
  end

  defp resource_candidates([flag, _value | rest]) when flag in @safe_skip_flags_with_values do
    resource_candidates(rest)
  end

  defp resource_candidates([flag | rest]) when flag in @safe_skip_flags do
    resource_candidates(rest)
  end

  defp resource_candidates([flag | rest]) do
    if safe_skip_inline_flag?(flag) or String.starts_with?(flag, "-") do
      resource_candidates(rest)
    else
      flag
      |> String.split(",", trim: true)
      |> Kernel.++(resource_candidates(rest))
    end
  end

  defp forbidden_resource_result(nil), do: :ok
  defp forbidden_resource_result(candidate), do: {:error, {:forbidden_resource, candidate}}

  defp forbidden_resource?(candidate) do
    candidate
    |> String.split("/", parts: 2)
    |> hd()
    |> String.split(".", parts: 2)
    |> hd()
    |> String.downcase()
    |> then(&(&1 in @forbidden_resource_types))
  end

  defp strip_leading_flags([]), do: []

  defp strip_leading_flags([flag, _namespace | rest]) when flag in @namespace_flags do
    strip_leading_flags(rest)
  end

  defp strip_leading_flags(["--namespace=" <> _namespace | rest]) do
    strip_leading_flags(rest)
  end

  defp strip_leading_flags([flag, _value | rest]) when flag in @safe_skip_flags_with_values do
    strip_leading_flags(rest)
  end

  defp strip_leading_flags([flag | rest]) when flag in @safe_skip_flags do
    strip_leading_flags(rest)
  end

  defp strip_leading_flags([flag | rest]) do
    if safe_skip_inline_flag?(flag) do
      strip_leading_flags(rest)
    else
      [flag | rest]
    end
  end

  defp safe_skip_inline_flag?(flag) do
    Enum.any?(@safe_skip_flags_with_values, fn safe_flag ->
      String.starts_with?(flag, safe_flag <> "=")
    end)
  end

  defp verb_from_remaining_args([]), do: {:error, :empty_args}
  defp verb_from_remaining_args(args), do: verb_from_tokens(args)

  defp verb_from_tokens(["rollout" | rest]) do
    case strip_leading_flags(rest) do
      [subcommand | _] -> {:ok, "rollout #{subcommand}"}
      [] -> {:ok, "rollout"}
    end
  end

  defp verb_from_tokens([verb | _]), do: {:ok, verb}

  defp classify_scale_verb(args, "scale") do
    with {:ok, value} <- extract_replicas(args),
         :ok <- validate_replica_value(value) do
      {:ok, infer_scale_direction(value)}
    end
  end

  defp classify_scale_verb(_args, verb), do: {:ok, verb}

  defp infer_scale_direction("+" <> _), do: "scale-up"
  defp infer_scale_direction("-" <> _), do: "scale-down"
  defp infer_scale_direction(_value), do: "scale"

  defp extract_replicas(args) do
    args
    |> do_extract_replicas([])
    |> normalize_replicas_result()
  end

  defp do_extract_replicas([], values), do: {:ok, Enum.reverse(values)}
  defp do_extract_replicas(["--replicas"], _values), do: {:error, :malformed_args}

  defp do_extract_replicas(["--replicas", value | rest], values) do
    do_extract_replicas(rest, [value | values])
  end

  defp do_extract_replicas(["--replicas=" <> value | rest], values) do
    do_extract_replicas(rest, [value | values])
  end

  defp do_extract_replicas([_arg | rest], values), do: do_extract_replicas(rest, values)

  defp normalize_replicas_result({:ok, []}), do: {:ok, nil}
  defp normalize_replicas_result({:ok, [value]}), do: {:ok, value}
  defp normalize_replicas_result({:ok, _multiple}), do: {:error, :malformed_args}
  defp normalize_replicas_result({:error, reason}), do: {:error, reason}

  defp validate_replica_value(nil), do: :ok

  defp validate_replica_value(raw_value) do
    with {:ok, value} <- parse_replica_integer(raw_value) do
      enforce_replica_bound(raw_value, value)
    end
  end

  defp parse_replica_integer(raw_value) do
    case Integer.parse(raw_value) do
      {value, ""} -> {:ok, value}
      _error_or_leftover -> {:error, :malformed_args}
    end
  end

  defp enforce_replica_bound("+" <> _ = raw_value, value) do
    enforce_replica_bound(raw_value, abs(value), @replicas_max_delta)
  end

  defp enforce_replica_bound("-" <> _ = raw_value, value) do
    enforce_replica_bound(raw_value, abs(value), @replicas_max_delta)
  end

  defp enforce_replica_bound(raw_value, value) do
    enforce_replica_bound(raw_value, value, @replicas_max_absolute)
  end

  defp enforce_replica_bound(_raw_value, magnitude, max) when magnitude <= max, do: :ok

  defp enforce_replica_bound(raw_value, _magnitude, _max) do
    {:error, {:forbidden_replicas, raw_value}}
  end

  defp lookup(verb, verb_table) do
    Enum.find(@classes, :write_prod_high, fn class ->
      verb in Map.get(verb_table, class, [])
    end)
  end
end
