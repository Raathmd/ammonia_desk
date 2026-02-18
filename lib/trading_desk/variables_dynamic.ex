defmodule TradingDesk.VariablesDynamic do
  @moduledoc """
  Dynamic variable management for any product group.

  Unlike the original `Variables` struct (which hardcodes 18 ammonia-specific
  fields), this module works with any product group's solver frame. Variables
  are represented as plain maps with keys from the frame definition.

  ## Usage

      # Create variables from defaults for a product group
      vars = VariablesDynamic.defaults(:sulphur_international)

      # Validate a variable map against its frame
      {:ok, vars} = VariablesDynamic.validate(vars, :sulphur_international)

      # Pack to binary for solver port (f64-LE, ordered by frame)
      binary = VariablesDynamic.to_binary(vars, :sulphur_international)

      # Unpack from binary
      vars = VariablesDynamic.from_binary(binary, :sulphur_international)

      # Get metadata for UI rendering
      meta = VariablesDynamic.metadata(:sulphur_international)

  ## Backward Compatibility

  For the `:ammonia_domestic` product group, `to_binary/2` produces the same
  160-byte payload as `Variables.to_binary/1`, maintaining compatibility with
  the existing Zig solver.
  """

  alias TradingDesk.ProductGroup

  @doc "Get default variable values as a map for a product group."
  @spec defaults(atom()) :: map()
  def defaults(product_group) do
    ProductGroup.default_values(product_group)
  end

  @doc "Validate a variable map against a product group's frame."
  @spec validate(map(), atom()) :: {:ok, map()} | {:error, [term()]}
  def validate(vars, product_group) do
    frame_vars = ProductGroup.variables(product_group)
    errors = []

    # Check for missing keys
    missing =
      frame_vars
      |> Enum.filter(fn v -> not Map.has_key?(vars, v[:key]) end)
      |> Enum.map(fn v -> {:missing, v[:key]} end)

    # Check for out-of-range values
    range_errors =
      frame_vars
      |> Enum.filter(fn v ->
        val = Map.get(vars, v[:key])
        val != nil and v[:type] != :boolean and is_number(val) and
          (val < v[:min] or val > v[:max])
      end)
      |> Enum.map(fn v ->
        {:out_of_range, v[:key], Map.get(vars, v[:key]), {v[:min], v[:max]}}
      end)

    errors = errors ++ missing ++ range_errors

    if errors == [] do
      {:ok, vars}
    else
      {:error, errors}
    end
  end

  @doc """
  Pack variables into binary for the solver port.

  Returns a binary of `n × 8` bytes, where n is the number of variables
  in the product group's frame, each encoded as f64-LE.

  Variables are ordered according to the frame definition order.
  Boolean variables are encoded as 1.0 (true) or 0.0 (false).
  """
  @spec to_binary(map(), atom()) :: binary()
  def to_binary(vars, product_group) do
    keys = ProductGroup.variable_keys(product_group)

    keys
    |> Enum.map(fn key ->
      val = Map.get(vars, key, 0.0)
      encode_f64(val)
    end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Unpack variables from binary.

  Expects `n × 8` bytes, where n is the number of variables in the frame.
  """
  @spec from_binary(binary(), atom()) :: map()
  def from_binary(binary, product_group) do
    keys = ProductGroup.variable_keys(product_group)
    n = length(keys)
    expected_size = n * 8

    if byte_size(binary) < expected_size do
      raise ArgumentError, "binary too short: got #{byte_size(binary)} bytes, expected #{expected_size}"
    end

    keys
    |> Enum.with_index()
    |> Map.new(fn {key, i} ->
      offset = i * 8
      <<_::binary-size(offset), val::float-little-64, _::binary>> = binary
      {key, val}
    end)
  end

  @doc "Get variable metadata for UI rendering."
  @spec metadata(atom()) :: [map()]
  def metadata(product_group) do
    ProductGroup.variable_metadata(product_group)
  end

  @doc "Get the byte size of the binary representation."
  @spec binary_size(atom()) :: non_neg_integer()
  def binary_size(product_group) do
    ProductGroup.variable_count(product_group) * 8
  end

  @doc """
  Convert an old-style Variables struct to a map.

  For backward compatibility with the ammonia_domestic frame.
  """
  @spec from_struct(struct()) :: map()
  def from_struct(%TradingDesk.Variables{} = v) do
    Map.from_struct(v)
  end
  def from_struct(map) when is_map(map) do
    Map.drop(map, [:__struct__])
  end

  @doc """
  Merge new data into existing variables, only updating keys that exist in the frame.
  """
  @spec merge(map(), map(), atom()) :: map()
  def merge(existing, new_data, product_group) do
    valid_keys = MapSet.new(ProductGroup.variable_keys(product_group))

    Enum.reduce(new_data, existing, fn {key, value}, acc ->
      if MapSet.member?(valid_keys, key) and not is_nil(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  @doc "Get the unique groups used by a product group's variables (for UI grouping)."
  @spec groups(atom()) :: [atom()]
  def groups(product_group) do
    ProductGroup.variables(product_group)
    |> Enum.map(& &1[:group])
    |> Enum.uniq()
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp encode_f64(true), do: <<1.0::float-little-64>>
  defp encode_f64(false), do: <<0.0::float-little-64>>
  defp encode_f64(val) when is_number(val), do: <<val / 1.0::float-little-64>>
  defp encode_f64(_), do: <<0.0::float-little-64>>
end
