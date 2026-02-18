defmodule TradingDesk.ScenarioLive do
  @moduledoc """
  Interactive scenario desk for commodity traders.

  Supports all product groups (ammonia domestic, sulphur international,
  petcoke, ammonia international, etc.) with frame-driven UI that
  dynamically renders variables, routes, and constraints from the
  ProductGroup registry.

  Two modes:
    - SOLVE: tweak variables, get instant result
    - MONTE CARLO: run N scenarios around current values

  Two tabs:
    - TRADER: Manual scenario exploration with solve and Monte Carlo
    - AGENT: Automated agent monitoring with delta-based triggering
  """
  use Phoenix.LiveView
  require Logger

  alias TradingDesk.Variables
  alias TradingDesk.Solver.Port, as: Solver
  alias TradingDesk.Solver.Pipeline
  alias TradingDesk.Data.LiveState
  alias TradingDesk.Scenarios.Store
  alias TradingDesk.ProductGroup

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "live_data")
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "auto_runner")
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "solve_pipeline")
    end

    product_group = :ammonia_domestic

    # Defensive: GenServer calls may fail if services haven't started yet
    live_vars = safe_call(fn -> LiveState.get() end, ProductGroup.default_values(product_group))
    auto_result = safe_call(fn -> TradingDesk.Scenarios.AutoRunner.latest() end, nil)
    vessel_data = safe_call(fn -> LiveState.get_supplementary(:vessel_tracking) end, nil)
    tides_data = safe_call(fn -> LiveState.get_supplementary(:tides) end, nil)
    saved = safe_call(fn -> Store.list("trader_1") end, [])

    # Load frame-driven metadata (pure functions — safe)
    frame = ProductGroup.frame(product_group)
    metadata = ProductGroup.variable_metadata(product_group)
    route_names = ProductGroup.route_names(product_group)
    constraint_names = ProductGroup.constraint_names(product_group)
    variable_groups = TradingDesk.VariablesDynamic.groups(product_group)
    available_groups = ProductGroup.list_with_info()

    # Ensure current_vars is always a plain map
    default_vars = ProductGroup.default_values(product_group)
    current_vars = if is_map(live_vars), do: live_vars, else: default_vars

    socket =
      socket
      |> assign(:product_group, product_group)
      |> assign(:frame, frame)
      |> assign(:live_vars, current_vars)
      |> assign(:current_vars, current_vars)
      |> assign(:overrides, MapSet.new())
      |> assign(:result, nil)
      |> assign(:distribution, nil)
      |> assign(:auto_result, auto_result)
      |> assign(:saved_scenarios, saved)
      |> assign(:trader_id, "trader_1")
      |> assign(:metadata, metadata)
      |> assign(:route_names, route_names)
      |> assign(:constraint_names, constraint_names)
      |> assign(:variable_groups, variable_groups)
      |> assign(:available_groups, available_groups)
      |> assign(:solving, false)
      |> assign(:active_tab, :trader)
      |> assign(:objective_mode, :max_profit)
      |> assign(:agent_history, [])
      |> assign(:explanation, nil)
      |> assign(:explaining, false)
      |> assign(:pipeline_phase, nil)
      |> assign(:pipeline_detail, nil)
      |> assign(:contracts_stale, false)
      |> assign(:vessel_data, vessel_data)
      |> assign(:tides_data, tides_data)
      # Trader intent + pre-solve review
      |> assign(:trader_action, "")
      |> assign(:intent, nil)
      |> assign(:intent_loading, false)
      |> assign(:show_review, false)
      |> assign(:review_mode, nil)
      |> assign(:sap_positions, nil)
      |> assign(:post_solve_impact, nil)
      |> assign(:ammonia_prices, TradingDesk.Data.AmmoniaPrices.price_summary())
      |> assign(:contracts_data, load_contracts_data())

    {:ok, socket}
  end

  @impl true
  def handle_event("solve", _params, socket) do
    # Show pre-solve review popup instead of solving immediately
    book = TradingDesk.Contracts.SapPositions.book_summary()
    socket =
      socket
      |> assign(:show_review, true)
      |> assign(:review_mode, :solve)
      |> assign(:sap_positions, book)
    # If trader has typed an action, parse intent in background
    socket = maybe_parse_intent(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("monte_carlo", _params, socket) do
    book = TradingDesk.Contracts.SapPositions.book_summary()
    socket =
      socket
      |> assign(:show_review, true)
      |> assign(:review_mode, :monte_carlo)
      |> assign(:sap_positions, book)
    socket = maybe_parse_intent(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_action", %{"action" => text}, socket) do
    {:noreply, assign(socket, :trader_action, text)}
  end

  @impl true
  def handle_event("confirm_solve", _params, socket) do
    # Apply intent variable adjustments if any, then solve
    vars = apply_intent_adjustments(socket.assigns.current_vars, socket.assigns.intent)
    mode = socket.assigns.review_mode

    socket =
      socket
      |> assign(:current_vars, vars)
      |> assign(:show_review, false)
      |> assign(:solving, true)
      |> assign(:pipeline_phase, :checking_contracts)
      |> assign(:pipeline_detail, nil)
      |> assign(:contracts_stale, false)
      |> assign(:post_solve_impact, nil)

    case mode do
      :monte_carlo -> send(self(), :do_monte_carlo)
      _ -> send(self(), :do_solve)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_review", _params, socket) do
    socket =
      socket
      |> assign(:show_review, false)
      |> assign(:review_mode, nil)
      |> assign(:intent, nil)
    {:noreply, socket}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    pg = socket.assigns.product_group
    live = safe_call(fn -> LiveState.get() end, ProductGroup.default_values(pg))
    live = if is_map(live), do: live, else: ProductGroup.default_values(pg)
    socket =
      socket
      |> assign(:current_vars, live)
      |> assign(:live_vars, live)
      |> assign(:overrides, MapSet.new())
      |> assign(:result, nil)
      |> assign(:distribution, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_var", %{"key" => key, "value" => value}, socket) do
    key_atom = String.to_existing_atom(key)
    parsed = parse_value(key_atom, value)

    new_vars = Map.put(socket.assigns.current_vars, key_atom, parsed)
    new_overrides = MapSet.put(socket.assigns.overrides, key_atom)

    socket =
      socket
      |> assign(:current_vars, new_vars)
      |> assign(:overrides, new_overrides)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_override", %{"key" => key}, socket) do
    key_atom = String.to_existing_atom(key)

    {new_vars, new_overrides} =
      if MapSet.member?(socket.assigns.overrides, key_atom) do
        # Reset to live value
        live_val = Map.get(socket.assigns.live_vars, key_atom)
        {Map.put(socket.assigns.current_vars, key_atom, live_val),
         MapSet.delete(socket.assigns.overrides, key_atom)}
      else
        # Mark as overridden (keep current value)
        {socket.assigns.current_vars,
         MapSet.put(socket.assigns.overrides, key_atom)}
      end

    socket =
      socket
      |> assign(:current_vars, new_vars)
      |> assign(:overrides, new_overrides)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_bool", %{"key" => key}, socket) do
    key_atom = String.to_existing_atom(key)
    current = Map.get(socket.assigns.current_vars, key_atom)
    new_vars = Map.put(socket.assigns.current_vars, key_atom, !current)
    new_overrides = MapSet.put(socket.assigns.overrides, key_atom)

    socket =
      socket
      |> assign(:current_vars, new_vars)
      |> assign(:overrides, new_overrides)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_scenario", %{"name" => name}, socket) do
    case socket.assigns.result do
      nil -> {:noreply, socket}
      result ->
        {:ok, _} = Store.save(
          socket.assigns.trader_id,
          name,
          socket.assigns.current_vars,
          result
        )
        scenarios = Store.list(socket.assigns.trader_id)
        {:noreply, assign(socket, :saved_scenarios, scenarios)}
    end
  end

  @impl true
  def handle_event("load_scenario", %{"id" => id}, socket) do
    id = String.to_integer(id)
    case Enum.find(socket.assigns.saved_scenarios, &(&1.id == id)) do
      nil -> {:noreply, socket}
      scenario ->
        socket =
          socket
          |> assign(:current_vars, scenario.variables)
          |> assign(:result, scenario.result)
          |> assign(:overrides, MapSet.new(Map.keys(scenario.variables)))

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_product_group", %{"group" => group}, socket) do
    pg = String.to_existing_atom(group)
    frame = ProductGroup.frame(pg)

    if frame do
      metadata = ProductGroup.variable_metadata(pg)
      route_names = ProductGroup.route_names(pg)
      constraint_names = ProductGroup.constraint_names(pg)
      variable_groups = TradingDesk.VariablesDynamic.groups(pg)
      default_vars = ProductGroup.default_values(pg)

      socket =
        socket
        |> assign(:product_group, pg)
        |> assign(:frame, frame)
        |> assign(:metadata, metadata)
        |> assign(:route_names, route_names)
        |> assign(:constraint_names, constraint_names)
        |> assign(:variable_groups, variable_groups)
        |> assign(:current_vars, default_vars)
        |> assign(:live_vars, default_vars)
        |> assign(:overrides, MapSet.new())
        |> assign(:result, nil)
        |> assign(:distribution, nil)
        |> assign(:explanation, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_objective", %{"objective" => obj}, socket) do
    objective = String.to_existing_atom(obj)
    {:noreply, assign(socket, :objective_mode, objective)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)
    socket = assign(socket, :active_tab, tab_atom)

    # Fetch agent history when switching to agent tab
    socket =
      if tab_atom == :agent do
        history = TradingDesk.Scenarios.AutoRunner.history()
        assign(socket, :agent_history, history)
      else
        socket
      end

    {:noreply, socket}
  end

  # --- Async solve handlers ---

  @impl true
  def handle_info(:do_solve, socket) do
    vars = socket.assigns.current_vars
    pg = socket.assigns.product_group
    obj = socket.assigns.objective_mode
    solver_opts = [objective: obj]
    Pipeline.solve_async(vars, product_group: pg, caller_ref: :trader_solve, solver_opts: solver_opts)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:do_monte_carlo, socket) do
    vars = socket.assigns.current_vars
    pg = socket.assigns.product_group
    obj = socket.assigns.objective_mode
    solver_opts = [objective: obj]
    Pipeline.monte_carlo_async(vars, product_group: pg, caller_ref: :trader_mc, solver_opts: solver_opts)
    {:noreply, socket}
  end

  # --- Pipeline phase events ---

  @impl true
  def handle_info({:pipeline_event, :pipeline_started, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :checking_contracts)}
  end

  def handle_info({:pipeline_event, :pipeline_contracts_ok, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :solving, pipeline_detail: nil)}
  end

  def handle_info({:pipeline_event, :pipeline_ingesting, %{changed: n, caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :ingesting, pipeline_detail: "#{n} contract#{if n != 1, do: "s", else: ""} changed — Copilot ingesting")}
  end

  def handle_info({:pipeline_event, :pipeline_ingest_done, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :solving, pipeline_detail: nil)}
  end

  def handle_info({:pipeline_event, :pipeline_contracts_stale, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :solving, contracts_stale: true)}
  end

  def handle_info({:pipeline_event, :pipeline_solving, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :solving)}
  end

  def handle_info({:pipeline_event, :pipeline_solve_done, %{mode: :solve, result: result, caller_ref: :trader_solve} = payload}, socket) do
    contracts_stale = Map.get(payload, :contracts_stale, false) or socket.assigns.contracts_stale
    socket = assign(socket,
      result: result,
      solving: false,
      pipeline_phase: nil,
      pipeline_detail: nil,
      contracts_stale: contracts_stale,
      explanation: nil,
      explaining: true
    )
    vars = socket.assigns.current_vars
    intent = socket.assigns.intent
    trader_action = socket.assigns.trader_action
    lv_pid = self()

    # Spawn explanation + post-solve impact analysis
    spawn(fn ->
      try do
        case TradingDesk.Analyst.explain_solve_with_impact(vars, result, intent, trader_action) do
          {:ok, text, impact} ->
            send(lv_pid, {:explanation_result, text})
            send(lv_pid, {:post_solve_impact, impact})
          {:ok, text} ->
            send(lv_pid, {:explanation_result, text})
          {:error, reason} ->
            Logger.warning("Analyst explain_solve failed: #{inspect(reason)}")
            send(lv_pid, {:explanation_result, {:error, reason}})
        end
      catch
        kind, reason ->
          Logger.error("Analyst explain_solve crashed: #{kind} #{inspect(reason)}")
          send(lv_pid, {:explanation_result, {:error, "#{kind}: #{inspect(reason)}"}})
      end
    end)
    {:noreply, socket}
  end

  def handle_info({:pipeline_event, :pipeline_solve_done, %{mode: :monte_carlo, result: dist, caller_ref: :trader_mc} = payload}, socket) do
    contracts_stale = Map.get(payload, :contracts_stale, false) or socket.assigns.contracts_stale
    socket = assign(socket,
      distribution: dist,
      solving: false,
      pipeline_phase: nil,
      pipeline_detail: nil,
      contracts_stale: contracts_stale,
      explanation: nil,
      explaining: true
    )
    vars = socket.assigns.current_vars
    lv_pid = self()
    spawn(fn ->
      try do
        case TradingDesk.Analyst.explain_distribution(vars, dist) do
          {:ok, text} -> send(lv_pid, {:explanation_result, text})
          {:error, reason} ->
            Logger.warning("Analyst explain_distribution failed: #{inspect(reason)}")
            send(lv_pid, {:explanation_result, {:error, reason}})
        end
      catch
        kind, reason ->
          Logger.error("Analyst explain_distribution crashed: #{kind} #{inspect(reason)}")
          send(lv_pid, {:explanation_result, {:error, "#{kind}: #{inspect(reason)}"}})
      end
    end)
    {:noreply, socket}
  end

  def handle_info({:pipeline_event, :pipeline_error, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, solving: false, pipeline_phase: nil, pipeline_detail: nil)}
  end

  # Catch-all for pipeline events not relevant to this LV (e.g. AutoRunner's)
  def handle_info({:pipeline_event, _, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:data_updated, _source}, socket) do
    pg = socket.assigns.product_group
    live = LiveState.get()

    # Only merge live data for ammonia_domestic (which uses the Variables struct).
    # Other product groups use frame defaults and manual overrides.
    if pg == :ammonia_domestic do
      overrides = socket.assigns.overrides
      current = socket.assigns.current_vars
      valid_keys = MapSet.new(ProductGroup.variable_keys(pg))

      updated_current =
        Enum.reduce(Map.from_struct(live), current, fn {key, val}, acc ->
          if MapSet.member?(overrides, key) or not MapSet.member?(valid_keys, key) do
            acc
          else
            Map.put(acc, key, val)
          end
        end)

      {:noreply, assign(socket, live_vars: live, current_vars: updated_current)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:supplementary_updated, :vessel_tracking}, socket) do
    vessel_data = LiveState.get_supplementary(:vessel_tracking)
    {:noreply, assign(socket, :vessel_data, vessel_data)}
  end

  @impl true
  def handle_info({:supplementary_updated, :tides}, socket) do
    tides_data = LiveState.get_supplementary(:tides)
    {:noreply, assign(socket, :tides_data, tides_data)}
  end

  @impl true
  def handle_info({:supplementary_updated, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:auto_result, result}, socket) do
    history = TradingDesk.Scenarios.AutoRunner.history()
    socket =
      socket
      |> assign(:auto_result, result)
      |> assign(:agent_history, history)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:intent_result, intent}, socket) do
    {:noreply, assign(socket, intent: intent, intent_loading: false)}
  end

  @impl true
  def handle_info({:post_solve_impact, impact}, socket) do
    {:noreply, assign(socket, post_solve_impact: impact)}
  end

  @impl true
  def handle_info({:explanation_result, {:error, reason}}, socket) do
    error_text = analyst_error_text(reason)
    {:noreply, assign(socket, explanation: {:error, error_text}, explaining: false)}
  end

  def handle_info({:explanation_result, text}, socket) do
    {:noreply, assign(socket, explanation: text, explaining: false)}
  end

  @impl true
  def handle_info({:auto_explanation, text}, socket) do
    auto_result =
      if socket.assigns.auto_result do
        Map.put(socket.assigns.auto_result, :explanation, text)
      else
        nil
      end
    {:noreply, assign(socket, :auto_result, auto_result)}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div style="background:#080c14;color:#c8d6e5;min-height:100vh;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',monospace">
      <%!-- === TOP BAR === --%>
      <div style="background:#0d1117;border-bottom:1px solid #1b2838;padding:10px 20px;display:flex;justify-content:space-between;align-items:center">
        <div style="display:flex;align-items:center;gap:12px">
          <div style={"width:8px;height:8px;border-radius:50%;background:#{if @auto_result, do: "#10b981", else: "#64748b"};box-shadow:0 0 8px #{if @auto_result, do: "#10b981", else: "transparent"}"}></div>
          <span style="font-size:14px;font-weight:700;color:#e2e8f0;letter-spacing:1px"><%= (@frame && @frame[:name]) || "SCENARIO DESK" %></span>
          <select phx-change="switch_product_group" name="group"
            style="background:#111827;border:1px solid #1e293b;color:#94a3b8;padding:3px 8px;border-radius:4px;font-size:10px;font-weight:600;cursor:pointer">
            <%= for pg <- @available_groups do %>
              <option value={pg.id} selected={pg.id == @product_group}><%= pg.name %></option>
            <% end %>
          </select>
          <a href="/contracts" style="color:#a78bfa;text-decoration:none;font-size:11px;font-weight:600;padding:4px 10px;border:1px solid #1e293b;border-radius:4px">CONTRACTS</a>
        </div>
        <div style="display:flex;align-items:center;gap:12px;font-size:11px">
          <%!-- Ammonia Prices Ticker --%>
          <div style="display:flex;align-items:center;gap:8px;padding-right:12px;border-right:1px solid #1b2838">
            <%= for p <- Enum.take(@ammonia_prices, 4) do %>
              <span style="color:#475569"><%= p.label %></span>
              <span style={"color:#{if p.direction == :buy, do: "#60a5fa", else: "#f59e0b"};font-weight:700;font-family:monospace"}>$<%= round(p.price) %></span>
            <% end %>
          </div>
          <%= if @auto_result do %>
            <span style="color:#64748b">AUTO</span>
            <span style={"background:#0f2a1f;color:#{signal_color(@auto_result.distribution.signal)};padding:3px 10px;border-radius:4px;font-weight:700;font-size:11px"}><%= signal_text(@auto_result.distribution.signal) %></span>
            <span style="color:#64748b">E[V]</span>
            <span style="color:#10b981;font-weight:700;font-family:monospace">$<%= format_number(@auto_result.distribution.mean) %></span>
            <span style="color:#64748b">VaR₅</span>
            <span style="color:#f59e0b;font-weight:700;font-family:monospace">$<%= format_number(@auto_result.distribution.p5) %></span>
          <% else %>
            <span style="color:#475569">AUTO: waiting...</span>
          <% end %>
        </div>
      </div>

      <div style="display:grid;grid-template-columns:400px 1fr;height:calc(100vh - 45px)">
        <%!-- === LEFT: VARIABLES === --%>
        <div style="background:#0a0f18;border-right:1px solid #1b2838;overflow-y:auto;padding:14px">
          <%= for group <- @variable_groups do %>
            <div style="margin-bottom:14px">
              <div style="display:flex;justify-content:space-between;margin-bottom:8px;padding-bottom:6px;border-bottom:1px solid #1b283833">
                <span style={"font-size:11px;font-weight:700;color:#{group_color(group)};letter-spacing:1.2px;text-transform:uppercase"}>
                  <%= group_icon(group) %> <%= to_string(group) %>
                </span>
              </div>
              <%= for meta <- Enum.filter(@metadata, & &1.group == group) do %>
                <div style={"display:grid;grid-template-columns:130px 1fr 68px 24px;align-items:center;gap:6px;padding:4px 6px;border-radius:4px;margin-bottom:1px;border-left:2px solid #{if MapSet.member?(@overrides, meta.key), do: "#f59e0b", else: "transparent"};background:#{if MapSet.member?(@overrides, meta.key), do: "#111827", else: "transparent"}"}>
                  <span style="font-size:11px;color:#8899aa;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= meta.label %></span>
                  <%= if Map.get(meta, :type) == :boolean do %>
                    <button phx-click="toggle_bool" phx-value-key={meta.key}
                      style={"padding:2px 0;border:1px solid #{if Map.get(@current_vars, meta.key), do: "#991b1b", else: "#1e3a5f"};border-radius:3px;background:#{if Map.get(@current_vars, meta.key), do: "#7f1d1d", else: "#0f2a3d"};color:#{if Map.get(@current_vars, meta.key), do: "#fca5a5", else: "#67e8f9"};font-weight:700;font-size:10px;cursor:pointer;letter-spacing:1px"}>
                      <%= if Map.get(@current_vars, meta.key), do: "⬤ OUTAGE", else: "◯ ONLINE" %>
                    </button>
                  <% else %>
                    <input type="range" min={meta.min} max={meta.max} step={meta.step}
                      value={Map.get(@current_vars, meta.key)}
                      phx-hook="Slider" id={"slider-#{meta.key}"} data-key={meta.key}
                      style={"width:100%;accent-color:#{if MapSet.member?(@overrides, meta.key), do: "#f59e0b", else: group_color(group)};height:3px;cursor:pointer"} />
                  <% end %>
                  <span style={"font-size:11px;font-family:monospace;text-align:right;color:#{if MapSet.member?(@overrides, meta.key), do: "#f59e0b", else: group_color(group)};font-weight:600"}>
                    <%= if Map.get(meta, :type) != :boolean, do: format_var(meta, Map.get(@current_vars, meta.key)), else: "" %>
                  </span>
                  <button phx-click="toggle_override" phx-value-key={meta.key}
                    style={"background:none;border:none;cursor:pointer;font-size:12px;padding:0;opacity:#{if MapSet.member?(@overrides, meta.key), do: "0.9", else: "0.4"}"}>
                    <%= if MapSet.member?(@overrides, meta.key), do: "⚡", else: "📡" %>
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>

          <div style="border-top:1px solid #1b2838;padding-top:12px;margin-top:8px">
            <%!-- Trader Action Input --%>
            <div style="margin-bottom:10px">
              <div style="font-size:10px;color:#a78bfa;letter-spacing:0.8px;margin-bottom:4px">TRADER ACTION</div>
              <textarea phx-blur="update_action" name="action"
                placeholder="Describe what you want to test... e.g. 'Redirect March Yuzhnyy cargo to India' or 'Simulate river drop to 15ft'"
                style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:8px;border-radius:6px;font-size:11px;font-family:inherit;resize:vertical;min-height:48px;max-height:120px"><%= @trader_action %></textarea>
            </div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
              <button phx-click="solve" disabled={@solving}
                style="padding:10px;border:none;border-radius:6px;font-weight:700;font-size:12px;background:linear-gradient(135deg,#0891b2,#06b6d4);color:#fff;cursor:pointer;letter-spacing:1px">
                <%= pipeline_button_text(@solving, @pipeline_phase, "SOLVE") %>
              </button>
              <button phx-click="monte_carlo" disabled={@solving}
                style="padding:10px;border:none;border-radius:6px;font-weight:700;font-size:12px;background:linear-gradient(135deg,#7c3aed,#8b5cf6);color:#fff;cursor:pointer;letter-spacing:1px">
                <%= pipeline_button_text(@solving, @pipeline_phase, "MONTE CARLO") %>
              </button>
            </div>
            <div style="margin-top:8px">
              <div style="font-size:10px;color:#64748b;letter-spacing:0.8px;margin-bottom:4px">OBJECTIVE</div>
              <select phx-change="switch_objective" name="objective"
                style="width:100%;background:#111827;border:1px solid #1e293b;color:#94a3b8;padding:6px 8px;border-radius:4px;font-size:11px;font-weight:600;cursor:pointer">
                <%= for {val, label} <- [max_profit: "Maximize Profit", min_cost: "Minimize Cost", max_roi: "Maximize ROI", cvar_adjusted: "CVaR-Adjusted", min_risk: "Minimize Risk"] do %>
                  <option value={val} selected={val == @objective_mode}><%= label %></option>
                <% end %>
              </select>
            </div>
            <button phx-click="reset"
              style="width:100%;padding:7px;border:1px solid #1e293b;border-radius:6px;font-weight:600;font-size:11px;background:transparent;color:#64748b;cursor:pointer;margin-top:8px">
              📡 RESET TO LIVE
            </button>
            <div style="text-align:center;margin-top:6px;font-size:10px;color:#334155">
              <%= MapSet.size(@overrides) %> override<%= if MapSet.size(@overrides) != 1, do: "s", else: "" %> active
            </div>
          </div>

          <%!-- === FLEET & TIDES COMPACT === --%>
          <%= if @vessel_data || @tides_data do %>
            <div style="border-top:1px solid #1b2838;padding-top:10px;margin-top:10px">
              <div style="font-size:10px;font-weight:700;color:#60a5fa;letter-spacing:1.2px;margin-bottom:6px">FLEET & TIDES</div>
              <%= if @vessel_data && @vessel_data[:vessels] do %>
                <div style="font-size:11px;color:#94a3b8;margin-bottom:4px">
                  <%= length(@vessel_data[:vessels]) %> vessel<%= if length(@vessel_data[:vessels]) != 1, do: "s", else: "" %> tracked
                </div>
                <%= for vessel <- Enum.take(@vessel_data[:vessels] || [], 3) do %>
                  <div style="display:flex;align-items:center;gap:6px;font-size:10px;padding:2px 0">
                    <span style={"color:#{vessel_status_color(vessel[:status])}"}><%= vessel_status_icon(vessel[:direction]) %></span>
                    <span style="color:#c8d6e5;font-weight:600;max-width:90px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= vessel[:name] || "Unknown" %></span>
                    <span style="color:#64748b;font-size:9px">mi <%= vessel[:river_mile] || "?" %></span>
                    <span style="color:#475569;font-size:9px"><%= vessel[:nearest_waypoint] || "" %></span>
                  </div>
                <% end %>
              <% else %>
                <div style="font-size:10px;color:#475569">No AIS data</div>
              <% end %>
              <%= if @tides_data do %>
                <div style="display:flex;gap:8px;margin-top:4px;font-size:10px">
                  <%= if @tides_data[:water_level_ft] do %>
                    <span style="color:#60a5fa">WL: <%= Float.round(@tides_data[:water_level_ft], 1) %>ft</span>
                  <% end %>
                  <%= if @tides_data[:tidal_range_ft] do %>
                    <span style="color:#818cf8">Range: <%= Float.round(@tides_data[:tidal_range_ft], 1) %>ft</span>
                  <% end %>
                  <%= if @tides_data[:current_speed_kn] do %>
                    <span style="color:#38bdf8">Current: <%= Float.round(@tides_data[:current_speed_kn], 1) %>kn</span>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- === RIGHT: TABS === --%>
        <div style="overflow-y:auto;padding:16px">
          <%!-- Tab buttons --%>
          <div style="display:flex;gap:2px;margin-bottom:16px">
            <%= for {tab, label, color} <- [{:trader, "Trader", "#38bdf8"}, {:contracts, "Contracts", "#a78bfa"}, {:map, "Map", "#60a5fa"}, {:agent, "Agent", "#10b981"}] do %>
              <button phx-click="switch_tab" phx-value-tab={tab}
                style={"padding:8px 16px;border:none;border-radius:6px 6px 0 0;font-size:12px;font-weight:600;cursor:pointer;background:#{if @active_tab == tab, do: "#111827", else: "transparent"};color:#{if @active_tab == tab, do: "#e2e8f0", else: "#475569"};border-bottom:2px solid #{if @active_tab == tab, do: color, else: "transparent"}"}>
                <%= label %>
              </button>
            <% end %>
          </div>

          <%!-- Pipeline status banner --%>
          <%= if @pipeline_phase do %>
            <div style={"background:#{pipeline_bg(@pipeline_phase)};border:1px solid #{pipeline_border(@pipeline_phase)};border-radius:8px;padding:10px 14px;margin-bottom:12px;display:flex;align-items:center;gap:10px;font-size:12px"}>
              <div style={"width:8px;height:8px;border-radius:50%;background:#{pipeline_dot(@pipeline_phase)};animation:pulse 1.5s infinite"}></div>
              <span style="color:#e2e8f0;font-weight:600"><%= pipeline_phase_text(@pipeline_phase) %></span>
              <%= if @pipeline_detail do %>
                <span style="color:#94a3b8">— <%= @pipeline_detail %></span>
              <% end %>
            </div>
          <% end %>
          <%= if @contracts_stale and not @solving do %>
            <div style="background:#1c1917;border:1px solid #78350f;border-radius:8px;padding:8px 14px;margin-bottom:12px;font-size:11px;color:#fbbf24">
              ⚠ Contract data may be stale — scanner was unavailable during this solve
            </div>
          <% end %>

          <%!-- === TRADER TAB === --%>
          <%= if @active_tab == :trader do %>
            <%!-- Solve result --%>
            <%= if @result && @result.status == :optimal do %>
              <div style="background:#111827;border-radius:10px;padding:20px;margin-bottom:16px">
                <div style="display:flex;justify-content:space-between;align-items:flex-start">
                  <div>
                    <div style="font-size:11px;color:#64748b;letter-spacing:1px;text-transform:uppercase">Gross Profit</div>
                    <div style="font-size:36px;font-weight:800;color:#10b981;font-family:monospace">$<%= format_number(@result.profit) %></div>
                  </div>
                  <div style="background:#0f2a1f;padding:6px 14px;border-radius:6px;text-align:center">
                    <div style="font-size:10px;color:#64748b">STATUS</div>
                    <div style="font-size:13px;font-weight:700;color:#10b981">OPTIMAL</div>
                  </div>
                </div>
                <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-top:14px">
                  <div style="background:#0a0f18;padding:8px;border-radius:6px"><div style="font-size:10px;color:#64748b">Tons</div><div style="font-size:15px;font-weight:700;font-family:monospace"><%= format_number(@result.tons) %></div></div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px"><div style="font-size:10px;color:#64748b">Barges</div><div style="font-size:15px;font-weight:700;font-family:monospace"><%= Float.round(@result.barges, 1) %></div></div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px"><div style="font-size:10px;color:#64748b">ROI</div><div style="font-size:15px;font-weight:700;font-family:monospace"><%= Float.round(@result.roi, 1) %>%</div></div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px"><div style="font-size:10px;color:#64748b">Capital</div><div style="font-size:15px;font-weight:700;font-family:monospace">$<%= format_number(@result.cost) %></div></div>
                </div>
                <%!-- Routes --%>
                <table style="width:100%;border-collapse:collapse;font-size:12px;margin-top:12px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:6px;color:#64748b;font-size:11px">Route</th>
                    <th style="text-align:right;padding:6px;color:#64748b;font-size:11px">Tons</th>
                    <th style="text-align:right;padding:6px;color:#64748b;font-size:11px">Margin</th>
                    <th style="text-align:right;padding:6px;color:#64748b;font-size:11px">Profit</th>
                  </tr></thead>
                  <tbody>
                    <%= for {name, idx} <- Enum.with_index(@route_names) do %>
                      <% tons = Enum.at(@result.route_tons, idx, 0) %>
                      <%= if tons > 0.5 do %>
                        <tr><td style="padding:6px;font-weight:600"><%= name %></td>
                        <td style="text-align:right;padding:6px;font-family:monospace"><%= format_number(tons) %></td>
                        <td style="text-align:right;padding:6px;font-family:monospace;color:#38bdf8">$<%= Float.round(Enum.at(@result.margins, idx, 0), 1) %>/t</td>
                        <td style="text-align:right;padding:6px;font-family:monospace;color:#10b981;font-weight:700">$<%= format_number(Enum.at(@result.route_profits, idx, 0)) %></td></tr>
                      <% end %>
                    <% end %>
                  </tbody>
                </table>

                <%!-- Percentile rank if MC has been run --%>
                <%= if @distribution do %>
                  <% {pct, desc} = percentile_rank(@result.profit, @distribution) %>
                  <div style="margin-top:12px;padding:10px;background:#0a0f18;border-radius:6px;font-size:12px">
                    <div style="display:flex;align-items:center;gap:8px">
                      <div style="flex:1;height:6px;background:#1e293b;border-radius:3px;position:relative;overflow:visible">
                        <div style={"width:#{pct}%;height:100%;background:linear-gradient(90deg,#ef4444,#f59e0b,#10b981);border-radius:3px"}></div>
                        <div style={"position:absolute;top:-3px;left:#{pct}%;width:2px;height:12px;background:#fff;border-radius:1px"}></div>
                      </div>
                    </div>
                    <div style="color:#94a3b8;margin-top:6px">
                      Your scenario ($<%= format_number(@result.profit) %>) is at the <span style="color:#38bdf8;font-weight:700"><%= pct %>th</span> percentile — <%= desc %>
                    </div>
                  </div>
                <% end %>

                <div style="display:flex;gap:8px;margin-top:12px">
                  <form phx-submit="save_scenario" style="display:flex;gap:8px;flex:1">
                    <input type="text" name="name" placeholder="Scenario name..." style="flex:1;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:8px;border-radius:6px;font-size:12px" />
                    <button type="submit" style="background:#1e293b;border:none;color:#94a3b8;padding:8px 14px;border-radius:6px;cursor:pointer;font-size:12px">💾 Save</button>
                  </form>
                </div>
              </div>
            <% end %>

            <%!-- AI Explanation --%>
            <div style="background:#0f1729;border:1px solid #1e293b;border-radius:8px;padding:12px;margin-bottom:16px">
              <div style="display:flex;align-items:center;gap:6px;margin-bottom:6px">
                <span style="font-size:11px;color:#8b5cf6;font-weight:700;letter-spacing:1px">🧠 ANALYST</span>
                <%= if @explaining do %>
                  <span style="font-size:10px;color:#475569">thinking...</span>
                <% end %>
              </div>
              <%= case @explanation do %>
                <% {:error, err_text} -> %>
                  <div style="font-size:12px;color:#f87171;line-height:1.5"><%= err_text %></div>
                <% text when is_binary(text) -> %>
                  <div style="font-size:13px;color:#c8d6e5;line-height:1.5"><%= text %></div>
                <% _ -> %>
                  <div style="font-size:12px;color:#475569;font-style:italic">Run SOLVE or MONTE CARLO to get analysis</div>
              <% end %>
            </div>

            <%!-- Monte Carlo distribution --%>
            <%= if @distribution do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
                  <span style="font-size:11px;color:#64748b;letter-spacing:1px">MONTE CARLO — <%= @distribution.n_feasible %>/<%= @distribution.n_scenarios %> feasible</span>
                  <span style={"color:#{signal_color(@distribution.signal)};font-weight:700;font-size:12px"}><%= signal_text(@distribution.signal) %></span>
                </div>
                <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:12px">
                  <div style="background:#0a0f18;padding:8px;border-radius:4px"><div style="font-size:10px;color:#64748b">Mean</div><div style="color:#10b981;font-weight:700;font-family:monospace">$<%= format_number(@distribution.mean) %></div></div>
                  <div style="background:#0a0f18;padding:8px;border-radius:4px"><div style="font-size:10px;color:#64748b">VaR₅</div><div style="color:#f59e0b;font-weight:700;font-family:monospace">$<%= format_number(@distribution.p5) %></div></div>
                  <div style="background:#0a0f18;padding:8px;border-radius:4px"><div style="font-size:10px;color:#64748b">P95</div><div style="color:#10b981;font-weight:700;font-family:monospace">$<%= format_number(@distribution.p95) %></div></div>
                </div>

                <%!-- Sensitivity --%>
                <%= if length(@distribution.sensitivity) > 0 do %>
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px;margin-top:12px">TOP RISK DRIVERS</div>
                  <%= for {key, corr} <- @distribution.sensitivity do %>
                    <div style="display:flex;align-items:center;gap:8px;margin-bottom:4px;font-size:12px">
                      <span style="width:120px;color:#94a3b8"><%= sensitivity_label(key) %></span>
                      <div style="flex:1;height:6px;background:#1e293b;border-radius:3px;overflow:hidden">
                        <div style={"width:#{round(abs(corr) * 100)}%;height:100%;border-radius:3px;background:#{if corr > 0, do: "#10b981", else: "#ef4444"}"}></div>
                      </div>
                      <span style={"width:50px;text-align:right;font-family:monospace;font-size:11px;color:#{if corr > 0, do: "#10b981", else: "#ef4444"}"}><%= if corr > 0, do: "+", else: "" %><%= Float.round(corr, 2) %></span>
                    </div>
                  <% end %>
                <% end %>
              </div>
            <% end %>

            <%!-- === TIDES & CURRENTS (Trader tab) === --%>
            <%= if @tides_data do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="font-size:10px;color:#818cf8;letter-spacing:1px;font-weight:700;margin-bottom:10px">TIDES & CURRENTS</div>
                <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:10px">
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Water Level</div>
                    <div style="font-size:16px;font-weight:700;color:#60a5fa;font-family:monospace">
                      <%= if @tides_data[:water_level_ft], do: "#{Float.round(@tides_data[:water_level_ft], 1)}ft", else: "—" %>
                    </div>
                  </div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Tidal Range</div>
                    <div style="font-size:16px;font-weight:700;color:#818cf8;font-family:monospace">
                      <%= if @tides_data[:tidal_range_ft], do: "#{Float.round(@tides_data[:tidal_range_ft], 1)}ft", else: "—" %>
                    </div>
                  </div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Current</div>
                    <div style="font-size:16px;font-weight:700;color:#38bdf8;font-family:monospace">
                      <%= if @tides_data[:current_speed_kn], do: "#{Float.round(@tides_data[:current_speed_kn], 1)}kn", else: "—" %>
                    </div>
                  </div>
                </div>
                <%= if @tides_data[:tidal_predictions] && @tides_data[:tidal_predictions][:next_high] do %>
                  <div style="font-size:10px;color:#475569;margin-top:4px">
                    Next high: <span style="color:#94a3b8"><%= @tides_data[:tidal_predictions][:next_high][:time] %></span>
                    (<span style="color:#60a5fa"><%= Float.round(@tides_data[:tidal_predictions][:next_high][:level], 1) %>ft</span>)
                  </div>
                <% end %>
                <%= if @tides_data[:tidal_predictions] && @tides_data[:tidal_predictions][:next_low] do %>
                  <div style="font-size:10px;color:#475569">
                    Next low: <span style="color:#94a3b8"><%= @tides_data[:tidal_predictions][:next_low][:time] %></span>
                    (<span style="color:#f59e0b"><%= Float.round(@tides_data[:tidal_predictions][:next_low][:level], 1) %>ft</span>)
                  </div>
                <% end %>
              </div>
            <% end %>

            <%!-- Saved scenarios --%>
            <%= if length(@saved_scenarios) > 0 do %>
              <div style="background:#111827;border-radius:10px;padding:16px">
                <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:8px">SAVED SCENARIOS</div>
                <table style="width:100%;border-collapse:collapse;font-size:12px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:4px;color:#64748b;font-size:11px">Name</th>
                    <th style="text-align:right;padding:4px;color:#64748b;font-size:11px">Profit</th>
                    <th style="text-align:right;padding:4px;color:#64748b;font-size:11px">ROI</th>
                    <th style="text-align:right;padding:4px;color:#64748b;font-size:11px">Tons</th>
                  </tr></thead>
                  <tbody>
                    <%= for sc <- @saved_scenarios do %>
                      <tr phx-click="load_scenario" phx-value-id={sc.id} style="cursor:pointer;border-bottom:1px solid #1e293b11">
                        <td style="padding:6px 4px;font-weight:600"><%= sc.name %></td>
                        <td style="text-align:right;padding:6px 4px;font-family:monospace;color:#10b981">$<%= format_number(sc.result.profit) %></td>
                        <td style="text-align:right;padding:6px 4px;font-family:monospace"><%= Float.round(sc.result.roi, 1) %>%</td>
                        <td style="text-align:right;padding:6px 4px;font-family:monospace"><%= format_number(sc.result.tons) %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% end %>

          <%!-- Post-solve impact --%>
            <%= if @post_solve_impact do %>
              <div style="background:#0d1a0d;border:1px solid #166534;border-radius:8px;padding:14px;margin-bottom:16px">
                <div style="font-size:11px;color:#4ade80;font-weight:700;letter-spacing:1px;margin-bottom:8px">POSITION IMPACT</div>
                <%= if @post_solve_impact[:summary] do %>
                  <div style="font-size:12px;color:#c8d6e5;line-height:1.5;margin-bottom:10px"><%= @post_solve_impact[:summary] %></div>
                <% end %>
                <%= if @post_solve_impact[:by_contract] do %>
                  <table style="width:100%;border-collapse:collapse;font-size:11px">
                    <thead><tr style="border-bottom:1px solid #1e293b">
                      <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Counterparty</th>
                      <th style="text-align:center;padding:4px 6px;color:#64748b;font-size:10px">Dir</th>
                      <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:10px">Open Qty</th>
                      <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Impact</th>
                    </tr></thead>
                    <tbody>
                      <%= for cp <- @post_solve_impact[:by_contract] do %>
                        <tr style="border-bottom:1px solid #1e293b11">
                          <td style="padding:4px 6px;font-weight:600;color:#e2e8f0"><%= cp[:counterparty] %></td>
                          <td style={"text-align:center;padding:4px 6px;color:#{if cp[:direction] == "purchase", do: "#60a5fa", else: "#f59e0b"};font-size:10px;font-weight:600"}><%= if cp[:direction] == "purchase", do: "BUY", else: "SELL" %></td>
                          <td style="text-align:right;padding:4px 6px;font-family:monospace;color:#c8d6e5"><%= format_number(cp[:open_qty] || 0) %></td>
                          <td style="padding:4px 6px;color:#94a3b8;font-size:10px"><%= cp[:impact] %></td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                <% end %>
                <%= if @post_solve_impact[:net_position_after] do %>
                  <div style="margin-top:8px;padding-top:8px;border-top:1px solid #166534;font-size:11px;color:#94a3b8">
                    Net position after: <span style={"font-weight:700;color:#{if @post_solve_impact[:net_position_after] > 0, do: "#4ade80", else: "#f87171"}"}>
                      <%= if @post_solve_impact[:net_position_after] > 0, do: "+", else: "" %><%= format_number(@post_solve_impact[:net_position_after]) %> MT
                    </span>
                  </div>
                <% end %>
              </div>
            <% end %>

          <%!-- === CONTRACTS TAB === --%>
          <%= if @active_tab == :contracts do %>
            <%!-- Ammonia Price Board --%>
            <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
              <div style="font-size:10px;color:#a78bfa;letter-spacing:1px;font-weight:700;margin-bottom:10px">AMMONIA BENCHMARK PRICES</div>
              <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:8px">
                <%= for p <- @ammonia_prices do %>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b"><%= p.label %></div>
                    <div style={"font-size:16px;font-weight:700;font-family:monospace;color:#{if p.direction == :buy, do: "#60a5fa", else: "#f59e0b"};"}>$<%= round(p.price) %></div>
                    <div style="font-size:8px;color:#475569"><%= p.source %></div>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Open Book Summary --%>
            <%= if @contracts_data do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
                  <span style="font-size:10px;color:#a78bfa;letter-spacing:1px;font-weight:700">OPEN BOOK</span>
                  <span style={"font-size:12px;font-weight:700;font-family:monospace;color:#{if @contracts_data.net_position > 0, do: "#4ade80", else: "#f87171"}"}>
                    NET: <%= if @contracts_data.net_position > 0, do: "+", else: "" %><%= format_number(@contracts_data.net_position) %> MT
                  </span>
                </div>
                <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:16px">
                  <div style="background:#0a1628;padding:12px;border-radius:8px;border-left:3px solid #60a5fa">
                    <div style="font-size:10px;color:#64748b">Purchase Open</div>
                    <div style="font-size:22px;font-weight:800;color:#60a5fa;font-family:monospace"><%= format_number(@contracts_data.total_purchase_open) %> MT</div>
                    <div style="font-size:10px;color:#475569"><%= length(Enum.filter(@contracts_data.contracts, & &1.direction == :purchase)) %> contracts</div>
                  </div>
                  <div style="background:#1a1400;padding:12px;border-radius:8px;border-left:3px solid #f59e0b">
                    <div style="font-size:10px;color:#64748b">Sale Open</div>
                    <div style="font-size:22px;font-weight:800;color:#f59e0b;font-family:monospace"><%= format_number(@contracts_data.total_sale_open) %> MT</div>
                    <div style="font-size:10px;color:#475569"><%= length(Enum.filter(@contracts_data.contracts, & &1.direction == :sale)) %> contracts</div>
                  </div>
                </div>

                <%!-- Contract Detail Table --%>
                <table style="width:100%;border-collapse:collapse;font-size:11px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:6px;color:#64748b;font-size:10px">Counterparty</th>
                    <th style="text-align:center;padding:6px;color:#64748b;font-size:10px">Dir</th>
                    <th style="text-align:center;padding:6px;color:#64748b;font-size:10px">Incoterm</th>
                    <th style="text-align:right;padding:6px;color:#64748b;font-size:10px">Total</th>
                    <th style="text-align:right;padding:6px;color:#64748b;font-size:10px">Open</th>
                    <th style="text-align:center;padding:6px;color:#64748b;font-size:10px">Progress</th>
                    <th style="text-align:left;padding:6px;color:#64748b;font-size:10px">Penalties</th>
                  </tr></thead>
                  <tbody>
                    <%= for c <- @contracts_data.contracts do %>
                      <tr style="border-bottom:1px solid #1e293b11">
                        <td style="padding:6px">
                          <div style="font-weight:600;color:#e2e8f0"><%= c.counterparty %></div>
                          <div style="font-size:9px;color:#475569"><%= c.contract_number %></div>
                        </td>
                        <td style={"text-align:center;padding:6px;font-weight:600;color:#{if c.direction == :purchase, do: "#60a5fa", else: "#f59e0b"}"}><%= if c.direction == :purchase, do: "BUY", else: "SELL" %></td>
                        <td style="text-align:center;padding:6px;color:#94a3b8;font-weight:600"><%= c.incoterm |> to_string() |> String.upcase() %></td>
                        <td style="text-align:right;padding:6px;font-family:monospace;color:#94a3b8"><%= format_number(c.total_qty) %></td>
                        <td style="text-align:right;padding:6px;font-family:monospace;color:#e2e8f0;font-weight:700"><%= format_number(c.open_qty) %></td>
                        <td style="padding:6px">
                          <div style="display:flex;align-items:center;gap:4px">
                            <div style="flex:1;height:4px;background:#1e293b;border-radius:2px;overflow:hidden">
                              <div style={"width:#{c.pct_complete}%;height:100%;background:#{if c.pct_complete > 50, do: "#10b981", else: "#38bdf8"};border-radius:2px"}></div>
                            </div>
                            <span style="font-size:9px;color:#64748b;width:28px;text-align:right"><%= c.pct_complete %>%</span>
                          </div>
                        </td>
                        <td style="padding:6px">
                          <%= for p <- c.penalties do %>
                            <div style="font-size:9px;padding:1px 0">
                              <span style="color:#fca5a5"><%= p.type %></span>
                              <span style="color:#64748b"> — </span>
                              <span style="color:#f59e0b;font-family:monospace"><%= p.rate %></span>
                            </div>
                          <% end %>
                          <%= if length(c.penalties) == 0 do %>
                            <span style="font-size:9px;color:#475569">—</span>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% end %>

          <%!-- === MAP TAB === --%>
          <%= if @active_tab == :map do %>
            <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
              <div style="font-size:10px;color:#60a5fa;letter-spacing:1px;font-weight:700;margin-bottom:8px">ROUTE MAP</div>
              <div id={"map-tab-#{@product_group}"} phx-hook="VesselMap" phx-update="ignore"
                data-mapdata={map_data_json(@product_group, @frame, @result, @vessel_data)}
                style="height:450px;border-radius:8px;background:#0a0f18"></div>
            </div>

            <%!-- Fleet Tracking --%>
            <%= if @vessel_data && @vessel_data[:vessels] && length(@vessel_data[:vessels]) > 0 do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
                  <div style="font-size:10px;color:#60a5fa;letter-spacing:1px;font-weight:700">FLEET TRACKING</div>
                  <div style="font-size:10px;color:#475569">
                    <%= if @vessel_data[:fleet_summary] do %>
                      <%= @vessel_data[:fleet_summary][:total_vessels] %> vessels
                      — <%= @vessel_data[:fleet_summary][:underway] || 0 %> underway
                    <% end %>
                  </div>
                </div>
                <table style="width:100%;border-collapse:collapse;font-size:11px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Vessel</th>
                    <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Near</th>
                    <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:10px">Mile</th>
                    <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:10px">Speed</th>
                    <th style="text-align:center;padding:4px 6px;color:#64748b;font-size:10px">Dir</th>
                    <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Status</th>
                  </tr></thead>
                  <tbody>
                    <%= for vessel <- @vessel_data[:vessels] do %>
                      <tr style="border-bottom:1px solid #1e293b11">
                        <td style="padding:5px 6px;font-weight:600;color:#e2e8f0;max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= vessel[:name] || "Unknown" %></td>
                        <td style="padding:5px 6px;color:#94a3b8"><%= vessel[:nearest_waypoint] || "—" %></td>
                        <td style="text-align:right;padding:5px 6px;font-family:monospace;color:#38bdf8"><%= vessel[:river_mile] || "—" %></td>
                        <td style="text-align:right;padding:5px 6px;font-family:monospace;color:#c8d6e5"><%= if vessel[:speed], do: "#{Float.round(vessel[:speed], 1)}kn", else: "—" %></td>
                        <td style="text-align:center;padding:5px 6px"><%= vessel_status_icon(vessel[:direction]) %></td>
                        <td style={"padding:5px 6px;color:#{vessel_status_color(vessel[:status])};font-size:10px;font-weight:600"}><%= vessel_status_text(vessel[:status]) %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <%!-- Tides & Currents on Map tab --%>
            <%= if @tides_data do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="font-size:10px;color:#818cf8;letter-spacing:1px;font-weight:700;margin-bottom:10px">TIDES & CURRENTS</div>
                <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px">
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Water Level</div>
                    <div style="font-size:16px;font-weight:700;color:#60a5fa;font-family:monospace">
                      <%= if @tides_data[:water_level_ft], do: "#{Float.round(@tides_data[:water_level_ft], 1)}ft", else: "—" %>
                    </div>
                  </div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Tidal Range</div>
                    <div style="font-size:16px;font-weight:700;color:#818cf8;font-family:monospace">
                      <%= if @tides_data[:tidal_range_ft], do: "#{Float.round(@tides_data[:tidal_range_ft], 1)}ft", else: "—" %>
                    </div>
                  </div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Current</div>
                    <div style="font-size:16px;font-weight:700;color:#38bdf8;font-family:monospace">
                      <%= if @tides_data[:current_speed_kn], do: "#{Float.round(@tides_data[:current_speed_kn], 1)}kn", else: "—" %>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          <% end %>

          <%!-- === AGENT TAB === --%>
          <%= if @active_tab == :agent do %>
            <%= if @auto_result do %>
              <%!-- Agent header --%>
              <div style="background:#111827;border-radius:10px;padding:20px;margin-bottom:16px">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
                  <div style="display:flex;align-items:center;gap:10px">
                    <div style={"width:10px;height:10px;border-radius:50%;background:#{signal_color(@auto_result.distribution.signal)};box-shadow:0 0 10px #{signal_color(@auto_result.distribution.signal)}"}></div>
                    <span style="font-size:16px;font-weight:700;color:#e2e8f0">AGENT MODE</span>
                  </div>
                  <span style="font-size:11px;color:#475569">
                    Last run: <%= Calendar.strftime(@auto_result.timestamp, "%H:%M:%S") %>
                  </span>
                </div>

                <%!-- Signal + key metrics --%>
                <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px;margin-bottom:16px">
                  <div style="background:#0a0f18;padding:12px;border-radius:8px;text-align:center">
                    <div style="font-size:10px;color:#64748b;letter-spacing:1px">SIGNAL</div>
                    <div style={"font-size:20px;font-weight:800;color:#{signal_color(@auto_result.distribution.signal)}"}><%= signal_text(@auto_result.distribution.signal) %></div>
                  </div>
                  <div style="background:#0a0f18;padding:12px;border-radius:8px;text-align:center">
                    <div style="font-size:10px;color:#64748b;letter-spacing:1px">EXPECTED VALUE</div>
                    <div style="font-size:20px;font-weight:800;color:#10b981;font-family:monospace">$<%= format_number(@auto_result.distribution.mean) %></div>
                  </div>
                  <div style="background:#0a0f18;padding:12px;border-radius:8px;text-align:center">
                    <div style="font-size:10px;color:#64748b;letter-spacing:1px">VALUE AT RISK</div>
                    <div style="font-size:20px;font-weight:800;color:#f59e0b;font-family:monospace">$<%= format_number(@auto_result.distribution.p5) %></div>
                  </div>
                </div>

                <%!-- Current live values --%>
                <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px">CURRENT LIVE VALUES</div>
                <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-bottom:16px;font-size:12px">
                  <span>🌊 River: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :river_stage, 0.0), 1) %>ft</span></span>
                  <span>🌡 Temp: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :temp_f, 0.0), 0) %>°F</span></span>
                  <span>⛽ Gas: <span style="color:#38bdf8;font-weight:600">$<%= Float.round(Map.get(@auto_result.center, :nat_gas, 0.0), 2) %></span></span>
                  <span>🔒 Lock: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :lock_hrs, 0.0), 0) %>hrs</span></span>
                  <span>💨 Wind: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :wind_mph, 0.0), 0) %>mph</span></span>
                  <span>🏭 StL: <span style={"font-weight:600;color:#{if Map.get(@auto_result.center, :stl_outage), do: "#ef4444", else: "#10b981"}"}><%= if Map.get(@auto_result.center, :stl_outage), do: "OUTAGE", else: "ONLINE" %></span></span>
                </div>

                <%!-- What triggered this run --%>
                <%= if Map.has_key?(@auto_result, :triggers) and length(@auto_result.triggers) > 0 do %>
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px">TRIGGERED BY</div>
                  <%= for trigger <- @auto_result.triggers do %>
                    <div style="display:flex;align-items:center;gap:8px;padding:4px 0;font-size:12px">
                      <div style="width:6px;height:6px;border-radius:50%;background:#f59e0b"></div>
                      <span style="color:#e2e8f0"><%= format_trigger(trigger) %></span>
                    </div>
                  <% end %>
                <% end %>
              </div>

              <%!-- Agent AI explanation --%>
              <%= if @auto_result[:explanation] do %>
                <div style="background:#0f1729;border:1px solid #1e293b;border-radius:8px;padding:12px;margin-top:12px;margin-bottom:16px">
                  <div style="font-size:11px;color:#8b5cf6;font-weight:700;letter-spacing:1px;margin-bottom:6px">🧠 AGENT ANALYSIS</div>
                  <div style="font-size:13px;color:#c8d6e5;line-height:1.5"><%= @auto_result.explanation %></div>
                </div>
              <% end %>

              <%!-- Distribution --%>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:10px">PROFIT DISTRIBUTION — <%= @auto_result.distribution.n_feasible %>/<%= @auto_result.distribution.n_scenarios %> feasible</div>
                <%= for {label, val, color} <- [{"P95", @auto_result.distribution.p95, "#10b981"}, {"P75", @auto_result.distribution.p75, "#34d399"}, {"Mean", @auto_result.distribution.mean, "#38bdf8"}, {"P50", @auto_result.distribution.p50, "#38bdf8"}, {"P25", @auto_result.distribution.p25, "#f59e0b"}, {"VaR₅", @auto_result.distribution.p5, "#ef4444"}] do %>
                  <div style="display:flex;align-items:center;gap:8px;font-size:12px;margin-bottom:5px">
                    <span style="width:40px;color:#64748b;text-align:right"><%= label %></span>
                    <div style="flex:1;height:6px;background:#1e293b;border-radius:3px;overflow:hidden">
                      <div style={"width:#{if @auto_result.distribution.p95 > 0, do: round(val / @auto_result.distribution.p95 * 100), else: 0}%;height:100%;background:#{color};border-radius:3px"}></div>
                    </div>
                    <span style={"width:70px;font-family:monospace;color:#{color};font-weight:600;text-align:right;font-size:11px"}>$<%= format_number(val) %></span>
                  </div>
                <% end %>
              </div>

              <%!-- Sensitivity --%>
              <%= if length(@auto_result.distribution.sensitivity) > 0 do %>
                <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:8px">TOP RISK DRIVERS</div>
                  <%= for {key, corr} <- @auto_result.distribution.sensitivity do %>
                    <div style="display:flex;align-items:center;gap:8px;margin-bottom:5px;font-size:12px">
                      <span style="width:120px;color:#94a3b8"><%= sensitivity_label(key) %></span>
                      <div style="flex:1;height:6px;background:#1e293b;border-radius:3px;overflow:hidden">
                        <div style={"width:#{round(abs(corr) * 100)}%;height:100%;border-radius:3px;background:#{if corr > 0, do: "#10b981", else: "#ef4444"}"}></div>
                      </div>
                      <span style={"width:50px;text-align:right;font-family:monospace;font-size:11px;color:#{if corr > 0, do: "#10b981", else: "#ef4444"}"}><%= if corr > 0, do: "+", else: "" %><%= Float.round(corr, 2) %></span>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- History --%>
              <%= if length(@agent_history) > 0 do %>
                <div style="background:#111827;border-radius:10px;padding:16px">
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:8px">RUN HISTORY</div>
                  <%= for entry <- @agent_history do %>
                    <div style="display:flex;align-items:center;gap:10px;padding:5px 0;border-bottom:1px solid #1e293b11;font-size:12px">
                      <span style="color:#475569;width:50px"><%= Calendar.strftime(entry.timestamp, "%H:%M") %></span>
                      <span style={"font-weight:700;width:60px;color:#{signal_color(entry.distribution.signal)}"}><%= signal_text(entry.distribution.signal) %></span>
                      <span style="font-family:monospace;color:#e2e8f0;width:80px">$<%= format_number(entry.distribution.mean) %></span>
                      <span style="color:#475569;flex:1;font-size:11px">
                        <%= Enum.map(entry.triggers, &trigger_label(&1.key)) |> Enum.join(", ") %>
                      </span>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- === AGENT ROUTE MAP === --%>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="font-size:10px;color:#60a5fa;letter-spacing:1px;font-weight:700;margin-bottom:8px">ROUTE MAP</div>
                <div id={"agent-map-#{@product_group}"} phx-hook="VesselMap" phx-update="ignore"
                  data-mapdata={map_data_json(@product_group, @frame, nil, @vessel_data)}
                  style="height:280px;border-radius:8px;background:#0a0f18"></div>
              </div>

              <%!-- === FLEET TRACKING === --%>
              <%= if @vessel_data && @vessel_data[:vessels] && length(@vessel_data[:vessels]) > 0 do %>
                <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
                    <div style="font-size:10px;color:#60a5fa;letter-spacing:1px;font-weight:700">FLEET TRACKING</div>
                    <div style="font-size:10px;color:#475569">
                      <%= if @vessel_data[:fleet_summary] do %>
                        <%= @vessel_data[:fleet_summary][:total_vessels] %> vessels
                        — <%= @vessel_data[:fleet_summary][:underway] || 0 %> underway
                      <% end %>
                    </div>
                  </div>
                  <table style="width:100%;border-collapse:collapse;font-size:11px">
                    <thead><tr style="border-bottom:1px solid #1e293b">
                      <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Vessel</th>
                      <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Near</th>
                      <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:10px">Mile</th>
                      <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:10px">Speed</th>
                      <th style="text-align:center;padding:4px 6px;color:#64748b;font-size:10px">Dir</th>
                      <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Status</th>
                    </tr></thead>
                    <tbody>
                      <%= for vessel <- @vessel_data[:vessels] do %>
                        <tr style="border-bottom:1px solid #1e293b11">
                          <td style="padding:5px 6px;font-weight:600;color:#e2e8f0;max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= vessel[:name] || "Unknown" %></td>
                          <td style="padding:5px 6px;color:#94a3b8"><%= vessel[:nearest_waypoint] || "—" %></td>
                          <td style="text-align:right;padding:5px 6px;font-family:monospace;color:#38bdf8"><%= vessel[:river_mile] || "—" %></td>
                          <td style="text-align:right;padding:5px 6px;font-family:monospace;color:#c8d6e5"><%= if vessel[:speed], do: "#{Float.round(vessel[:speed], 1)}kn", else: "—" %></td>
                          <td style="text-align:center;padding:5px 6px"><%= vessel_status_icon(vessel[:direction]) %></td>
                          <td style={"padding:5px 6px;color:#{vessel_status_color(vessel[:status])};font-size:10px;font-weight:600"}><%= vessel_status_text(vessel[:status]) %></td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                  <%!-- Fleet weather from vessel positions --%>
                  <%= if @vessel_data[:fleet_weather] && @vessel_data[:fleet_weather][:source] == :fleet_aggregate do %>
                    <div style="margin-top:10px;padding-top:8px;border-top:1px solid #1e293b">
                      <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:4px">FLEET WEATHER (worst-case across positions)</div>
                      <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:6px;font-size:11px">
                        <%= if @vessel_data[:fleet_weather][:wind_mph] do %>
                          <div style="background:#0a0f18;padding:6px;border-radius:4px">
                            <div style="font-size:9px;color:#64748b">Wind</div>
                            <div style="font-weight:700;color:#38bdf8;font-family:monospace"><%= Float.round(@vessel_data[:fleet_weather][:wind_mph], 0) %> mph</div>
                          </div>
                        <% end %>
                        <%= if @vessel_data[:fleet_weather][:vis_mi] do %>
                          <div style="background:#0a0f18;padding:6px;border-radius:4px">
                            <div style="font-size:9px;color:#64748b">Visibility</div>
                            <div style="font-weight:700;color:#38bdf8;font-family:monospace"><%= Float.round(@vessel_data[:fleet_weather][:vis_mi], 1) %> mi</div>
                          </div>
                        <% end %>
                        <%= if @vessel_data[:fleet_weather][:temp_f] do %>
                          <div style="background:#0a0f18;padding:6px;border-radius:4px">
                            <div style="font-size:9px;color:#64748b">Temp</div>
                            <div style="font-weight:700;color:#38bdf8;font-family:monospace"><%= Float.round(@vessel_data[:fleet_weather][:temp_f], 0) %>°F</div>
                          </div>
                        <% end %>
                        <%= if @vessel_data[:fleet_weather][:precip_in] do %>
                          <div style="background:#0a0f18;padding:6px;border-radius:4px">
                            <div style="font-size:9px;color:#64748b">Precip</div>
                            <div style="font-weight:700;color:#38bdf8;font-family:monospace"><%= Float.round(@vessel_data[:fleet_weather][:precip_in], 1) %> in</div>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- === TIDES & CURRENTS === --%>
              <%= if @tides_data do %>
                <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                  <div style="font-size:10px;color:#818cf8;letter-spacing:1px;font-weight:700;margin-bottom:10px">TIDES & CURRENTS</div>
                  <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:10px">
                    <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">Water Level</div>
                      <div style="font-size:16px;font-weight:700;color:#60a5fa;font-family:monospace">
                        <%= if @tides_data[:water_level_ft], do: "#{Float.round(@tides_data[:water_level_ft], 1)}ft", else: "—" %>
                      </div>
                      <div style="font-size:9px;color:#475569">Pilottown</div>
                    </div>
                    <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">Tidal Range</div>
                      <div style="font-size:16px;font-weight:700;color:#818cf8;font-family:monospace">
                        <%= if @tides_data[:tidal_range_ft], do: "#{Float.round(@tides_data[:tidal_range_ft], 1)}ft", else: "—" %>
                      </div>
                      <div style="font-size:9px;color:#475569">24h predicted</div>
                    </div>
                    <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">Current</div>
                      <div style="font-size:16px;font-weight:700;color:#38bdf8;font-family:monospace">
                        <%= if @tides_data[:current_speed_kn], do: "#{Float.round(@tides_data[:current_speed_kn], 1)}kn", else: "—" %>
                      </div>
                      <div style="font-size:9px;color:#475569">SW Pass</div>
                    </div>
                  </div>
                  <%= if @tides_data[:nola_water_level_ft] do %>
                    <div style="font-size:11px;color:#94a3b8;margin-bottom:4px">
                      NOLA (New Canal): <span style="color:#60a5fa;font-weight:600;font-family:monospace"><%= Float.round(@tides_data[:nola_water_level_ft], 1) %>ft</span>
                    </div>
                  <% end %>
                  <%= if @tides_data[:tidal_predictions] && @tides_data[:tidal_predictions][:next_high] do %>
                    <div style="font-size:10px;color:#475569;margin-top:4px">
                      Next high: <span style="color:#94a3b8"><%= @tides_data[:tidal_predictions][:next_high][:time] %></span>
                      (<span style="color:#60a5fa"><%= Float.round(@tides_data[:tidal_predictions][:next_high][:level], 1) %>ft</span>)
                    </div>
                  <% end %>
                  <%= if @tides_data[:tidal_predictions] && @tides_data[:tidal_predictions][:next_low] do %>
                    <div style="font-size:10px;color:#475569">
                      Next low: <span style="color:#94a3b8"><%= @tides_data[:tidal_predictions][:next_low][:time] %></span>
                      (<span style="color:#f59e0b"><%= Float.round(@tides_data[:tidal_predictions][:next_low][:level], 1) %>ft</span>)
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% else %>
              <div style="background:#111827;border-radius:10px;padding:40px;text-align:center;color:#475569">
                Agent is initializing...
              </div>
            <% end %>
          <% end %>
        </div>
      </div>

      <%!-- === PRE-SOLVE REVIEW POPUP === --%>
      <%= if @show_review do %>
        <div style="position:fixed;inset:0;background:rgba(0,0,0,0.7);z-index:1000;display:flex;align-items:center;justify-content:center"
             phx-click="cancel_review">
          <div style="background:#111827;border:1px solid #1e293b;border-radius:12px;padding:24px;width:640px;max-height:80vh;overflow-y:auto;box-shadow:0 25px 50px rgba(0,0,0,0.5)"
               phx-click-away="cancel_review">

            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
              <span style="font-size:14px;font-weight:700;color:#e2e8f0;letter-spacing:1px">
                PRE-SOLVE REVIEW — <%= if @review_mode == :monte_carlo, do: "MONTE CARLO", else: "SOLVE" %>
              </span>
              <button phx-click="cancel_review" style="background:none;border:none;color:#64748b;cursor:pointer;font-size:16px">X</button>
            </div>

            <%!-- Trader Action --%>
            <%= if @trader_action != "" do %>
              <div style="background:#0a0f18;border-radius:8px;padding:12px;margin-bottom:12px;border-left:3px solid #a78bfa">
                <div style="font-size:10px;color:#a78bfa;letter-spacing:1px;margin-bottom:4px">TRADER ACTION</div>
                <div style="font-size:13px;color:#e2e8f0;font-style:italic">"<%= @trader_action %>"</div>
              </div>
            <% end %>

            <%!-- Intent Mapping --%>
            <%= if @intent_loading do %>
              <div style="font-size:12px;color:#64748b;padding:8px 0">Mapping intent to variables...</div>
            <% end %>
            <%= if @intent do %>
              <div style="background:#0a0f18;border-radius:8px;padding:12px;margin-bottom:12px">
                <div style="font-size:10px;color:#38bdf8;letter-spacing:1px;margin-bottom:4px">AI INTERPRETATION</div>
                <div style="font-size:12px;color:#c8d6e5;margin-bottom:8px"><%= @intent.summary %></div>

                <%= if map_size(@intent.variable_adjustments) > 0 do %>
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:4px;margin-top:8px">VARIABLE CHANGES</div>
                  <%= for {key, val} <- @intent.variable_adjustments do %>
                    <div style="display:flex;justify-content:space-between;font-size:11px;padding:2px 0">
                      <span style="color:#94a3b8"><%= key %></span>
                      <span style="color:#f59e0b;font-family:monospace"><%= Map.get(@current_vars, key) %> -> <%= val %></span>
                    </div>
                  <% end %>
                <% end %>

                <%= if length(@intent.affected_contracts) > 0 do %>
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:4px;margin-top:8px">AFFECTED CONTRACTS</div>
                  <%= for ac <- @intent.affected_contracts do %>
                    <div style="font-size:11px;padding:3px 0;border-bottom:1px solid #1e293b11">
                      <span style={"font-weight:600;color:#{if ac.direction == "purchase", do: "#60a5fa", else: "#f59e0b"}"}><%= ac.counterparty %></span>
                      <span style="color:#64748b;margin-left:4px">— <%= ac.impact %></span>
                    </div>
                  <% end %>
                <% end %>

                <%= if length(@intent.risk_notes) > 0 do %>
                  <div style="font-size:10px;color:#ef4444;letter-spacing:1px;margin-bottom:4px;margin-top:8px">RISK ALERTS</div>
                  <%= for note <- @intent.risk_notes do %>
                    <div style="font-size:11px;color:#fca5a5;padding:2px 0"><%= note %></div>
                  <% end %>
                <% end %>
              </div>
            <% end %>

            <%!-- Open Book Positions --%>
            <%= if @sap_positions do %>
              <div style="background:#0a0f18;border-radius:8px;padding:12px;margin-bottom:12px">
                <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px">OPEN BOOK (SAP)</div>
                <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:8px">
                  <div style="text-align:center">
                    <div style="font-size:9px;color:#64748b">Purchase Open</div>
                    <div style="font-size:14px;font-weight:700;color:#60a5fa;font-family:monospace"><%= format_number(@sap_positions.total_purchase_open) %></div>
                  </div>
                  <div style="text-align:center">
                    <div style="font-size:9px;color:#64748b">Sale Open</div>
                    <div style="font-size:14px;font-weight:700;color:#f59e0b;font-family:monospace"><%= format_number(@sap_positions.total_sale_open) %></div>
                  </div>
                  <div style="text-align:center">
                    <div style="font-size:9px;color:#64748b">Net Position</div>
                    <div style={"font-size:14px;font-weight:700;font-family:monospace;color:#{if @sap_positions.net_position > 0, do: "#4ade80", else: "#f87171"}"}><%= if @sap_positions.net_position > 0, do: "+", else: "" %><%= format_number(@sap_positions.net_position) %></div>
                  </div>
                </div>
                <table style="width:100%;border-collapse:collapse;font-size:10px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:3px 4px;color:#475569">Counterparty</th>
                    <th style="text-align:center;padding:3px 4px;color:#475569">Dir</th>
                    <th style="text-align:center;padding:3px 4px;color:#475569">Incoterm</th>
                    <th style="text-align:right;padding:3px 4px;color:#475569">Contract</th>
                    <th style="text-align:right;padding:3px 4px;color:#475569">Delivered</th>
                    <th style="text-align:right;padding:3px 4px;color:#475569">Open</th>
                  </tr></thead>
                  <tbody>
                    <%= for {name, pos} <- Enum.sort_by(@sap_positions.positions, fn {_k, v} -> v.open_qty_mt end, :desc) do %>
                      <tr style="border-bottom:1px solid #1e293b11">
                        <td style="padding:3px 4px;color:#c8d6e5;font-weight:600"><%= name %></td>
                        <td style={"text-align:center;padding:3px 4px;color:#{if pos.direction == :purchase, do: "#60a5fa", else: "#f59e0b"};font-weight:600"}><%= if pos.direction == :purchase, do: "BUY", else: "SELL" %></td>
                        <td style="text-align:center;padding:3px 4px;color:#94a3b8"><%= pos.incoterm |> to_string() |> String.upcase() %></td>
                        <td style="text-align:right;padding:3px 4px;font-family:monospace;color:#94a3b8"><%= format_number(pos.total_qty_mt) %></td>
                        <td style="text-align:right;padding:3px 4px;font-family:monospace;color:#64748b"><%= format_number(pos.delivered_qty_mt) %></td>
                        <td style="text-align:right;padding:3px 4px;font-family:monospace;color:#e2e8f0;font-weight:600"><%= format_number(pos.open_qty_mt) %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <%!-- Key Variables Summary --%>
            <div style="background:#0a0f18;border-radius:8px;padding:12px;margin-bottom:16px">
              <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px">CURRENT VARIABLES</div>
              <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:4px;font-size:11px">
                <%= for meta <- Enum.take(Enum.filter(@metadata, & Map.get(&1, :type) != :boolean), 12) do %>
                  <div style="display:flex;justify-content:space-between;padding:2px 4px">
                    <span style="color:#64748b;font-size:10px"><%= meta.label %></span>
                    <span style={"color:#{if MapSet.member?(@overrides, meta.key), do: "#f59e0b", else: "#94a3b8"};font-family:monospace;font-size:10px"}><%= format_var(meta, Map.get(@current_vars, meta.key)) %></span>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Action buttons --%>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
              <button phx-click="cancel_review"
                style="padding:12px;border:1px solid #1e293b;border-radius:8px;background:transparent;color:#94a3b8;font-weight:700;font-size:13px;cursor:pointer;letter-spacing:1px">
                CANCEL
              </button>
              <button phx-click="confirm_solve"
                style={"padding:12px;border:none;border-radius:8px;font-weight:700;font-size:13px;cursor:pointer;letter-spacing:1px;color:#fff;background:linear-gradient(135deg,#{if @review_mode == :monte_carlo, do: "#7c3aed,#8b5cf6", else: "#0891b2,#06b6d4"})"}>
                CONFIRM <%= if @review_mode == :monte_carlo, do: "MONTE CARLO", else: "SOLVE" %>
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Helpers ---

  defp percentile_rank(profit, dist) do
    cond do
      dist == nil -> nil
      profit <= dist.p5 -> {5, "below 5th percentile — high risk"}
      profit <= dist.p25 ->
        pct = round(5 + (profit - dist.p5) / max(dist.p25 - dist.p5, 1) * 20)
        {pct, "#{pct}th percentile — below average"}
      profit <= dist.p50 ->
        pct = round(25 + (profit - dist.p25) / max(dist.p50 - dist.p25, 1) * 25)
        {pct, "#{pct}th percentile — near median"}
      profit <= dist.p75 ->
        pct = round(50 + (profit - dist.p50) / max(dist.p75 - dist.p50, 1) * 25)
        {pct, "#{pct}th percentile — above average"}
      profit <= dist.p95 ->
        pct = round(75 + (profit - dist.p75) / max(dist.p95 - dist.p75, 1) * 20)
        {pct, "#{pct}th percentile — strong"}
      true -> {99, "above 95th percentile — best case"}
    end
  end

  defp sensitivity_label(key) do
    # Try all registered product groups for label lookup
    label =
      ProductGroup.list()
      |> Enum.find_value(fn pg ->
        ProductGroup.variables(pg)
        |> Enum.find_value(fn v ->
          if v[:key] == key, do: v[:label]
        end)
      end)

    label || key |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp trigger_label(:startup), do: "startup"
  defp trigger_label(:scheduled), do: "scheduled"
  defp trigger_label(:manual), do: "manual"
  defp trigger_label(:initial), do: "initial"
  defp trigger_label(key), do: sensitivity_label(key)

  defp format_trigger(%{key: key, baseline_value: baseline, current_value: current, delta: delta, threshold: threshold}) do
    sign = if delta > 0, do: "+", else: ""
    "#{trigger_label(key)}: #{Float.round(baseline, 1)} → #{Float.round(current, 1)} (#{sign}#{Float.round(delta, 1)}, threshold ±#{Float.round(threshold, 1)})"
  end
  defp format_trigger(%{key: key, baseline_value: baseline, current_value: current, delta: delta}) do
    sign = if delta > 0, do: "+", else: ""
    "#{trigger_label(key)}: #{Float.round(baseline, 1)} → #{Float.round(current, 1)} (#{sign}#{Float.round(delta, 1)})"
  end
  defp format_trigger(%{key: key, old: nil}), do: trigger_label(key)
  defp format_trigger(%{key: key, old: old, new: new}) do
    delta = new - old
    sign = if delta > 0, do: "+", else: ""
    "#{trigger_label(key)}: #{Float.round(old, 1)} → #{Float.round(new, 1)} (#{sign}#{Float.round(delta, 1)})"
  end
  defp format_trigger(%{key: key}), do: trigger_label(key)
  defp format_trigger(_), do: "—"

  defp signal_color(:strong_go), do: "#10b981"
  defp signal_color(:go), do: "#34d399"
  defp signal_color(:cautious), do: "#fbbf24"
  defp signal_color(:weak), do: "#f87171"
  defp signal_color(:no_go), do: "#ef4444"
  defp signal_color(_), do: "#64748b"

  defp signal_text(:strong_go), do: "STRONG GO"
  defp signal_text(:go), do: "GO"
  defp signal_text(:cautious), do: "CAUTIOUS"
  defp signal_text(:weak), do: "WEAK"
  defp signal_text(:no_go), do: "NO GO"
  defp signal_text(_), do: "—"

  defp group_color(:environment), do: "#38bdf8"
  defp group_color(:operations), do: "#a78bfa"
  defp group_color(:commercial), do: "#34d399"
  defp group_color(:market), do: "#34d399"
  defp group_color(:freight), do: "#f59e0b"
  defp group_color(:macro), do: "#818cf8"
  defp group_color(:quality), do: "#fb923c"
  defp group_color(_), do: "#94a3b8"

  defp group_icon(:environment), do: "~"
  defp group_icon(:operations), do: "*"
  defp group_icon(:commercial), do: "$"
  defp group_icon(:market), do: "$"
  defp group_icon(:freight), do: ">"
  defp group_icon(:macro), do: "#"
  defp group_icon(:quality), do: "?"
  defp group_icon(_), do: "-"

  defp format_var(%{unit: "$"}, val), do: "$#{format_number(val)}"
  defp format_var(%{unit: "$M"}, val), do: "$#{format_number(val)}M"
  defp format_var(%{step: step, unit: unit}, val) when is_float(val) and is_float(step) and step < 1 do
    "#{Float.round(val, 1)} #{unit}"
  end
  defp format_var(%{unit: unit}, val) when is_float(val), do: "#{round(val)} #{unit}"
  defp format_var(%{unit: unit}, val), do: "#{val} #{unit}"
  defp format_var(_meta, val), do: to_string(val)

  defp format_number(val) when is_float(val) do
    val
    |> round()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse()
    |> String.trim_leading(",")
  end
  defp format_number(val), do: to_string(val)

  defp load_contracts_data do
    book = TradingDesk.Contracts.SapPositions.book_summary()
    positions = book.positions

    contracts =
      positions
      |> Enum.sort_by(fn {_k, v} -> v.open_qty_mt end, :desc)
      |> Enum.map(fn {name, pos} ->
        # Get penalty info from seed loader positions
        penalties = case pos.direction do
          :purchase ->
            case name do
              "NGC Trinidad" -> [%{type: "Volume shortfall", rate: "$15/MT", applies_to: "Buyer"}]
              "SABIC Agri-Nutrients" -> [%{type: "Volume shortfall", rate: "$12/MT", applies_to: "Buyer"}]
              "LSB Industries" -> [%{type: "Volume shortfall", rate: "$10/MT", applies_to: "Buyer"}]
              _ -> []
            end
          :sale ->
            case name do
              "Mosaic Company" -> [%{type: "Late delivery", rate: "$20/MT", applies_to: "Seller"}, %{type: "Volume shortfall", rate: "$18/MT", applies_to: "Seller"}]
              "IFFCO" -> [%{type: "Late delivery", rate: "$15/MT", applies_to: "Seller"}, %{type: "Volume shortfall", rate: "$12/MT", applies_to: "Seller"}]
              "OCP Group" -> [%{type: "Late delivery", rate: "$22/MT", applies_to: "Seller"}]
              "Nutrien StL" -> [%{type: "Volume shortfall", rate: "$12/MT", applies_to: "Seller"}, %{type: "Late delivery", rate: "$8/MT", applies_to: "Seller"}]
              "Koch Fertilizer" -> [%{type: "Volume shortfall", rate: "$10/MT", applies_to: "Seller"}]
              "BASF SE" -> [%{type: "Late delivery", rate: "$25/MT", applies_to: "Seller"}]
              _ -> []
            end
        end

        %{
          counterparty: name,
          contract_number: pos.contract_number,
          direction: pos.direction,
          incoterm: pos.incoterm,
          total_qty: pos.total_qty_mt,
          delivered_qty: pos.delivered_qty_mt,
          open_qty: pos.open_qty_mt,
          period: pos.period,
          penalties: penalties,
          pct_complete: if(pos.total_qty_mt > 0, do: round(pos.delivered_qty_mt / pos.total_qty_mt * 100), else: 0)
        }
      end)

    %{
      contracts: contracts,
      total_purchase_open: book.total_purchase_open,
      total_sale_open: book.total_sale_open,
      net_position: book.net_position
    }
  end

  defp maybe_parse_intent(socket) do
    action = socket.assigns.trader_action
    if action != nil and String.trim(action || "") != "" do
      lv_pid = self()
      vars = socket.assigns.current_vars
      pg = socket.assigns.product_group
      spawn(fn ->
        case TradingDesk.IntentMapper.parse_intent(action, vars, pg) do
          {:ok, intent} -> send(lv_pid, {:intent_result, intent})
          {:error, _} -> send(lv_pid, {:intent_result, nil})
        end
      end)
      assign(socket, :intent_loading, true)
    else
      socket
    end
  end

  defp apply_intent_adjustments(vars, nil), do: vars
  defp apply_intent_adjustments(vars, %{variable_adjustments: adj}) when map_size(adj) > 0 do
    Enum.reduce(adj, vars, fn {key, val}, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, val), else: acc
    end)
  end
  defp apply_intent_adjustments(vars, _), do: vars

  defp parse_value(_key, "true"), do: true
  defp parse_value(_key, "false"), do: false
  defp parse_value(_key, value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp parse_value(_key, value), do: value

  # --- Pipeline UI helpers ---

  defp analyst_error_text(:no_api_key), do: "ANTHROPIC_API_KEY not set. Export it in your shell to enable analyst explanations."
  defp analyst_error_text(:api_error), do: "Claude API returned an error. Check logs for details."
  defp analyst_error_text(:request_failed), do: "Could not reach Claude API. Check network connectivity."
  defp analyst_error_text(msg) when is_binary(msg), do: "Analyst crashed: #{msg}"
  defp analyst_error_text(reason), do: "Analyst error: #{inspect(reason)}"

  defp pipeline_button_text(false, _, label), do: "⚡ #{label}"
  defp pipeline_button_text(true, :checking_contracts, _), do: "📋 CHECKING CONTRACTS..."
  defp pipeline_button_text(true, :ingesting, _), do: "🔄 INGESTING CHANGES..."
  defp pipeline_button_text(true, :solving, _), do: "⏳ SOLVING..."
  defp pipeline_button_text(true, _, _), do: "⏳ WORKING..."

  defp pipeline_phase_text(:checking_contracts), do: "Checking contract hashes"
  defp pipeline_phase_text(:ingesting), do: "Waiting for Copilot to ingest changes"
  defp pipeline_phase_text(:solving), do: "Running solver"
  defp pipeline_phase_text(_), do: "Working"

  defp pipeline_bg(:checking_contracts), do: "#0c1629"
  defp pipeline_bg(:ingesting), do: "#1a1400"
  defp pipeline_bg(:solving), do: "#0c1629"
  defp pipeline_bg(_), do: "#0c1629"

  defp pipeline_border(:checking_contracts), do: "#1e3a5f"
  defp pipeline_border(:ingesting), do: "#78350f"
  defp pipeline_border(:solving), do: "#1e3a5f"
  defp pipeline_border(_), do: "#1e293b"

  defp pipeline_dot(:checking_contracts), do: "#38bdf8"
  defp pipeline_dot(:ingesting), do: "#f59e0b"
  defp pipeline_dot(:solving), do: "#10b981"
  defp pipeline_dot(_), do: "#64748b"

  # --- Vessel tracking helpers ---

  defp vessel_status_icon(:northbound), do: "^"
  defp vessel_status_icon(:southbound), do: "v"
  defp vessel_status_icon(_), do: "-"

  defp vessel_status_color(:underway_engine), do: "#10b981"
  defp vessel_status_color(:underway_sailing), do: "#34d399"
  defp vessel_status_color(:at_anchor), do: "#f59e0b"
  defp vessel_status_color(:moored), do: "#60a5fa"
  defp vessel_status_color(:not_under_command), do: "#ef4444"
  defp vessel_status_color(:restricted_maneuverability), do: "#fbbf24"
  defp vessel_status_color(_), do: "#64748b"

  defp vessel_status_text(:underway_engine), do: "UNDERWAY"
  defp vessel_status_text(:underway_sailing), do: "SAILING"
  defp vessel_status_text(:at_anchor), do: "ANCHOR"
  defp vessel_status_text(:moored), do: "MOORED"
  defp vessel_status_text(:not_under_command), do: "NUC"
  defp vessel_status_text(:restricted_maneuverability), do: "RESTRICTED"
  defp vessel_status_text(_), do: "UNKNOWN"

  # --- Map data helpers ---

  @terminal_coords %{
    # Ammonia Domestic (Mississippi River)
    "Donaldsonville, LA" => {30.098, -90.993},
    "Geismar, LA" => {30.219, -90.935},
    "St. Louis, MO" => {38.627, -90.199},
    "Memphis, TN" => {35.150, -90.049},
    # Ammonia International
    "Point Lisas, Trinidad" => {10.400, -61.468},
    "Yuzhnyy, Ukraine" => {46.627, 31.011},
    "Jubail, Saudi Arabia" => {27.015, 49.658},
    "Tampa, FL" => {27.951, -82.457},
    "Paradip/Mumbai, India" => {20.266, 86.612},
    "Jorf Lasfar, Morocco" => {33.101, -8.621},
    # Sulphur International
    "Vancouver, BC" => {49.283, -123.121},
    "Abu Dhabi/Ruwais, UAE" => {24.073, 52.730},
    "Batumi, Georgia" => {41.640, 41.637},
    "Mumbai/Paradip, India" => {20.266, 86.612},
    "Nanjing/Zhanjiang, China" => {32.060, 118.797},
    # Petcoke
    "US Gulf Coast" => {29.760, -95.370},
    "Mundra/Kandla, India" => {22.739, 69.722},
    "Qingdao/Lianyungang, China" => {36.067, 120.383},
    "Mundra/Jamnagar, India" => {22.294, 68.968}
  }

  @map_centers %{
    ammonia_domestic: {34.0, -90.5, 5},
    ammonia_international: {20.0, -20.0, 2},
    sulphur_international: {25.0, 40.0, 2},
    petcoke: {20.0, 40.0, 2}
  }

  defp map_data_json(product_group, frame, result, vessel_data) do
    routes = frame[:routes] || []
    {clat, clon, zoom} = Map.get(@map_centers, product_group, {20.0, 0.0, 2})

    route_tons = if result, do: result.route_tons || [], else: []

    terminals =
      routes
      |> Enum.flat_map(fn r -> [r[:origin], r[:destination]] end)
      |> Enum.uniq()
      |> Enum.flat_map(fn name ->
        case Map.get(@terminal_coords, name) do
          {lat, lon} ->
            color = if String.contains?(name || "", ["Don", "Geis", "USGC", "US Gulf", "Vancouver", "Point Lisas",
                                                      "Yuzhnyy", "Jubail", "Abu Dhabi", "Batumi", "Mundra/Jamnagar"]),
                       do: "#f59e0b", else: "#10b981"
            [%{name: name, lat: lat, lon: lon, color: color}]
          _ -> []
        end
      end)

    route_lines =
      routes
      |> Enum.with_index()
      |> Enum.flat_map(fn {r, idx} ->
        with {flat, flon} <- Map.get(@terminal_coords, r[:origin]),
             {tlat, tlon} <- Map.get(@terminal_coords, r[:destination]) do
          tons = Enum.at(route_tons, idx, 0.0)
          [%{from_lat: flat, from_lon: flon, to_lat: tlat, to_lon: tlon, active: tons > 0.5}]
        else
          _ -> []
        end
      end)

    vessels =
      case vessel_data do
        %{vessels: vs} when is_list(vs) -> build_vessel_markers(vs, product_group)
        _ when is_map(vessel_data) ->
          case vessel_data[:vessels] do
            vs when is_list(vs) -> build_vessel_markers(vs, product_group)
            _ -> []
          end
        _ -> []
      end

    data = %{
      center: [clat, clon],
      zoom: zoom,
      terminals: terminals,
      routes: route_lines,
      vessels: vessels
    }

    Jason.encode!(data)
  end

  defp build_vessel_markers(vessels, :ammonia_domestic) do
    # Barge positions approximated from river mile on the Mississippi
    Enum.flat_map(vessels, fn v ->
      case v[:river_mile] do
        rm when is_number(rm) ->
          # Approximate lat from river mile (Mile 0 = Pilottown ~29.18, Mile 180 = NOLA ~30.0,
          # Mile 600 = Memphis ~35.15, Mile 1050 = St. Louis ~38.63)
          lat = 29.18 + rm * 0.009
          lon = -90.0 + :rand.uniform() * 0.3 - 0.15  # slight jitter
          color = case v[:status] do
            :underway_engine -> "#10b981"
            :at_anchor -> "#f59e0b"
            :moored -> "#60a5fa"
            _ -> "#64748b"
          end
          [%{lat: lat, lon: lon, name: v[:name] || "Barge", status: to_string(v[:status] || "unknown"), color: color}]
        _ -> []
      end
    end)
  end

  defp build_vessel_markers(vessels, _product_group) do
    # Ocean vessels with lat/lon
    Enum.flat_map(vessels, fn v ->
      lat = v[:latitude] || v[:lat]
      lon = v[:longitude] || v[:lon]
      if lat && lon do
        color = case v[:status] do
          :underway_engine -> "#10b981"
          :at_anchor -> "#f59e0b"
          :moored -> "#60a5fa"
          _ -> "#64748b"
        end
        [%{lat: lat, lon: lon, name: v[:name] || "Vessel", status: to_string(v[:status] || "unknown"), color: color}]
      else
        []
      end
    end)
  end

  # Safe GenServer call — returns fallback if the service isn't running yet
  defp safe_call(fun, fallback) do
    try do
      fun.()
    catch
      :exit, _ -> fallback
      _, _ -> fallback
    end
  end
end
