defmodule AmmoniaDesk.ScenarioLive do
  @moduledoc """
  Interactive scenario desk for ammonia barge traders.
  
  Two modes:
    - SOLVE: tweak variables, get instant result
    - MONTE CARLO: run 1000 scenarios around current values
  
  All 18 variables shown with live API values.
  Trader can override any variable, then reset to live.
  
  Two tabs:
    - TRADER: Manual scenario exploration with solve and Monte Carlo
    - AGENT: Automated agent monitoring with delta-based triggering
  """
  use Phoenix.LiveView

  alias AmmoniaDesk.Variables
  alias AmmoniaDesk.Solver.Port, as: Solver
  alias AmmoniaDesk.Data.LiveState
  alias AmmoniaDesk.Scenarios.Store

  @route_names ["Don→StL", "Don→Mem", "Geis→StL", "Geis→Mem"]
  @constraint_names ["Supply Don", "Supply Geis", "StL Capacity", "Mem Capacity", "Fleet", "Working Cap"]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AmmoniaDesk.PubSub, "live_data")
      Phoenix.PubSub.subscribe(AmmoniaDesk.PubSub, "auto_runner")
    end

    live_vars = LiveState.get()
    auto_result = AmmoniaDesk.Scenarios.AutoRunner.latest()

    socket =
      socket
      |> assign(:live_vars, live_vars)
      |> assign(:current_vars, live_vars)
      |> assign(:overrides, MapSet.new())
      |> assign(:result, nil)
      |> assign(:distribution, nil)
      |> assign(:auto_result, auto_result)
      |> assign(:saved_scenarios, Store.list("trader_1"))
      |> assign(:trader_id, "trader_1")
      |> assign(:metadata, Variables.metadata())
      |> assign(:route_names, @route_names)
      |> assign(:constraint_names, @constraint_names)
      |> assign(:solving, false)
      |> assign(:active_tab, :trader)
      |> assign(:agent_history, [])

    {:ok, socket}
  end

  @impl true
  def handle_event("solve", _params, socket) do
    socket = assign(socket, :solving, true)
    send(self(), :do_solve)
    {:noreply, socket}
  end

  @impl true
  def handle_event("monte_carlo", _params, socket) do
    socket = assign(socket, :solving, true)
    send(self(), :do_monte_carlo)
    {:noreply, socket}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    live = LiveState.get()
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
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)
    socket = assign(socket, :active_tab, tab_atom)

    # Fetch agent history when switching to agent tab
    socket =
      if tab_atom == :agent do
        history = AmmoniaDesk.Scenarios.AutoRunner.history()
        assign(socket, :agent_history, history)
      else
        socket
      end

    {:noreply, socket}
  end

  # --- Async solve handlers ---

  @impl true
  def handle_info(:do_solve, socket) do
    case Solver.solve(socket.assigns.current_vars) do
      {:ok, result} ->
        {:noreply, assign(socket, result: result, solving: false)}
      {:error, _reason} ->
        {:noreply, assign(socket, solving: false)}
    end
  end

  @impl true
  def handle_info(:do_monte_carlo, socket) do
    case Solver.monte_carlo(socket.assigns.current_vars) do
      {:ok, dist} ->
        {:noreply, assign(socket, distribution: dist, solving: false)}
      {:error, _reason} ->
        {:noreply, assign(socket, solving: false)}
    end
  end

  @impl true
  def handle_info({:data_updated, _source}, socket) do
    live = LiveState.get()
    {:noreply, assign(socket, :live_vars, live)}
  end

  @impl true
  def handle_info({:auto_result, result}, socket) do
    history = AmmoniaDesk.Scenarios.AutoRunner.history()
    socket =
      socket
      |> assign(:auto_result, result)
      |> assign(:agent_history, history)
    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div style="background:#080c14;color:#c8d6e5;min-height:100vh;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',monospace">
      <%# === TOP BAR === %>
      <div style="background:#0d1117;border-bottom:1px solid #1b2838;padding:10px 20px;display:flex;justify-content:space-between;align-items:center">
        <div style="display:flex;align-items:center;gap:12px">
          <div style={"width:8px;height:8px;border-radius:50%;background:#{if @auto_result, do: "#10b981", else: "#64748b"};box-shadow:0 0 8px #{if @auto_result, do: "#10b981", else: "transparent"}"}></div>
          <span style="font-size:14px;font-weight:700;color:#e2e8f0;letter-spacing:1px">AMMONIA BARGE SCENARIO DESK</span>
        </div>
        <div style="display:flex;align-items:center;gap:16px;font-size:12px">
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
        <%# === LEFT: VARIABLES === %>
        <div style="background:#0a0f18;border-right:1px solid #1b2838;overflow-y:auto;padding:14px">
          <%= for group <- [:environment, :operations, :commercial] do %>
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
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
              <button phx-click="solve" disabled={@solving}
                style="padding:10px;border:none;border-radius:6px;font-weight:700;font-size:12px;background:linear-gradient(135deg,#0891b2,#06b6d4);color:#fff;cursor:pointer;letter-spacing:1px">
                <%= if @solving, do: "⏳ SOLVING...", else: "⚡ SOLVE" %>
              </button>
              <button phx-click="monte_carlo" disabled={@solving}
                style="padding:10px;border:none;border-radius:6px;font-weight:700;font-size:12px;background:linear-gradient(135deg,#7c3aed,#8b5cf6);color:#fff;cursor:pointer;letter-spacing:1px">
                🎲 MONTE CARLO
              </button>
            </div>
            <button phx-click="reset"
              style="width:100%;padding:7px;border:1px solid #1e293b;border-radius:6px;font-weight:600;font-size:11px;background:transparent;color:#64748b;cursor:pointer;margin-top:8px">
              📡 RESET TO LIVE
            </button>
            <div style="text-align:center;margin-top:6px;font-size:10px;color:#334155">
              <%= MapSet.size(@overrides) %> override<%= if MapSet.size(@overrides) != 1, do: "s", else: "" %> active
            </div>
          </div>
        </div>

        <%# === RIGHT: TABS === %>
        <div style="overflow-y:auto;padding:16px">
          <%# Tab buttons %>
          <div style="display:flex;gap:2px;margin-bottom:16px">
            <button phx-click="switch_tab" phx-value-tab="trader"
              style={"padding:8px 16px;border:none;border-radius:6px 6px 0 0;font-size:12px;font-weight:600;cursor:pointer;background:#{if @active_tab == :trader, do: "#111827", else: "transparent"};color:#{if @active_tab == :trader, do: "#e2e8f0", else: "#475569"};border-bottom:2px solid #{if @active_tab == :trader, do: "#38bdf8", else: "transparent"}"}>
              ⚡ Trader
            </button>
            <button phx-click="switch_tab" phx-value-tab="agent"
              style={"padding:8px 16px;border:none;border-radius:6px 6px 0 0;font-size:12px;font-weight:600;cursor:pointer;background:#{if @active_tab == :agent, do: "#111827", else: "transparent"};color:#{if @active_tab == :agent, do: "#e2e8f0", else: "#475569"};border-bottom:2px solid #{if @active_tab == :agent, do: "#10b981", else: "transparent"}"}>
              🤖 Agent
            </button>
          </div>

          <%# === TRADER TAB === %>
          <%= if @active_tab == :trader do %>
            <%# Solve result %>
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
                <%# Routes %>
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

                <%# Percentile rank if MC has been run %>
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

            <%# Monte Carlo distribution %>
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

                <%# Sensitivity %>
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

            <%# Saved scenarios %>
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

          <%# === AGENT TAB === %>
          <%= if @active_tab == :agent do %>
            <%= if @auto_result do %>
              <%# Agent header %>
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

                <%# Signal + key metrics %>
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

                <%# Current live values %>
                <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px">CURRENT LIVE VALUES</div>
                <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-bottom:16px;font-size:12px">
                  <span>🌊 River: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :river_stage, 0.0), 1) %>ft</span></span>
                  <span>🌡 Temp: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :temp_f, 0.0), 0) %>°F</span></span>
                  <span>⛽ Gas: <span style="color:#38bdf8;font-weight:600">$<%= Float.round(Map.get(@auto_result.center, :nat_gas, 0.0), 2) %></span></span>
                  <span>🔒 Lock: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :lock_hrs, 0.0), 0) %>hrs</span></span>
                  <span>💨 Wind: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :wind_mph, 0.0), 0) %>mph</span></span>
                  <span>🏭 StL: <span style={"font-weight:600;color:#{if Map.get(@auto_result.center, :stl_outage), do: "#ef4444", else: "#10b981"}"}><%= if Map.get(@auto_result.center, :stl_outage), do: "OUTAGE", else: "ONLINE" %></span></span>
                </div>

                <%# What triggered this run %>
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

              <%# Distribution %>
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

              <%# Sensitivity %>
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

              <%# History %>
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
            <% else %>
              <div style="background:#111827;border-radius:10px;padding:40px;text-align:center;color:#475569">
                Agent is initializing...
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
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
    labels = %{
      river_stage: "River Stage", lock_hrs: "Lock Delays", temp_f: "Temperature",
      wind_mph: "Wind Speed", vis_mi: "Visibility", precip_in: "Precipitation",
      inv_don: "Don. Inventory", inv_geis: "Geis. Inventory",
      stl_outage: "StL Outage", mem_outage: "Mem Outage", barge_count: "Barge Count",
      nola_buy: "NH3 Buy Price", sell_stl: "StL Sell Price", sell_mem: "Mem Sell Price",
      fr_don_stl: "Fr Don→StL", fr_don_mem: "Fr Don→Mem",
      fr_geis_stl: "Fr Geis→StL", fr_geis_mem: "Fr Geis→Mem",
      nat_gas: "Nat Gas", working_cap: "Working Capital"
    }
    Map.get(labels, key, to_string(key))
  end

  defp trigger_label(:startup), do: "startup"
  defp trigger_label(:scheduled), do: "scheduled"
  defp trigger_label(:manual), do: "manual"
  defp trigger_label(:initial), do: "initial"
  defp trigger_label(key), do: sensitivity_label(key)

  defp format_trigger(%{key: key, old: nil}), do: trigger_label(key)
  defp format_trigger(%{key: key, old: old, new: new}) do
    delta = new - old
    sign = if delta > 0, do: "+", else: ""
    "#{trigger_label(key)}: #{Float.round(old, 1)} → #{Float.round(new, 1)} (#{sign}#{Float.round(delta, 1)})"
  end

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

  defp group_icon(:environment), do: "🌊"
  defp group_icon(:operations), do: "⚙️"
  defp group_icon(:commercial), do: "💰"

  defp format_var(%{key: :working_cap}, val), do: "$#{format_number(val)}"
  defp format_var(%{unit: unit, key: key}, val) when key in [:nat_gas, :river_stage, :vis_mi] do
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

  defp parse_value(key, value) when key in [:stl_outage, :mem_outage] do
    value == "true" or value == "1"
  end
  defp parse_value(_key, value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp parse_value(_key, value), do: value
end
