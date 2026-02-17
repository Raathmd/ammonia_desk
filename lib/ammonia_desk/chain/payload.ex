defmodule AmmoniaDesk.Chain.Payload do
  @moduledoc """
  Canonical binary payload serialization for BSV on-chain commitments.

  Every solve (trader or auto) is serialized into a deterministic binary format,
  hashed, signed, encrypted, and stored on-chain in an OP_RETURN output.

  ## Payload Types

    - 0x01: SOLVE_COMMIT — trader commits to a single solve result
    - 0x02: MC_COMMIT — trader commits to a Monte Carlo distribution
    - 0x03: AUTO_SOLVE — server auto-solve triggered by delta threshold
    - 0x04: AUTO_MC — server auto Monte Carlo triggered by delta threshold
    - 0x05: CONFIG_CHANGE — admin updates delta config

  ## Binary Format

    HEADER (8 bytes)
      magic:          4B    "NH3\\x01" (ammonia protocol v1)
      type:           1B    payload type (0x01-0x05)
      product_group:  1B    0x01=ammonia, 0x02=uan, 0x03=urea
      version:        1B    payload version (0x01)
      flags:          1B    reserved

    TIMESTAMP (8 bytes)
      unix_ms:        8B    u64-LE — milliseconds since epoch

    VARIABLES (160 bytes)
      20 × f64-LE: canonical variable order (same as Variables.to_binary/1)

    RESULT (varies by type)
      For SOLVE (type 0x01, 0x03):
        status:       1B    0x00=optimal, 0x01=infeasible, 0x02=error
        profit:       8B    f64-LE
        tons:         8B    f64-LE
        cost:         8B    f64-LE
        roi:          8B    f64-LE
        route_tons:   32B   4 × f64-LE
        margins:      32B   4 × f64-LE

      For MC (type 0x02, 0x04):
        signal:       1B    0x01=strong_go .. 0x05=no_go
        n_scenarios:  4B    u32-LE
        n_feasible:   4B    u32-LE
        mean:         8B    f64-LE
        stddev:       8B    f64-LE
        p5:           8B    f64-LE
        p25:          8B    f64-LE
        p50:          8B    f64-LE
        p75:          8B    f64-LE
        p95:          8B    f64-LE
        min:          8B    f64-LE
        max:          8B    f64-LE

    TRIGGER (only for types 0x03, 0x04 — auto-solve)
      triggered_mask: 4B    u32-LE bitmask (bit per variable)
      n_triggered:    1B    count of triggered variables
      For each triggered variable (33 bytes each):
        var_index:    1B    variable index (0-19)
        baseline:     8B    f64-LE — value at last solve
        current:      8B    f64-LE — value that triggered
        threshold:    8B    f64-LE — configured threshold
        delta:        8B    f64-LE — actual delta

  Full payload is then:
    1. SHA-256 hashed → 32-byte digest
    2. ECDSA signed with signer's BSV key
    3. AES-256-GCM encrypted (key from ECDH)
    4. Stored in OP_RETURN
  """

  @magic "NH3\x01"

  # Payload types
  @type_solve_commit  0x01
  @type_mc_commit     0x02
  @type_auto_solve    0x03
  @type_auto_mc       0x04
  @type_config_change 0x05

  # Product group codes
  @pg_ammonia 0x01
  @pg_uan     0x02
  @pg_urea    0x03

  # Signal codes
  @signal_strong_go 0x01
  @signal_go        0x02
  @signal_cautious  0x03
  @signal_weak      0x04
  @signal_no_go     0x05

  @doc "Serialize an auto-solve (MC) to canonical binary."
  @spec serialize_auto_mc(map()) :: binary()
  def serialize_auto_mc(opts) do
    variables = opts[:variables]
    distribution = opts[:distribution]
    trigger_details = opts[:trigger_details] || []
    product_group = opts[:product_group] || :ammonia
    timestamp = opts[:timestamp] || DateTime.utc_now()

    header = serialize_header(@type_auto_mc, product_group)
    ts = serialize_timestamp(timestamp)
    vars = AmmoniaDesk.Variables.to_binary(variables)
    result = serialize_mc_result(distribution)
    trigger = serialize_trigger_section(trigger_details)

    header <> ts <> vars <> result <> trigger
  end

  @doc "Serialize an auto-solve (single) to canonical binary."
  @spec serialize_auto_solve(map()) :: binary()
  def serialize_auto_solve(opts) do
    variables = opts[:variables]
    result_data = opts[:result]
    trigger_details = opts[:trigger_details] || []
    product_group = opts[:product_group] || :ammonia
    timestamp = opts[:timestamp] || DateTime.utc_now()

    header = serialize_header(@type_auto_solve, product_group)
    ts = serialize_timestamp(timestamp)
    vars = AmmoniaDesk.Variables.to_binary(variables)
    result = serialize_solve_result(result_data)
    trigger = serialize_trigger_section(trigger_details)

    header <> ts <> vars <> result <> trigger
  end

  @doc "Serialize a trader solve commit to canonical binary."
  @spec serialize_solve_commit(map()) :: binary()
  def serialize_solve_commit(opts) do
    variables = opts[:variables]
    result_data = opts[:result]
    product_group = opts[:product_group] || :ammonia
    timestamp = opts[:timestamp] || DateTime.utc_now()

    header = serialize_header(@type_solve_commit, product_group)
    ts = serialize_timestamp(timestamp)
    vars = AmmoniaDesk.Variables.to_binary(variables)
    result = serialize_solve_result(result_data)

    header <> ts <> vars <> result
  end

  @doc "Serialize a trader MC commit to canonical binary."
  @spec serialize_mc_commit(map()) :: binary()
  def serialize_mc_commit(opts) do
    variables = opts[:variables]
    distribution = opts[:distribution]
    product_group = opts[:product_group] || :ammonia
    timestamp = opts[:timestamp] || DateTime.utc_now()

    header = serialize_header(@type_mc_commit, product_group)
    ts = serialize_timestamp(timestamp)
    vars = AmmoniaDesk.Variables.to_binary(variables)
    result = serialize_mc_result(distribution)

    header <> ts <> vars <> result
  end

  @doc "Serialize a config change to canonical binary."
  @spec serialize_config_change(map()) :: binary()
  def serialize_config_change(opts) do
    product_group = opts[:product_group] || :ammonia
    timestamp = opts[:timestamp] || DateTime.utc_now()
    config_json = Jason.encode!(opts[:config] || %{})

    header = serialize_header(@type_config_change, product_group)
    ts = serialize_timestamp(timestamp)
    config_bytes = config_json

    header <> ts <> <<byte_size(config_bytes)::little-32>> <> config_bytes
  end

  @doc "SHA-256 hash of a canonical payload."
  @spec hash(binary()) :: binary()
  def hash(payload) do
    :crypto.hash(:sha256, payload)
  end

  @doc "SHA-256 hash as hex string."
  @spec hash_hex(binary()) :: String.t()
  def hash_hex(payload) do
    hash(payload) |> Base.encode16(case: :lower)
  end

  @doc "Get the type byte name."
  def type_name(@type_solve_commit), do: :solve_commit
  def type_name(@type_mc_commit), do: :mc_commit
  def type_name(@type_auto_solve), do: :auto_solve
  def type_name(@type_auto_mc), do: :auto_mc
  def type_name(@type_config_change), do: :config_change
  def type_name(_), do: :unknown

  @doc "Get the type byte value."
  def type_code(:solve_commit), do: @type_solve_commit
  def type_code(:mc_commit), do: @type_mc_commit
  def type_code(:auto_solve), do: @type_auto_solve
  def type_code(:auto_mc), do: @type_auto_mc
  def type_code(:config_change), do: @type_config_change

  # ──────────────────────────────────────────────────────────
  # SERIALIZATION HELPERS
  # ──────────────────────────────────────────────────────────

  defp serialize_header(type, product_group) do
    pg_code = case product_group do
      :ammonia -> @pg_ammonia
      :uan -> @pg_uan
      :urea -> @pg_urea
      _ -> @pg_ammonia
    end

    <<@magic::binary, type::8, pg_code::8, 0x01::8, 0x00::8>>
  end

  defp serialize_timestamp(datetime) do
    unix_ms = DateTime.to_unix(datetime, :millisecond)
    <<unix_ms::little-64>>
  end

  defp serialize_solve_result(result) when is_map(result) do
    status = case Map.get(result, :status) do
      :optimal -> 0x00
      :infeasible -> 0x01
      _ -> 0x02
    end

    profit = to_f64(result[:profit])
    tons = to_f64(result[:tons])
    cost = to_f64(result[:cost])
    roi = to_f64(result[:roi])

    route_tons = result[:route_tons] || [0, 0, 0, 0]
    margins = result[:margins] || [0, 0, 0, 0]

    <<
      status::8,
      profit::float-little-64,
      tons::float-little-64,
      cost::float-little-64,
      roi::float-little-64,
      serialize_f64_array(route_tons, 4)::binary,
      serialize_f64_array(margins, 4)::binary
    >>
  end
  defp serialize_solve_result(_), do: <<0x02::8, 0::float-little-64>>

  defp serialize_mc_result(dist) when is_map(dist) do
    signal = case Map.get(dist, :signal) do
      :strong_go -> @signal_strong_go
      :go -> @signal_go
      :cautious -> @signal_cautious
      :weak -> @signal_weak
      :no_go -> @signal_no_go
      _ -> 0x00
    end

    <<
      signal::8,
      to_u32(dist[:n_scenarios])::little-32,
      to_u32(dist[:n_feasible])::little-32,
      to_f64(dist[:mean])::float-little-64,
      to_f64(dist[:stddev])::float-little-64,
      to_f64(dist[:p5])::float-little-64,
      to_f64(dist[:p25])::float-little-64,
      to_f64(dist[:p50])::float-little-64,
      to_f64(dist[:p75])::float-little-64,
      to_f64(dist[:p95])::float-little-64,
      to_f64(dist[:min])::float-little-64,
      to_f64(dist[:max])::float-little-64
    >>
  end
  defp serialize_mc_result(_), do: <<0x00::8>>

  defp serialize_trigger_section([]), do: <<0::little-32, 0::8>>
  defp serialize_trigger_section(triggers) do
    # Build bitmask
    mask = Enum.reduce(triggers, 0, fn t, acc ->
      idx = t[:variable_index] || 0
      Bitwise.bor(acc, Bitwise.bsl(1, idx))
    end)

    n = length(triggers)

    trigger_entries = Enum.map(triggers, fn t ->
      <<
        (t[:variable_index] || 0)::8,
        to_f64(t[:baseline_value])::float-little-64,
        to_f64(t[:current_value])::float-little-64,
        to_f64(t[:threshold])::float-little-64,
        to_f64(t[:delta])::float-little-64
      >>
    end)

    <<mask::little-32, n::8>> <> IO.iodata_to_binary(trigger_entries)
  end

  defp serialize_f64_array(values, expected_len) do
    padded = (values ++ List.duplicate(0, expected_len)) |> Enum.take(expected_len)
    Enum.map(padded, fn v -> <<to_f64(v)::float-little-64>> end) |> IO.iodata_to_binary()
  end

  defp to_f64(nil), do: 0.0
  defp to_f64(v) when is_number(v), do: v / 1
  defp to_f64(_), do: 0.0

  defp to_u32(nil), do: 0
  defp to_u32(v) when is_integer(v), do: v
  defp to_u32(v) when is_float(v), do: round(v)
  defp to_u32(_), do: 0
end
