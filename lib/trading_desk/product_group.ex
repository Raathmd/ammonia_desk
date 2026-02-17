defmodule TradingDesk.ProductGroup do
  @moduledoc """
  Product group registry and solver frame abstraction.

  Each product group (ammonia domestic, international sulphur, petcoke, etc.)
  defines its own **solver frame** — the complete specification of what variables
  the solver operates on, what routes exist, which API sources feed data, and
  how contracts map to solver parameters.

  ## Solver Frame

  A solver frame is a map with these keys:

    - `:id` — atom identifier (e.g., `:ammonia_domestic`, `:sulphur_international`)
    - `:name` — display name (e.g., "NH3 Domestic Barge")
    - `:product` — commodity traded (e.g., "Anhydrous Ammonia", "Sulphur")
    - `:transport_mode` — :barge | :ocean_vessel | :rail | :truck | :pipeline
    - `:variables` — ordered list of variable definitions
    - `:routes` — list of route definitions (origin → destination)
    - `:constraints` — list of constraint definitions
    - `:api_sources` — map of source_key → API module + config
    - `:perturbation` — Monte Carlo perturbation parameters per variable
    - `:signal_thresholds` — thresholds for go/no-go signal classification
    - `:contract_term_map` — maps contract clause_ids to solver parameters
    - `:location_anchors` — maps location names to solver parameter keys
    - `:price_anchors` — maps price references to solver parameter keys
    - `:product_patterns` — regex patterns that identify this product in contracts
    - `:chain_magic` — 4-byte magic header for on-chain payload
    - `:chain_product_code` — 1-byte product code for chain encoding

  ## Usage

      # Get a product group's full frame
      frame = ProductGroup.frame(:ammonia_domestic)

      # List all registered product groups
      ProductGroup.list()

      # Get just variable definitions
      ProductGroup.variables(:sulphur_international)

      # Get route definitions
      ProductGroup.routes(:petcoke)

  ## Adding a New Product Group

  Create a module that implements the `TradingDesk.ProductGroup.Frame` behaviour
  and register it in the `@registry` below.
  """

  alias TradingDesk.ProductGroup.Frames

  # ──────────────────────────────────────────────────────────
  # REGISTRY
  # ──────────────────────────────────────────────────────────

  @registry %{
    ammonia_domestic:        Frames.AmmoniaDomestic,
    sulphur_international:   Frames.SulphurInternational,
    petcoke:                 Frames.Petcoke,
    ammonia_international:   Frames.AmmoniaInternational,
    # Legacy aliases — map old atom to new canonical id
    ammonia:                 Frames.AmmoniaDomestic,
    uan:                     Frames.AmmoniaDomestic,   # placeholder until UAN frame built
    urea:                    Frames.AmmoniaDomestic    # placeholder until urea frame built
  }

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc "Get the full solver frame for a product group."
  @spec frame(atom()) :: map() | nil
  def frame(product_group) do
    case Map.get(@registry, product_group) do
      nil -> nil
      module -> module.frame()
    end
  end

  @doc "List all registered product group IDs (excluding aliases)."
  @spec list() :: [atom()]
  def list do
    @registry
    |> Enum.uniq_by(fn {_k, v} -> v end)
    |> Enum.map(fn {k, _v} -> k end)
    |> Enum.sort()
  end

  @doc "List all product groups with display info."
  @spec list_with_info() :: [map()]
  def list_with_info do
    list()
    |> Enum.map(fn id ->
      f = frame(id)
      %{
        id: id,
        name: f[:name],
        product: f[:product],
        transport_mode: f[:transport_mode],
        variable_count: length(f[:variables]),
        route_count: length(f[:routes])
      }
    end)
  end

  @doc "Get variable definitions for a product group."
  @spec variables(atom()) :: [map()]
  def variables(product_group) do
    case frame(product_group) do
      nil -> []
      f -> f[:variables]
    end
  end

  @doc "Get variable keys (ordered) for a product group."
  @spec variable_keys(atom()) :: [atom()]
  def variable_keys(product_group) do
    variables(product_group) |> Enum.map(& &1[:key])
  end

  @doc "Get the number of variables for a product group."
  @spec variable_count(atom()) :: non_neg_integer()
  def variable_count(product_group) do
    length(variables(product_group))
  end

  @doc "Get route definitions for a product group."
  @spec routes(atom()) :: [map()]
  def routes(product_group) do
    case frame(product_group) do
      nil -> []
      f -> f[:routes]
    end
  end

  @doc "Get route names for UI display."
  @spec route_names(atom()) :: [String.t()]
  def route_names(product_group) do
    routes(product_group) |> Enum.map(& &1[:name])
  end

  @doc "Get the number of routes for a product group."
  @spec route_count(atom()) :: non_neg_integer()
  def route_count(product_group) do
    length(routes(product_group))
  end

  @doc "Get constraint definitions for a product group."
  @spec constraints(atom()) :: [map()]
  def constraints(product_group) do
    case frame(product_group) do
      nil -> []
      f -> f[:constraints] || []
    end
  end

  @doc "Get constraint names for UI display."
  @spec constraint_names(atom()) :: [String.t()]
  def constraint_names(product_group) do
    constraints(product_group) |> Enum.map(& &1[:name])
  end

  @doc "Get API source configuration for a product group."
  @spec api_sources(atom()) :: map()
  def api_sources(product_group) do
    case frame(product_group) do
      nil -> %{}
      f -> f[:api_sources] || %{}
    end
  end

  @doc "Get default variable values as a map."
  @spec default_values(atom()) :: map()
  def default_values(product_group) do
    variables(product_group)
    |> Map.new(fn v -> {v[:key], v[:default]} end)
  end

  @doc "Get variable metadata (for UI sliders, labels, etc.)."
  @spec variable_metadata(atom()) :: [map()]
  def variable_metadata(product_group) do
    variables(product_group)
    |> Enum.map(fn v ->
      %{
        key: v[:key],
        label: v[:label],
        unit: v[:unit],
        min: v[:min],
        max: v[:max],
        step: v[:step],
        source: v[:source],
        group: v[:group],
        type: v[:type]
      }
    end)
  end

  @doc "Get variable index map (key → 0-based index) for a product group."
  @spec variable_indices(atom()) :: %{atom() => non_neg_integer()}
  def variable_indices(product_group) do
    variables(product_group)
    |> Enum.with_index()
    |> Map.new(fn {v, i} -> {v[:key], i} end)
  end

  @doc "Get signal thresholds for a product group."
  @spec signal_thresholds(atom()) :: map()
  def signal_thresholds(product_group) do
    case frame(product_group) do
      nil -> %{strong_go: 50_000, go: 50_000, cautious: 0, weak: 0}
      f -> f[:signal_thresholds] || %{strong_go: 50_000, go: 50_000, cautious: 0, weak: 0}
    end
  end

  @doc "Get contract term mapping for a product group."
  @spec contract_term_map(atom()) :: map()
  def contract_term_map(product_group) do
    case frame(product_group) do
      nil -> %{}
      f -> f[:contract_term_map] || %{}
    end
  end

  @doc "Get perturbation parameters for Monte Carlo."
  @spec perturbation(atom()) :: map()
  def perturbation(product_group) do
    case frame(product_group) do
      nil -> %{}
      f -> f[:perturbation] || %{}
    end
  end

  @doc "Get default delta thresholds for a product group."
  @spec default_thresholds(atom()) :: map()
  def default_thresholds(product_group) do
    variables(product_group)
    |> Map.new(fn v -> {v[:key], v[:delta_threshold] || 1.0} end)
  end

  @doc "Get default poll intervals for a product group."
  @spec default_poll_intervals(atom()) :: map()
  def default_poll_intervals(product_group) do
    case frame(product_group) do
      nil -> %{}
      f -> f[:default_poll_intervals] || %{}
    end
  end

  @doc "Get the chain magic header bytes for a product group."
  @spec chain_magic(atom()) :: binary()
  def chain_magic(product_group) do
    case frame(product_group) do
      nil -> "GEN\x01"
      f -> f[:chain_magic] || "GEN\x01"
    end
  end

  @doc "Get the chain product code byte for a product group."
  @spec chain_product_code(atom()) :: non_neg_integer()
  def chain_product_code(product_group) do
    case frame(product_group) do
      nil -> 0xFF
      f -> f[:chain_product_code] || 0xFF
    end
  end

  @doc "Check if a product group is registered."
  @spec registered?(atom()) :: boolean()
  def registered?(product_group) do
    Map.has_key?(@registry, product_group)
  end

  @doc "Get the frame module for a product group."
  @spec frame_module(atom()) :: module() | nil
  def frame_module(product_group) do
    Map.get(@registry, product_group)
  end
end
