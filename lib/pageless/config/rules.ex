defmodule Pageless.Config.Rules do
  @moduledoc """
  Loads and validates the static Pageless governance rules YAML.
  """

  @enforce_keys [:capability_classes, :kubectl_verbs, :function_blocklist]
  defstruct [
    :capability_classes,
    :kubectl_verbs,
    :function_blocklist,
    investigator_profiles: %{},
    alert_class_routing: %{},
    kubectl_config: %{},
    query_db_config: %{},
    rate_limiter_config: %{}
  ]

  @class_names ~w(read write_dev write_prod_low write_prod_high)
  @class_atoms %{
    "read" => :read,
    "write_dev" => :write_dev,
    "write_prod_low" => :write_prod_low,
    "write_prod_high" => :write_prod_high
  }
  @policy_fields ~w(auto audit gated)
  @policy_field_atoms %{"auto" => :auto, "audit" => :audit, "gated" => :gated}

  @typedoc "Capability policy for one governance class."
  @type capability_policy :: %{auto: boolean(), audit: boolean(), gated: boolean()}

  @typedoc "Fixed governance classification used by packet 1 rules."
  @type classification :: :read | :write_dev | :write_prod_low | :write_prod_high

  @type t :: %__MODULE__{
          capability_classes: %{classification() => capability_policy()},
          kubectl_verbs: %{classification() => [String.t()]},
          function_blocklist: [String.t()],
          investigator_profiles: map(),
          alert_class_routing: map(),
          kubectl_config: map(),
          query_db_config: map(),
          rate_limiter_config: map()
        }

  @doc "Loads rules from a YAML file and validates the parsed shape."
  @spec load!(Path.t()) :: t()
  def load!(path) do
    unless File.exists?(path),
      do: raise(File.Error, reason: :enoent, action: "read file", path: path)

    path
    |> YamlElixir.read_from_file!()
    |> validate!()
  end

  @doc "Validates parsed YAML and returns a normalized rules struct."
  @spec validate!(map()) :: t()
  def validate!(parsed) when is_map(parsed) do
    require_top_level_keys!(parsed)

    %__MODULE__{
      capability_classes: validate_capability_classes!(Map.fetch!(parsed, "capability_classes")),
      kubectl_verbs: validate_kubectl_verbs!(Map.fetch!(parsed, "kubectl_verbs")),
      function_blocklist:
        validate_string_list!(Map.fetch!(parsed, "function_blocklist"), "function_blocklist"),
      investigator_profiles: validate_optional_map!(parsed, "investigator_profiles"),
      alert_class_routing: validate_optional_map!(parsed, "alert_class_routing"),
      kubectl_config: validate_optional_map!(parsed, "kubectl", "kubectl_config"),
      query_db_config: validate_optional_map!(parsed, "query_db", "query_db_config"),
      rate_limiter_config: validate_optional_map!(parsed, "rate_limiter", "rate_limiter_config")
    }
  end

  def validate!(_parsed), do: raise(ArgumentError, "rules YAML must parse to a map")

  @doc "Returns the capability policy for a valid class."
  @spec policy_for(t(), classification()) :: capability_policy()
  def policy_for(%__MODULE__{} = rules, class), do: Map.fetch!(rules.capability_classes, class)

  defp require_top_level_keys!(parsed) do
    for key <- ["capability_classes", "kubectl_verbs", "function_blocklist"] do
      unless Map.has_key?(parsed, key), do: raise(ArgumentError, "missing required key #{key}")
    end
  end

  defp validate_capability_classes!(classes) when is_map(classes) do
    validate_exact_keys!(classes, @class_names, "capability_classes")

    normalized =
      Map.new(@class_names, fn class_name ->
        {Map.fetch!(@class_atoms, class_name),
         validate_policy!(class_name, Map.fetch!(classes, class_name))}
      end)

    unless normalized.write_prod_high.gated do
      raise ArgumentError, "write_prod_high must be gated"
    end

    normalized
  end

  defp validate_capability_classes!(_classes),
    do: raise(ArgumentError, "capability_classes must be a map")

  defp validate_policy!(class_name, policy) when is_map(policy) do
    validate_exact_keys!(policy, @policy_fields, "capability_classes.#{class_name}")

    Map.new(@policy_fields, fn field ->
      value = Map.fetch!(policy, field)
      unless is_boolean(value), do: raise(ArgumentError, "#{class_name}.#{field} must be boolean")
      {Map.fetch!(@policy_field_atoms, field), value}
    end)
  end

  defp validate_policy!(class_name, _policy),
    do: raise(ArgumentError, "#{class_name} policy must be a map")

  defp validate_kubectl_verbs!(verbs) when is_map(verbs) do
    validate_exact_keys!(verbs, @class_names, "kubectl_verbs")

    Map.new(@class_names, fn class_name ->
      {Map.fetch!(@class_atoms, class_name),
       validate_string_list!(Map.fetch!(verbs, class_name), class_name)}
    end)
  end

  defp validate_kubectl_verbs!(_verbs), do: raise(ArgumentError, "kubectl_verbs must be a map")

  defp validate_optional_map!(parsed, key), do: validate_optional_map!(parsed, key, key)

  defp validate_optional_map!(parsed, key, label) do
    case Map.get(parsed, key, %{}) do
      value when is_map(value) -> value
      _value -> raise(ArgumentError, "#{label} must be a map")
    end
  end

  defp validate_string_list!(values, label) when is_list(values) do
    unless Enum.all?(values, &is_binary/1),
      do: raise(ArgumentError, "#{label} must contain only strings")

    values
  end

  defp validate_string_list!(_values, label),
    do: raise(ArgumentError, "#{label} must be a list of strings")

  defp validate_exact_keys!(map, expected, label) do
    keys = Map.keys(map)
    missing = expected -- keys
    extra = keys -- expected

    cond do
      missing != [] -> raise ArgumentError, "#{label} missing #{Enum.join(missing, ", ")}"
      extra != [] -> raise ArgumentError, "#{label} has unknown #{Enum.join(extra, ", ")}"
      true -> :ok
    end
  end
end
