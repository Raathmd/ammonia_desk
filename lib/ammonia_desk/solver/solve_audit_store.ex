defmodule AmmoniaDesk.Solver.SolveAuditStore do
  @moduledoc """
  Stores immutable solve audit records.

  Every pipeline execution (solve or Monte Carlo) writes an audit record
  here. Records are append-only — never updated or deleted.

  ## Tables

    :solve_audits           — {audit_id, %SolveAudit{}}
    :solve_audit_by_trader  — {{trader_id, timestamp}, audit_id}
    :solve_audit_by_contract — {{contract_id, timestamp}, audit_id}
    :solve_audit_timeline   — {{product_group, timestamp}, audit_id}

  ## Queries

    list_recent/1          — last N audits across all groups
    find_by_contract/2     — all solves that used a specific contract version
    find_by_trader/2       — all solves by a trader
    find_by_time_range/3   — solves within a time window for a product group
    trader_decision_chain/2 — ordered solve history for a trader (DAG-ready)
    product_group_timeline/2 — full timeline for a product group (management view)
    compare_paths/2        — compare auto-runner vs trader decisions over a period
  """

  use GenServer

  alias AmmoniaDesk.Solver.SolveAudit

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc "Store a completed audit record. Returns {:ok, audit}."
  @spec record(%SolveAudit{}) :: {:ok, %SolveAudit{}}
  def record(%SolveAudit{} = audit) do
    GenServer.call(__MODULE__, {:record, audit})
  end

  @doc "Get a single audit by ID."
  @spec get(String.t()) :: {:ok, %SolveAudit{}} | {:error, :not_found}
  def get(audit_id) do
    GenServer.call(__MODULE__, {:get, audit_id})
  end

  @doc "List most recent N audit records."
  @spec list_recent(pos_integer()) :: [%SolveAudit{}]
  def list_recent(limit \\ 50) do
    GenServer.call(__MODULE__, {:list_recent, limit})
  end

  @doc """
  Find all solves that used a specific contract (by contract ID).

  Returns audits where this contract version appears in `contracts_used`.
  Useful for answering: "which decisions were based on this contract?"
  """
  @spec find_by_contract(String.t(), keyword()) :: [%SolveAudit{}]
  def find_by_contract(contract_id, opts \\ []) do
    GenServer.call(__MODULE__, {:find_by_contract, contract_id, opts})
  end

  @doc """
  Find all solves by a specific trader.

  Returns audits in chronological order. This is the trader's decision
  history — each solve represents a decision point.
  """
  @spec find_by_trader(String.t(), keyword()) :: [%SolveAudit{}]
  def find_by_trader(trader_id, opts \\ []) do
    GenServer.call(__MODULE__, {:find_by_trader, trader_id, opts})
  end

  @doc """
  Find solves within a time window for a product group.

  Management view: see all decisions made for ammonia trading
  between two dates.
  """
  @spec find_by_time_range(atom(), DateTime.t(), DateTime.t()) :: [%SolveAudit{}]
  def find_by_time_range(product_group, from, to) do
    GenServer.call(__MODULE__, {:find_by_time_range, product_group, from, to})
  end

  @doc """
  Get a trader's decision chain — ordered sequence of solves
  with contract version transitions and variable deltas.

  Returns a list of nodes suitable for DAG visualization:

      [%{
        audit: %SolveAudit{},
        contracts_changed_from_prev: [...],  # contract versions that changed since last solve
        variables_delta: %{...},              # significant variable changes
        time_since_prev: seconds,
        decision_type: :initial | :recheck | :variable_change | :contract_update
      }]
  """
  @spec trader_decision_chain(String.t(), keyword()) :: [map()]
  def trader_decision_chain(trader_id, opts \\ []) do
    GenServer.call(__MODULE__, {:trader_decision_chain, trader_id, opts})
  end

  @doc """
  Full timeline for a product group — both auto-runner and trader decisions.

  Management view: see how the auto-runner's continuous monitoring compares
  to actual trader decisions. Each entry is a node in the decision DAG.

  Returns:
      [%{
        audit: %SolveAudit{},
        source: :auto_runner | :trader,
        trader_id: "..." | nil,
        profit_or_signal: number | atom,
        contracts_version_set: "v3-Koch/v2-Mosaic/..."   # compact contract state ID
      }]
  """
  @spec product_group_timeline(atom(), keyword()) :: [map()]
  def product_group_timeline(product_group, opts \\ []) do
    GenServer.call(__MODULE__, {:product_group_timeline, product_group, opts})
  end

  @doc """
  Compare auto-runner signals against trader decisions over a period.

  Shows where the auto-runner said "go" but the trader didn't act,
  where the trader overrode the signal, and overall alignment.

  Returns:
      %{
        period: {from, to},
        auto_signals: [%{at: DateTime, signal: atom, profit_mean: number}],
        trader_solves: [%{at: DateTime, mode: atom, profit: number}],
        alignment_score: float,   # 0.0 - 1.0
        missed_opportunities: [%{auto_signal: ..., trader_action: nil}],
        overrides: [%{auto_signal: :no_go, trader_action: :solve}]
      }
  """
  @spec compare_paths(atom(), keyword()) :: map()
  def compare_paths(product_group, opts \\ []) do
    GenServer.call(__MODULE__, {:compare_paths, product_group, opts})
  end

  @doc """
  Aggregate performance metrics for a trader or product group.

  Returns summary stats for management dashboards.
  """
  @spec performance_summary(keyword()) :: map()
  def performance_summary(opts \\ []) do
    GenServer.call(__MODULE__, {:performance_summary, opts})
  end

  # ──────────────────────────────────────────────────────────
  # GENSERVER
  # ──────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    audits = :ets.new(:solve_audits, [:set, :protected])
    by_trader = :ets.new(:solve_audit_by_trader, [:ordered_set, :protected])
    by_contract = :ets.new(:solve_audit_by_contract, [:ordered_set, :protected])
    timeline = :ets.new(:solve_audit_timeline, [:ordered_set, :protected])

    {:ok, %{
      audits: audits,
      by_trader: by_trader,
      by_contract: by_contract,
      timeline: timeline,
      count: 0
    }}
  end

  @impl true
  def handle_call({:record, audit}, _from, state) do
    ts = audit.completed_at || audit.started_at || DateTime.utc_now()

    # Main record
    :ets.insert(state.audits, {audit.id, audit})

    # Index by trader
    if audit.trader_id do
      :ets.insert(state.by_trader, {{audit.trader_id, ts}, audit.id})
    end

    # Index by trigger for auto-runner
    if audit.trigger == :auto_runner do
      :ets.insert(state.by_trader, {{"__auto_runner__", ts}, audit.id})
    end

    # Index by each contract used
    for contract <- (audit.contracts_used || []) do
      :ets.insert(state.by_contract, {{contract.id, ts}, audit.id})
    end

    # Timeline index by product group
    :ets.insert(state.timeline, {{audit.product_group, ts}, audit.id})

    new_count = state.count + 1

    if rem(new_count, 100) == 0 do
      Logger.info("SolveAudit: #{new_count} records stored")
    end

    {:reply, {:ok, audit}, %{state | count: new_count}}
  end

  @impl true
  def handle_call({:get, audit_id}, _from, state) do
    case :ets.lookup(state.audits, audit_id) do
      [{^audit_id, audit}] -> {:reply, {:ok, audit}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list_recent, limit}, _from, state) do
    # Get all from timeline (ordered by {product_group, timestamp}),
    # sort by timestamp descending, take limit
    audits =
      :ets.tab2list(state.timeline)
      |> Enum.sort_by(fn {{_pg, ts}, _id} -> ts end, {:desc, DateTime})
      |> Enum.take(limit)
      |> Enum.map(fn {_key, id} -> lookup_audit(state.audits, id) end)
      |> Enum.reject(&is_nil/1)

    {:reply, audits, state}
  end

  @impl true
  def handle_call({:find_by_contract, contract_id, _opts}, _from, state) do
    audits =
      :ets.match_object(state.by_contract, {{contract_id, :_}, :_})
      |> Enum.sort_by(fn {{_, ts}, _} -> ts end, {:asc, DateTime})
      |> Enum.map(fn {_key, id} -> lookup_audit(state.audits, id) end)
      |> Enum.reject(&is_nil/1)

    {:reply, audits, state}
  end

  @impl true
  def handle_call({:find_by_trader, trader_id, _opts}, _from, state) do
    audits =
      :ets.match_object(state.by_trader, {{trader_id, :_}, :_})
      |> Enum.sort_by(fn {{_, ts}, _} -> ts end, {:asc, DateTime})
      |> Enum.map(fn {_key, id} -> lookup_audit(state.audits, id) end)
      |> Enum.reject(&is_nil/1)

    {:reply, audits, state}
  end

  @impl true
  def handle_call({:find_by_time_range, product_group, from, to}, _from, state) do
    audits =
      :ets.match_object(state.timeline, {{product_group, :_}, :_})
      |> Enum.filter(fn {{_, ts}, _} ->
        DateTime.compare(ts, from) != :lt and DateTime.compare(ts, to) != :gt
      end)
      |> Enum.sort_by(fn {{_, ts}, _} -> ts end, {:asc, DateTime})
      |> Enum.map(fn {_key, id} -> lookup_audit(state.audits, id) end)
      |> Enum.reject(&is_nil/1)

    {:reply, audits, state}
  end

  @impl true
  def handle_call({:trader_decision_chain, trader_id, _opts}, _from, state) do
    audits =
      :ets.match_object(state.by_trader, {{trader_id, :_}, :_})
      |> Enum.sort_by(fn {{_, ts}, _} -> ts end, {:asc, DateTime})
      |> Enum.map(fn {_key, id} -> lookup_audit(state.audits, id) end)
      |> Enum.reject(&is_nil/1)

    chain = build_decision_chain(audits)
    {:reply, chain, state}
  end

  @impl true
  def handle_call({:product_group_timeline, product_group, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 200)

    entries =
      :ets.match_object(state.timeline, {{product_group, :_}, :_})
      |> Enum.sort_by(fn {{_, ts}, _} -> ts end, {:desc, DateTime})
      |> Enum.take(limit)
      |> Enum.map(fn {_key, id} -> lookup_audit(state.audits, id) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reverse()
      |> Enum.map(&build_timeline_entry/1)

    {:reply, entries, state}
  end

  @impl true
  def handle_call({:compare_paths, product_group, opts}, _from, state) do
    hours = Keyword.get(opts, :hours, 24)
    now = DateTime.utc_now()
    from = DateTime.add(now, -hours * 3600, :second)

    all_audits =
      :ets.match_object(state.timeline, {{product_group, :_}, :_})
      |> Enum.filter(fn {{_, ts}, _} -> DateTime.compare(ts, from) != :lt end)
      |> Enum.sort_by(fn {{_, ts}, _} -> ts end, {:asc, DateTime})
      |> Enum.map(fn {_key, id} -> lookup_audit(state.audits, id) end)
      |> Enum.reject(&is_nil/1)

    comparison = build_path_comparison(all_audits, from, now)
    {:reply, comparison, state}
  end

  @impl true
  def handle_call({:performance_summary, opts}, _from, state) do
    product_group = Keyword.get(opts, :product_group)
    trader_id = Keyword.get(opts, :trader_id)
    hours = Keyword.get(opts, :hours, 168)  # default 1 week

    now = DateTime.utc_now()
    from = DateTime.add(now, -hours * 3600, :second)

    audits = filter_audits(state, product_group, trader_id, from, now)
    summary = build_performance_summary(audits, product_group, trader_id, from, now)
    {:reply, summary, state}
  end

  # ──────────────────────────────────────────────────────────
  # DECISION CHAIN (DAG-READY)
  # ──────────────────────────────────────────────────────────

  defp build_decision_chain(audits) do
    audits
    |> Enum.with_index()
    |> Enum.map(fn {audit, idx} ->
      prev = if idx > 0, do: Enum.at(audits, idx - 1)

      %{
        audit: audit,
        index: idx,
        contracts_changed_from_prev: contracts_diff(prev, audit),
        variables_delta: variables_diff(prev, audit),
        time_since_prev: time_diff(prev, audit),
        decision_type: classify_decision(prev, audit)
      }
    end)
  end

  defp contracts_diff(nil, _current), do: []
  defp contracts_diff(prev, current) do
    prev_set = Map.new(prev.contracts_used || [], fn c -> {c.id, c} end)
    curr_set = Map.new(current.contracts_used || [], fn c -> {c.id, c} end)

    changes = []

    # New contracts not in previous solve
    added =
      Enum.filter(current.contracts_used || [], fn c -> not Map.has_key?(prev_set, c.id) end)
      |> Enum.map(fn c -> %{type: :added, contract: c} end)

    # Removed contracts
    removed =
      Enum.filter(prev.contracts_used || [], fn c -> not Map.has_key?(curr_set, c.id) end)
      |> Enum.map(fn c -> %{type: :removed, contract: c} end)

    # Version changes (same counterparty, different version)
    prev_by_cp = Map.new(prev.contracts_used || [], fn c -> {c.counterparty, c} end)
    version_changes =
      (current.contracts_used || [])
      |> Enum.filter(fn c ->
        case Map.get(prev_by_cp, c.counterparty) do
          nil -> false
          prev_c -> prev_c.version != c.version
        end
      end)
      |> Enum.map(fn c ->
        prev_c = prev_by_cp[c.counterparty]
        %{type: :version_changed, contract: c, from_version: prev_c.version, to_version: c.version}
      end)

    changes ++ added ++ removed ++ version_changes
  end

  defp variables_diff(nil, _current), do: %{}
  defp variables_diff(prev, current) do
    prev_vars = prev.variables || %{}
    curr_vars = current.variables || %{}

    AmmoniaDesk.Variables.metadata()
    |> Enum.reduce(%{}, fn meta, acc ->
      key = meta.key
      prev_val = Map.get(prev_vars, key)
      curr_val = Map.get(curr_vars, key)

      if prev_val != nil and curr_val != nil and prev_val != curr_val do
        Map.put(acc, key, %{
          from: prev_val,
          to: curr_val,
          delta: if(is_number(prev_val) and is_number(curr_val), do: curr_val - prev_val, else: nil),
          source: meta.source
        })
      else
        acc
      end
    end)
  end

  defp time_diff(nil, _current), do: nil
  defp time_diff(prev, current) do
    prev_ts = prev.completed_at || prev.started_at
    curr_ts = current.started_at

    if prev_ts && curr_ts do
      DateTime.diff(curr_ts, prev_ts, :second)
    end
  end

  defp classify_decision(nil, _current), do: :initial
  defp classify_decision(prev, current) do
    contract_changes = contracts_diff(prev, current)
    var_deltas = variables_diff(prev, current)

    cond do
      length(contract_changes) > 0 -> :contract_update
      map_size(var_deltas) > 0 -> :variable_change
      true -> :recheck
    end
  end

  # ──────────────────────────────────────────────────────────
  # TIMELINE ENTRY (MANAGEMENT VIEW)
  # ──────────────────────────────────────────────────────────

  defp build_timeline_entry(audit) do
    # Compact contract state identifier
    contracts_version_set =
      (audit.contracts_used || [])
      |> Enum.sort_by(& &1.counterparty)
      |> Enum.map(fn c -> "v#{c.version}-#{c.counterparty}" end)
      |> Enum.join("/")

    profit_or_signal =
      case audit.mode do
        :solve ->
          if audit.result, do: Map.get(audit.result, :profit, nil), else: nil
        :monte_carlo ->
          if audit.result, do: Map.get(audit.result, :signal, nil), else: nil
      end

    %{
      audit: audit,
      source: if(audit.trigger == :auto_runner, do: :auto_runner, else: :trader),
      trader_id: audit.trader_id,
      profit_or_signal: profit_or_signal,
      contracts_version_set: contracts_version_set,
      at: audit.completed_at || audit.started_at
    }
  end

  # ──────────────────────────────────────────────────────────
  # PATH COMPARISON (AUTO-RUNNER VS TRADER)
  # ──────────────────────────────────────────────────────────

  defp build_path_comparison(audits, from, to) do
    {auto_audits, trader_audits} =
      Enum.split_with(audits, fn a -> a.trigger == :auto_runner end)

    auto_signals =
      Enum.map(auto_audits, fn a ->
        %{
          at: a.completed_at || a.started_at,
          signal: extract_signal(a),
          profit_mean: extract_profit_mean(a),
          audit_id: a.id
        }
      end)

    trader_solves =
      Enum.map(trader_audits, fn a ->
        %{
          at: a.completed_at || a.started_at,
          mode: a.mode,
          profit: extract_profit(a),
          trader_id: a.trader_id,
          audit_id: a.id
        }
      end)

    %{
      period: {from, to},
      auto_signals: auto_signals,
      trader_solves: trader_solves,
      total_auto: length(auto_signals),
      total_trader: length(trader_solves),
      alignment_score: compute_alignment(auto_signals, trader_solves)
    }
  end

  defp extract_signal(%{result: result}) when is_map(result), do: Map.get(result, :signal)
  defp extract_signal(_), do: nil

  defp extract_profit_mean(%{result: result}) when is_map(result), do: Map.get(result, :mean)
  defp extract_profit_mean(_), do: nil

  defp extract_profit(%{result: result}) when is_map(result), do: Map.get(result, :profit)
  defp extract_profit(_), do: nil

  defp compute_alignment([], _trader), do: 0.0
  defp compute_alignment(_auto, []), do: 0.0
  defp compute_alignment(auto_signals, trader_solves) do
    # Simple alignment: what fraction of :strong_go / :go signals
    # were followed by a trader solve within 30 minutes?
    go_signals = Enum.filter(auto_signals, fn s -> s.signal in [:strong_go, :go] end)

    if length(go_signals) == 0 do
      1.0  # no actionable signals = fully aligned (nothing to do)
    else
      followed =
        Enum.count(go_signals, fn signal ->
          Enum.any?(trader_solves, fn solve ->
            diff = DateTime.diff(solve.at, signal.at, :second)
            diff >= 0 and diff <= 1800  # within 30 minutes
          end)
        end)

      followed / length(go_signals)
    end
  end

  # ──────────────────────────────────────────────────────────
  # PERFORMANCE SUMMARY
  # ──────────────────────────────────────────────────────────

  defp filter_audits(state, product_group, trader_id, from, _to) do
    source =
      cond do
        product_group && trader_id ->
          :ets.match_object(state.by_trader, {{trader_id, :_}, :_})
          |> Enum.map(fn {_key, id} -> lookup_audit(state.audits, id) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(fn a -> a.product_group == product_group end)

        product_group ->
          :ets.match_object(state.timeline, {{product_group, :_}, :_})
          |> Enum.map(fn {_key, id} -> lookup_audit(state.audits, id) end)
          |> Enum.reject(&is_nil/1)

        trader_id ->
          :ets.match_object(state.by_trader, {{trader_id, :_}, :_})
          |> Enum.map(fn {_key, id} -> lookup_audit(state.audits, id) end)
          |> Enum.reject(&is_nil/1)

        true ->
          :ets.tab2list(state.audits)
          |> Enum.map(fn {_id, audit} -> audit end)
      end

    Enum.filter(source, fn a ->
      ts = a.completed_at || a.started_at
      ts && DateTime.compare(ts, from) != :lt
    end)
  end

  defp build_performance_summary(audits, product_group, trader_id, from, to) do
    solves = Enum.filter(audits, fn a -> a.mode == :solve end)
    monte_carlos = Enum.filter(audits, fn a -> a.mode == :monte_carlo end)

    solve_profits =
      solves
      |> Enum.map(&extract_profit/1)
      |> Enum.reject(&is_nil/1)

    mc_signals =
      monte_carlos
      |> Enum.map(&extract_signal/1)
      |> Enum.reject(&is_nil/1)

    contract_versions_seen =
      audits
      |> Enum.flat_map(fn a -> a.contracts_used || [] end)
      |> Enum.uniq_by(fn c -> {c.id, c.version} end)

    %{
      period: {from, to},
      product_group: product_group,
      trader_id: trader_id,
      total_solves: length(solves),
      total_monte_carlos: length(monte_carlos),
      solve_profit_stats: compute_stats(solve_profits),
      signal_distribution: Enum.frequencies(mc_signals),
      contract_versions_used: length(contract_versions_seen),
      unique_counterparties: contract_versions_seen |> Enum.map(& &1.counterparty) |> Enum.uniq() |> length(),
      contracts_updated_during_solves: Enum.count(audits, fn a -> (a.contracts_ingested || 0) > 0 end),
      stale_data_solves: Enum.count(audits, fn a -> a.contracts_stale end)
    }
  end

  defp compute_stats([]), do: %{count: 0}
  defp compute_stats(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    sum = Enum.sum(sorted)
    mean = sum / n

    %{
      count: n,
      total: sum,
      mean: mean,
      min: List.first(sorted),
      max: List.last(sorted),
      p25: Enum.at(sorted, div(n, 4)),
      p50: Enum.at(sorted, div(n, 2)),
      p75: Enum.at(sorted, div(3 * n, 4))
    }
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp lookup_audit(table, id) do
    case :ets.lookup(table, id) do
      [{^id, audit}] -> audit
      [] -> nil
    end
  end
end
