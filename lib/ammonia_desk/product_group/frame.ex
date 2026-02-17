defmodule AmmoniaDesk.ProductGroup.Frame do
  @moduledoc """
  Behaviour for product group solver frame definitions.

  Each product group implements this behaviour to define its complete
  solver frame — variables, routes, constraints, API sources, and
  contract term mappings.

  ## Implementing a New Product Group

      defmodule AmmoniaDesk.ProductGroup.Frames.MyProduct do
        @behaviour AmmoniaDesk.ProductGroup.Frame

        @impl true
        def frame do
          %{
            id: :my_product,
            name: "My Product",
            product: "Widget",
            transport_mode: :ocean_vessel,
            variables: [...],
            routes: [...],
            constraints: [...],
            api_sources: %{...},
            ...
          }
        end
      end

  ## Variable Definition Format

      %{
        key: :price_fob,
        label: "FOB Price",
        unit: "$/ton",
        min: 50.0,
        max: 500.0,
        step: 1.0,
        default: 150.0,
        source: :market,
        group: :commercial,
        type: :float,            # :float | :boolean
        delta_threshold: 2.0,    # for auto-solve triggering
        perturbation: %{         # for Monte Carlo
          stddev: 10.0,
          min: 50.0,
          max: 500.0,
          correlations: []       # [{:other_var, coefficient}]
        }
      }

  ## Route Definition Format

      %{
        key: :vancouver_mumbai,
        name: "Vancouver → Mumbai",
        origin: "Vancouver, BC",
        destination: "Mumbai, India",
        distance_nm: 7800,
        transport_mode: :ocean_vessel,
        freight_variable: :fr_van_mum,
        sell_variable: :sell_mumbai,
        typical_transit_days: 28
      }
  """

  @callback frame() :: map()
end
