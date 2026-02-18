defmodule TradingDesk.ContractsLive do
  @moduledoc """
  Contract management LiveView with role-based tabs.

  Three roles, three views:
    - TRADER:     Strict gate dashboard, contract impact preview, currency report
    - LEGAL:      Clause review, template completeness, gate status, approve/reject
    - OPERATIONS: SAP validation, open position refresh, full pipeline triggers

  Each role sees only what they need. All roles see real-time PubSub updates
  as pipeline tasks complete in the background on the BEAM.
  """
  use Phoenix.LiveView

  alias TradingDesk.Contracts.{
    Store,
    Pipeline,
    LegalReview,
    Readiness,
    ConstraintBridge,
    TemplateRegistry,
    StrictGate,
    CurrencyTracker
  }

  @product_groups [:ammonia, :uan, :urea]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "contracts")
    end

    socket =
      socket
      |> assign(:role, :trader)
      |> assign(:product_group, :ammonia)
      |> assign(:product_groups, @product_groups)
      |> assign(:contracts, [])
      |> assign(:selected_contract, nil)
      |> assign(:readiness, nil)
      |> assign(:constraint_preview, nil)
      |> assign(:review_summary, nil)
      |> assign(:gate_report, nil)
      |> assign(:currency_report, nil)
      |> assign(:pipeline_status, nil)
      |> assign(:upload_error, nil)
      |> refresh_contracts()
      |> refresh_readiness()
      |> refresh_gate_report()
      |> refresh_currency()

    {:ok, socket}
  end

  # --- Events: Role & Navigation ---

  @impl true
  def handle_event("switch_role", %{"role" => role}, socket) do
    socket =
      socket
      |> assign(:role, String.to_existing_atom(role))
      |> assign(:selected_contract, nil)
      |> assign(:review_summary, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_product_group", %{"pg" => pg}, socket) do
    socket =
      socket
      |> assign(:product_group, String.to_existing_atom(pg))
      |> assign(:selected_contract, nil)
      |> refresh_contracts()
      |> refresh_readiness()
      |> refresh_gate_report()
      |> refresh_currency()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_contract", %{"id" => id}, socket) do
    case Store.get(id) do
      {:ok, contract} ->
        socket = assign(socket, :selected_contract, contract)

        socket =
          if socket.assigns.role == :legal do
            case LegalReview.review_summary(id) do
              {:ok, summary} -> assign(socket, :review_summary, summary)
              _ -> socket
            end
          else
            socket
          end

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # --- Events: Contract Ingestion (with template metadata) ---

  @impl true
  def handle_event("extract_contract", params, socket) do
    counterparty = Map.get(params, "counterparty", "") |> String.trim()
    cp_type = Map.get(params, "cp_type", "customer") |> String.to_existing_atom()
    file_path = Map.get(params, "file_path", "") |> String.trim()
    sap_id = Map.get(params, "sap_contract_id", "") |> String.trim()
    template_type = safe_atom(Map.get(params, "template_type", ""))
    incoterm = safe_atom(Map.get(params, "incoterm", ""))
    term_type = safe_atom(Map.get(params, "term_type", ""))
    company = safe_atom(Map.get(params, "company", ""))

    cond do
      counterparty == "" ->
        {:noreply, assign(socket, :upload_error, "Counterparty name is required")}

      file_path == "" ->
        {:noreply, assign(socket, :upload_error, "File path is required")}

      not File.exists?(file_path) ->
        {:noreply, assign(socket, :upload_error, "File not found: #{file_path}")}

      is_nil(template_type) ->
        {:noreply, assign(socket, :upload_error, "Contract type is required (purchase/sale/spot)")}

      true ->
        opts = [template_type: template_type]
        opts = if incoterm, do: [{:incoterm, incoterm} | opts], else: opts
        opts = if term_type, do: [{:term_type, term_type} | opts], else: opts
        opts = if company, do: [{:company, company} | opts], else: opts
        opts = if sap_id != "", do: [{:sap_contract_id, sap_id} | opts], else: opts

        Pipeline.full_extract_async(file_path, counterparty, cp_type, socket.assigns.product_group, opts)

        socket =
          socket
          |> assign(:pipeline_status, "Full chain: extracting #{Path.basename(file_path)}...")
          |> assign(:upload_error, nil)

        {:noreply, socket}
    end
  end

  # --- Events: Legal Review ---

  @impl true
  def handle_event("submit_for_review", %{"id" => id}, socket) do
    # Check Gate 1 before submission
    case Store.get(id) do
      {:ok, contract} ->
        case StrictGate.gate_extraction(contract) do
          {:pass, _} ->
            case LegalReview.submit_for_review(id) do
              {:ok, _} ->
                {:noreply, socket |> refresh_contracts() |> refresh_gate_report()
                  |> assign(:pipeline_status, "Submitted for legal review")}
              {:error, reason} ->
                {:noreply, assign(socket, :pipeline_status, "Submit failed: #{inspect(reason)}")}
            end

          {:fail, blockers, _} ->
            first = List.first(blockers)
            {:noreply, assign(socket, :pipeline_status, "Cannot submit: #{first.message}")}
        end
      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("approve_contract", %{"id" => id, "reviewer" => reviewer}, socket) do
    notes = Map.get(socket.assigns, :review_notes, "")

    case LegalReview.approve(id, reviewer, notes: notes) do
      {:ok, _} ->
        CurrencyTracker.stamp(id, :legal_reviewed_at)
        {:noreply, socket |> refresh_contracts() |> refresh_readiness()
          |> refresh_gate_report() |> refresh_currency()
          |> assign(:pipeline_status, "Contract approved")
          |> assign(:selected_contract, nil)}
      {:error, reason} ->
        {:noreply, assign(socket, :pipeline_status, "Approval failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reject_contract", %{"id" => id, "reviewer" => reviewer, "reason" => reason}, socket) do
    case LegalReview.reject(id, reviewer, reason) do
      {:ok, _} ->
        {:noreply, socket |> refresh_contracts()
          |> assign(:pipeline_status, "Contract rejected")
          |> assign(:selected_contract, nil)}
      {:error, reason} ->
        {:noreply, assign(socket, :pipeline_status, "Rejection failed: #{inspect(reason)}")}
    end
  end

  # --- Events: Operations (SAP) ---

  @impl true
  def handle_event("validate_sap", %{"id" => id}, socket) do
    Pipeline.validate_sap_async(id)
    {:noreply, assign(socket, :pipeline_status, "SAP validation running...")}
  end

  @impl true
  def handle_event("validate_all_sap", _params, socket) do
    Pipeline.validate_product_group_async(socket.assigns.product_group)
    {:noreply, assign(socket, :pipeline_status, "Validating all contracts against SAP...")}
  end

  @impl true
  def handle_event("refresh_positions", _params, socket) do
    Pipeline.refresh_positions_async(socket.assigns.product_group)
    {:noreply, assign(socket, :pipeline_status, "Refreshing open positions from SAP...")}
  end

  @impl true
  def handle_event("validate_all_templates", _params, socket) do
    Pipeline.validate_templates_async(socket.assigns.product_group)
    {:noreply, assign(socket, :pipeline_status, "Validating all templates...")}
  end

  # --- Events: Trader ---

  @impl true
  def handle_event("preview_constraints", _params, socket) do
    vars = TradingDesk.Data.LiveState.get()
    preview = ConstraintBridge.preview_constraints(vars, socket.assigns.product_group)
    {:noreply, assign(socket, :constraint_preview, preview)}
  end

  @impl true
  def handle_event("check_readiness", _params, socket) do
    {:noreply, socket |> refresh_readiness() |> refresh_gate_report() |> refresh_currency()}
  end

  # --- PubSub: Pipeline events ---

  @impl true
  def handle_info({:contract_event, event, payload}, socket) do
    status_msg = format_pipeline_event(event, payload)

    socket =
      socket
      |> assign(:pipeline_status, status_msg)
      |> refresh_contracts()
      |> refresh_readiness()
      |> refresh_gate_report()
      |> refresh_currency()

    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div style="background:#080c14;color:#c8d6e5;min-height:100vh;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',monospace">
      <%!-- === TOP BAR === --%>
      <div style="background:#0d1117;border-bottom:1px solid #1b2838;padding:10px 20px;display:flex;justify-content:space-between;align-items:center">
        <div style="display:flex;align-items:center;gap:12px">
          <a href="/" style="color:#64748b;text-decoration:none;font-size:12px">&larr; DESK</a>
          <span style="font-size:14px;font-weight:700;color:#e2e8f0;letter-spacing:1px">CONTRACT MANAGEMENT</span>
        </div>
        <div style="display:flex;align-items:center;gap:8px">
          <%= for pg <- @product_groups do %>
            <button phx-click="switch_product_group" phx-value-pg={pg}
              style={"padding:4px 12px;border-radius:4px;font-size:11px;font-weight:600;cursor:pointer;border:1px solid #{if @product_group == pg, do: "#38bdf8", else: "#1e293b"};background:#{if @product_group == pg, do: "#0c4a6e", else: "transparent"};color:#{if @product_group == pg, do: "#38bdf8", else: "#64748b"}"}>
              <%= pg |> to_string() |> String.upcase() %>
            </button>
          <% end %>
        </div>
      </div>

      <%!-- === ROLE TABS === --%>
      <div style="background:#0d1117;border-bottom:1px solid #1b2838;padding:0 20px;display:flex;gap:2px">
        <%= for {role, label, icon, color} <- [{:trader, "Trader", "📊", "#38bdf8"}, {:legal, "Legal", "⚖️", "#a78bfa"}, {:operations, "Operations", "🏭", "#f59e0b"}] do %>
          <button phx-click="switch_role" phx-value-role={role}
            style={"padding:10px 20px;border:none;font-size:12px;font-weight:600;cursor:pointer;background:#{if @role == role, do: "#111827", else: "transparent"};color:#{if @role == role, do: color, else: "#475569"};border-bottom:2px solid #{if @role == role, do: color, else: "transparent"}"}>
            <%= icon %> <%= label %>
          </button>
        <% end %>
      </div>

      <%!-- === PIPELINE STATUS BAR === --%>
      <%= if @pipeline_status do %>
        <div style="background:#0f1729;border-bottom:1px solid #1e293b;padding:8px 20px;font-size:12px;color:#38bdf8;display:flex;align-items:center;gap:8px">
          <div style="width:6px;height:6px;border-radius:50%;background:#38bdf8"></div>
          <%= @pipeline_status %>
        </div>
      <% end %>

      <div style="display:grid;grid-template-columns:400px 1fr;height:calc(100vh - 100px)">
        <%!-- === LEFT: CONTRACT LIST + INGEST === --%>
        <div style="background:#0a0f18;border-right:1px solid #1b2838;overflow-y:auto;padding:14px">
          <%!-- Ingest form with template metadata --%>
          <div style="margin-bottom:16px;padding:12px;background:#111827;border-radius:8px">
            <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:8px">INGEST CONTRACT</div>
            <form phx-submit="extract_contract">
              <input type="text" name="counterparty" placeholder="Counterparty name..." style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px;margin-bottom:6px" />
              <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-bottom:6px">
                <select name="cp_type" style="background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px">
                  <option value="customer">Customer</option>
                  <option value="supplier">Supplier</option>
                </select>
                <select name="template_type" style="background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px">
                  <option value="">-- Type --</option>
                  <option value="purchase">Purchase</option>
                  <option value="sale">Sale</option>
                  <option value="spot_purchase">Spot Purchase</option>
                  <option value="spot_sale">Spot Sale</option>
                </select>
              </div>
              <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-bottom:6px">
                <select name="incoterm" style="background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px">
                  <option value="">-- Incoterm --</option>
                  <option value="fob">FOB</option>
                  <option value="cif">CIF</option>
                  <option value="cfr">CFR</option>
                  <option value="dap">DAP</option>
                  <option value="ddp">DDP</option>
                  <option value="fca">FCA</option>
                  <option value="exw">EXW</option>
                </select>
                <select name="term_type" style="background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px">
                  <option value="">-- Term --</option>
                  <option value="spot">Spot</option>
                  <option value="long_term">Long Term</option>
                </select>
              </div>
              <select name="company" style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px;margin-bottom:6px">
                <option value="">-- Company Entity --</option>
                <option value="trammo_inc">Trammo, Inc. — Ammonia Division</option>
                <option value="trammo_sas">Trammo SAS</option>
                <option value="trammo_dmcc">Trammo DMCC</option>
              </select>
              <input type="text" name="file_path" placeholder="File path (PDF/DOCX/DOCM)..." style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px;margin-bottom:6px" />
              <input type="text" name="sap_contract_id" placeholder="SAP Contract # (optional)" style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px;margin-bottom:6px" />
              <button type="submit" style="width:100%;padding:8px;border:none;border-radius:4px;font-weight:600;font-size:11px;background:linear-gradient(135deg,#0c4a6e,#1e3a5f);color:#38bdf8;cursor:pointer">
                FULL EXTRACT CHAIN
              </button>
            </form>
            <%= if @upload_error do %>
              <div style="color:#ef4444;font-size:11px;margin-top:6px"><%= @upload_error %></div>
            <% end %>
          </div>

          <%!-- Contract list --%>
          <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:8px">
            CONTRACTS — <%= @product_group |> to_string() |> String.upcase() %>
            <span style="color:#475569">(<%= length(@contracts) %>)</span>
          </div>
          <%= for contract <- @contracts do %>
            <div phx-click="select_contract" phx-value-id={contract.id}
              style={"padding:10px;margin-bottom:4px;border-radius:6px;cursor:pointer;border-left:3px solid #{status_color(contract.status)};background:#{if @selected_contract && @selected_contract.id == contract.id, do: "#1e293b", else: "#111827"}"}>
              <div style="display:flex;justify-content:space-between;align-items:center">
                <span style="font-size:12px;font-weight:600;color:#e2e8f0"><%= contract.counterparty %></span>
                <span style={"font-size:10px;font-weight:700;padding:2px 6px;border-radius:3px;background:#{status_bg(contract.status)};color:#{status_color(contract.status)}"}>
                  <%= contract.status |> to_string() |> String.upcase() |> String.replace("_", " ") %>
                </span>
              </div>
              <div style="display:flex;justify-content:space-between;margin-top:4px;font-size:10px;color:#64748b">
                <span>v<%= contract.version %> | <%= fmt_atom(contract.template_type) %> <%= fmt_atom(contract.incoterm) %></span>
                <span><%= length(contract.clauses || []) %> clauses</span>
              </div>
              <div style="display:flex;gap:6px;margin-top:3px;font-size:10px">
                <span style={"color:#{if contract.sap_validated, do: "#10b981", else: "#64748b"}"}><%= if contract.sap_validated, do: "SAP✓", else: "SAP?" %></span>
                <%= if contract.template_validation do %>
                  <span style={"color:#{if contract.template_validation.blocks_submission, do: "#ef4444", else: "#10b981"}"}><%= Float.round(contract.template_validation.completeness_pct, 0) %>%</span>
                <% end %>
                <%= if contract.company do %>
                  <span style="color:#475569"><%= fmt_company(contract.company) %></span>
                <% end %>
                <%= if contract.open_position do %>
                  <span style="color:#38bdf8"><%= format_number(contract.open_position) %>t</span>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- === RIGHT: ROLE-SPECIFIC PANEL === --%>
        <div style="overflow-y:auto;padding:16px">
          <%= if @role == :trader do %>
            <%= render_trader_panel(assigns) %>
          <% end %>
          <%= if @role == :legal do %>
            <%= render_legal_panel(assigns) %>
          <% end %>
          <%= if @role == :operations do %>
            <%= render_operations_panel(assigns) %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # === TRADER PANEL ===

  defp render_trader_panel(assigns) do
    ~H"""
    <%!-- Master gate (Gate 4) --%>
    <div style="background:#111827;border-radius:10px;padding:20px;margin-bottom:16px">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
        <span style="font-size:14px;font-weight:700;color:#e2e8f0">MASTER GATE (Gate 4)</span>
        <button phx-click="check_readiness"
          style="padding:6px 14px;border:1px solid #1e293b;border-radius:4px;font-size:11px;font-weight:600;background:transparent;color:#38bdf8;cursor:pointer">
          REFRESH ALL
        </button>
      </div>

      <%= if @gate_report do %>
        <div style={"display:flex;align-items:center;gap:12px;padding:14px;border-radius:8px;margin-bottom:16px;background:#{if @gate_report.all_passing, do: "#052e16", else: "#1c1917"};border:1px solid #{if @gate_report.all_passing, do: "#166534", else: "#78350f"}"}>
          <div style={"width:14px;height:14px;border-radius:50%;background:#{if @gate_report.all_passing, do: "#10b981", else: "#f59e0b"}"}></div>
          <div>
            <div style={"font-size:16px;font-weight:800;color:#{if @gate_report.all_passing, do: "#10b981", else: "#f59e0b"}"}>
              <%= if @gate_report.all_passing, do: "READY TO OPTIMIZE", else: "NOT READY" %>
            </div>
            <div style="font-size:11px;color:#94a3b8;margin-top:2px">
              <%= @gate_report.active_contracts %>/<%= @gate_report.total_contracts %> active |
              <%= length(@gate_report.master_blockers) %> blocker(s)
            </div>
          </div>
        </div>

        <%!-- Per-contract gate status --%>
        <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:8px">CONTRACT GATE STATUS</div>
        <table style="width:100%;border-collapse:collapse;font-size:11px;margin-bottom:16px">
          <thead><tr style="border-bottom:1px solid #1e293b">
            <th style="text-align:left;padding:4px;color:#64748b">Counterparty</th>
            <th style="text-align:left;padding:4px;color:#64748b">Type</th>
            <th style="text-align:center;padding:4px;color:#64748b">G1</th>
            <th style="text-align:center;padding:4px;color:#64748b">G2</th>
            <th style="text-align:center;padding:4px;color:#64748b">G3</th>
            <th style="text-align:right;padding:4px;color:#64748b">Blockers</th>
          </tr></thead>
          <tbody>
            <%= for cr <- @gate_report.contracts do %>
              <tr style="border-bottom:1px solid #1e293b11">
                <td style="padding:4px;color:#e2e8f0;font-weight:600"><%= cr.counterparty %> v<%= cr.version %></td>
                <td style="padding:4px;color:#64748b"><%= fmt_atom(cr.template_type) %> <%= fmt_atom(cr.incoterm) %></td>
                <td style={"padding:4px;text-align:center;color:#{gate_color(cr.gate1_extraction)}"}><%= gate_icon(cr.gate1_extraction) %></td>
                <td style={"padding:4px;text-align:center;color:#{gate_color(cr.gate2_review)}"}><%= gate_icon(cr.gate2_review) %></td>
                <td style={"padding:4px;text-align:center;color:#{gate_color(cr.gate3_activation)}"}><%= gate_icon(cr.gate3_activation) %></td>
                <td style="padding:4px;text-align:right;color:#f59e0b"><%= length(cr.blockers) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <%!-- Master blockers --%>
        <%= if length(@gate_report.master_blockers) > 0 do %>
          <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:8px">MASTER GATE BLOCKERS</div>
          <%= for b <- @gate_report.master_blockers do %>
            <div style="padding:8px 12px;margin-bottom:4px;border-radius:4px;background:#1c1917;border-left:3px solid #f59e0b;font-size:12px">
              <div style="color:#fbbf24;font-weight:600"><%= b.gate |> to_string() |> String.upcase() %> / <%= b.code %></div>
              <div style="color:#c8d6e5;margin-top:2px"><%= b.message %></div>
            </div>
          <% end %>
        <% end %>
      <% end %>
    </div>

    <%!-- Currency report --%>
    <%= if @currency_report do %>
      <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
          <span style="font-size:11px;color:#64748b;letter-spacing:1px">DATA CURRENCY</span>
          <span style={"font-size:11px;font-weight:700;color:#{if @currency_report.all_current, do: "#10b981", else: "#f59e0b"}"}>
            <%= if @currency_report.all_current, do: "ALL CURRENT", else: "#{@currency_report.stale} STALE" %>
          </span>
        </div>
        <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:6px">
          <div style="background:#0a0f18;padding:8px;border-radius:4px;text-align:center">
            <div style="font-size:10px;color:#64748b">Current</div>
            <div style={"font-size:18px;font-weight:700;color:#{if @currency_report.fully_current == @currency_report.total_contracts, do: "#10b981", else: "#f59e0b"}"}><%= @currency_report.fully_current %>/<%= @currency_report.total_contracts %></div>
          </div>
          <div style="background:#0a0f18;padding:8px;border-radius:4px;text-align:center">
            <div style="font-size:10px;color:#64748b">Stale</div>
            <div style={"font-size:18px;font-weight:700;color:#{if @currency_report.stale > 0, do: "#ef4444", else: "#10b981"}"}><%= @currency_report.stale %></div>
          </div>
          <div style="background:#0a0f18;padding:8px;border-radius:4px;text-align:center">
            <div style="font-size:10px;color:#64748b">PG Refresh</div>
            <% pg_fresh = Enum.all?(@currency_report.product_group_stamps, fn {_, v} -> not v.stale end) %>
            <div style={"font-size:18px;font-weight:700;color:#{if pg_fresh, do: "#10b981", else: "#f59e0b"}"}><%= if pg_fresh, do: "OK", else: "STALE" %></div>
          </div>
        </div>
      </div>
    <% end %>

    <%!-- Contract constraint preview --%>
    <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
        <span style="font-size:11px;color:#64748b;letter-spacing:1px">CONTRACT IMPACT PREVIEW</span>
        <button phx-click="preview_constraints"
          style="padding:4px 10px;border:1px solid #1e293b;border-radius:4px;font-size:10px;background:transparent;color:#a78bfa;cursor:pointer">
          PREVIEW
        </button>
      </div>
      <%= if @constraint_preview && length(@constraint_preview) > 0 do %>
        <table style="width:100%;border-collapse:collapse;font-size:11px">
          <thead><tr style="border-bottom:1px solid #1e293b">
            <th style="text-align:left;padding:4px;color:#64748b">Counterparty</th>
            <th style="text-align:left;padding:4px;color:#64748b">Parameter</th>
            <th style="text-align:right;padding:4px;color:#64748b">Current</th>
            <th style="text-align:center;padding:4px;color:#64748b">Op</th>
            <th style="text-align:right;padding:4px;color:#64748b">Contract</th>
            <th style="text-align:right;padding:4px;color:#64748b">Applied</th>
          </tr></thead>
          <tbody>
            <%= for p <- @constraint_preview do %>
              <tr style={"border-bottom:1px solid #1e293b11;background:#{if p.would_change, do: "#1a1a2e", else: "transparent"}"}>
                <td style="padding:4px;color:#94a3b8"><%= p.counterparty %></td>
                <td style="padding:4px;color:#e2e8f0"><%= p.parameter %></td>
                <td style="padding:4px;text-align:right;font-family:monospace"><%= format_val(p.current_value) %></td>
                <td style="padding:4px;text-align:center;color:#64748b"><%= p.operator %></td>
                <td style="padding:4px;text-align:right;font-family:monospace;color:#a78bfa"><%= format_val(p.clause_value) %></td>
                <td style={"padding:4px;text-align:right;font-family:monospace;font-weight:#{if p.would_change, do: "700", else: "400"};color:#{if p.would_change, do: "#f59e0b", else: "#64748b"}"}><%= format_val(p.proposed_value) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% else %>
        <div style="font-size:12px;color:#475569;font-style:italic">Click PREVIEW to see how contracts modify solver inputs</div>
      <% end %>
    </div>
    """
  end

  # === LEGAL PANEL ===

  defp render_legal_panel(assigns) do
    ~H"""
    <%= if @selected_contract do %>
      <% c = @selected_contract %>
      <%!-- Contract header --%>
      <div style="background:#111827;border-radius:10px;padding:20px;margin-bottom:16px">
        <div style="display:flex;justify-content:space-between;align-items:flex-start">
          <div>
            <div style="font-size:18px;font-weight:700;color:#e2e8f0"><%= c.counterparty %></div>
            <div style="font-size:12px;color:#64748b;margin-top:2px">
              <%= fmt_atom(c.template_type) %> | <%= fmt_atom(c.incoterm) %> | <%= fmt_atom(c.term_type) %> | v<%= c.version %> | <%= c.source_file %>
            </div>
            <%= if c.company do %>
              <div style="font-size:11px;color:#475569;margin-top:2px"><%= TemplateRegistry.company_label(c.company) %></div>
            <% end %>
          </div>
          <span style={"font-size:12px;font-weight:700;padding:4px 10px;border-radius:4px;background:#{status_bg(c.status)};color:#{status_color(c.status)}"}>
            <%= c.status |> to_string() |> String.upcase() |> String.replace("_", " ") %>
          </span>
        </div>

        <%!-- Template completeness --%>
        <%= if c.template_validation do %>
          <div style="margin-top:16px;padding:12px;border-radius:6px;background:#0a0f18;border:1px solid #1e293b">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
              <span style="font-size:11px;color:#64748b;letter-spacing:1px">TEMPLATE COMPLETENESS</span>
              <span style={"font-size:14px;font-weight:700;color:#{if c.template_validation.completeness_pct >= 100, do: "#10b981", else: if c.template_validation.blocks_submission, do: "#ef4444", else: "#f59e0b"}"}><%= Float.round(c.template_validation.completeness_pct, 0) %>%</span>
            </div>
            <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:6px;font-size:11px">
              <div style="text-align:center"><span style="color:#64748b">Required</span><br/><span style={"font-weight:700;color:#{if c.template_validation.required_met == c.template_validation.required_total, do: "#10b981", else: "#ef4444"}"}><%= c.template_validation.required_met %>/<%= c.template_validation.required_total %></span></div>
              <div style="text-align:center"><span style="color:#64748b">Expected</span><br/><span style={"font-weight:700;color:#{if c.template_validation.expected_met == c.template_validation.expected_total, do: "#10b981", else: "#f59e0b"}"}><%= c.template_validation.expected_met %>/<%= c.template_validation.expected_total %></span></div>
              <div style="text-align:center"><span style="color:#64748b">SAP</span><br/><span style={"font-weight:700;color:#{if c.sap_validated, do: "#10b981", else: "#64748b"}"}><%= if c.sap_validated, do: "✓", else: "?" %></span></div>
              <div style="text-align:center"><span style="color:#64748b">Blocks</span><br/><span style={"font-weight:700;color:#{if c.template_validation.blocks_submission, do: "#ef4444", else: "#10b981"}"}><%= if c.template_validation.blocks_submission, do: "YES", else: "NO" %></span></div>
            </div>
            <%!-- Template findings --%>
            <%= if length(c.template_validation.findings) > 0 do %>
              <div style="margin-top:10px">
                <%= for f <- c.template_validation.findings do %>
                  <div style={"padding:4px 8px;margin-bottom:2px;font-size:10px;border-left:2px solid #{finding_color(f.level)};color:#{finding_color(f.level)}"}>
                    <%= f.message %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- LLM validation --%>
        <%= if c.llm_validation do %>
          <div style="margin-top:8px;padding:8px 12px;border-radius:6px;background:#0a0f18;border:1px solid #1e293b;font-size:11px">
            <span style="color:#64748b">LLM Verify:</span>
            <span style={"font-weight:600;color:#{if c.llm_validation.errors > 0, do: "#ef4444", else: "#10b981"}"}><%= c.llm_validation.errors %> errors</span>,
            <span style={"color:#{if c.llm_validation.warnings > 0, do: "#f59e0b", else: "#64748b"}"}><%= c.llm_validation.warnings %> warnings</span>
          </div>
        <% end %>

        <%!-- Action buttons --%>
        <%= if c.status == :draft do %>
          <div style="margin-top:16px">
            <button phx-click="submit_for_review" phx-value-id={c.id}
              style={"padding:8px 20px;border:none;border-radius:4px;font-weight:600;font-size:12px;cursor:pointer;background:#{if c.template_validation && c.template_validation.blocks_submission, do: "#1e293b", else: "#7c3aed"};color:#{if c.template_validation && c.template_validation.blocks_submission, do: "#64748b", else: "#fff"}"}>
              <%= if c.template_validation && c.template_validation.blocks_submission do %>
                BLOCKED — MISSING REQUIRED CLAUSES
              <% else %>
                SUBMIT FOR LEGAL REVIEW
              <% end %>
            </button>
          </div>
        <% end %>

        <%= if c.status == :pending_review do %>
          <div style="display:flex;gap:8px;margin-top:16px;flex-wrap:wrap">
            <form phx-submit="approve_contract" style="display:flex;gap:8px">
              <input type="hidden" name="id" value={c.id} />
              <input type="text" name="reviewer" placeholder="Your name..."
                style="background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 10px;border-radius:4px;font-size:11px" />
              <button type="submit"
                style="padding:8px 20px;border:none;border-radius:4px;font-weight:600;font-size:12px;background:#059669;color:#fff;cursor:pointer">
                APPROVE
              </button>
            </form>
            <form phx-submit="reject_contract" style="display:flex;gap:8px">
              <input type="hidden" name="id" value={c.id} />
              <input type="text" name="reviewer" placeholder="Your name..."
                style="background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 10px;border-radius:4px;font-size:11px" />
              <input type="text" name="reason" placeholder="Rejection reason..."
                style="background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 10px;border-radius:4px;font-size:11px;flex:1" />
              <button type="submit"
                style="padding:8px 20px;border:none;border-radius:4px;font-weight:600;font-size:12px;background:#dc2626;color:#fff;cursor:pointer">
                REJECT
              </button>
            </form>
          </div>
        <% end %>
      </div>

      <%!-- SAP discrepancies --%>
      <%= if c.sap_discrepancies && length(c.sap_discrepancies) > 0 do %>
        <div style="background:#1c1917;border:1px solid #78350f;border-radius:8px;padding:14px;margin-bottom:16px">
          <div style="font-size:11px;color:#fbbf24;letter-spacing:1px;margin-bottom:8px">SAP DISCREPANCIES (<%= length(c.sap_discrepancies) %>)</div>
          <%= for d <- c.sap_discrepancies do %>
            <div style="padding:6px 0;border-bottom:1px solid #78350f22;font-size:12px">
              <span style={"font-weight:600;color:#{if d.severity == :high, do: "#ef4444", else: "#fbbf24"}"}>
                [<%= d.severity |> to_string() |> String.upcase() %>]
              </span>
              <span style="color:#c8d6e5;margin-left:6px"><%= d.message %></span>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Clause list --%>
      <div style="background:#111827;border-radius:10px;padding:16px">
        <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:10px">EXTRACTED CLAUSES (<%= length(c.clauses || []) %>)</div>
        <%= for clause <- (c.clauses || []) do %>
          <div style={"padding:12px;margin-bottom:6px;border-radius:6px;background:#0a0f18;border-left:3px solid #{confidence_color(clause.confidence)}"}>
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px">
              <span style="font-size:11px;font-weight:700;color:#e2e8f0">
                <%= clause.type |> to_string() |> String.upcase() %>
                <%= if clause.parameter do %>
                  <span style="color:#38bdf8;font-weight:400;margin-left:6px"><%= clause.parameter %></span>
                <% end %>
              </span>
              <div style="display:flex;gap:6px;align-items:center">
                <span style={"font-size:10px;padding:2px 6px;border-radius:3px;background:#{confidence_bg(clause.confidence)};color:#{confidence_color(clause.confidence)}"}>
                  <%= clause.confidence %>
                </span>
                <span style="font-size:10px;color:#475569"><%= clause.reference_section %></span>
              </div>
            </div>
            <%= if clause.value do %>
              <div style="display:flex;gap:16px;margin-bottom:6px;font-size:12px">
                <%= if clause.operator do %>
                  <span style="color:#64748b"><%= clause.operator %> <span style="color:#e2e8f0;font-family:monospace;font-weight:600"><%= format_val(clause.value) %></span> <span style="color:#64748b"><%= clause.unit %></span></span>
                <% end %>
                <%= if clause.penalty_per_unit do %>
                  <span style="color:#ef4444">Penalty: $<%= clause.penalty_per_unit %>/<%= clause.unit || "unit" %></span>
                <% end %>
                <%= if clause.period do %>
                  <span style="color:#64748b"><%= clause.period %></span>
                <% end %>
              </div>
            <% end %>
            <div style="font-size:11px;color:#94a3b8;line-height:1.4;font-style:italic;border-top:1px solid #1e293b;padding-top:6px">
              "<%= String.slice(clause.description, 0, 300) %><%= if String.length(clause.description) > 300, do: "..." %>"
            </div>
          </div>
        <% end %>
      </div>
    <% else %>
      <div style="background:#111827;border-radius:10px;padding:40px;text-align:center;color:#475569">
        Select a contract from the list to review
      </div>
    <% end %>
    """
  end

  # === OPERATIONS PANEL ===

  defp render_operations_panel(assigns) do
    ~H"""
    <%!-- Batch actions --%>
    <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
      <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:12px">
        OPERATIONS — <%= @product_group |> to_string() |> String.upcase() %>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px">
        <button phx-click="validate_all_templates"
          style="padding:10px;border:none;border-radius:6px;font-weight:600;font-size:11px;background:#312e81;color:#a78bfa;cursor:pointer">
          VALIDATE TEMPLATES
        </button>
        <button phx-click="validate_all_sap"
          style="padding:10px;border:none;border-radius:6px;font-weight:600;font-size:11px;background:#92400e;color:#fbbf24;cursor:pointer">
          VALIDATE ALL SAP
        </button>
        <button phx-click="refresh_positions"
          style="padding:10px;border:none;border-radius:6px;font-weight:600;font-size:11px;background:#0c4a6e;color:#38bdf8;cursor:pointer">
          REFRESH POSITIONS
        </button>
      </div>
    </div>

    <%!-- Selected contract detail --%>
    <%= if @selected_contract do %>
      <% c = @selected_contract %>
      <div style="background:#111827;border-radius:10px;padding:20px;margin-bottom:16px">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
          <div>
            <div style="font-size:16px;font-weight:700;color:#e2e8f0"><%= c.counterparty %></div>
            <div style="font-size:12px;color:#64748b">
              SAP: <%= c.sap_contract_id || "not linked" %> |
              <%= fmt_atom(c.template_type) %> <%= fmt_atom(c.incoterm) %> |
              <%= if c.company, do: fmt_company(c.company), else: "—" %>
            </div>
          </div>
          <button phx-click="validate_sap" phx-value-id={c.id}
            style="padding:6px 14px;border:1px solid #78350f;border-radius:4px;font-size:11px;font-weight:600;background:transparent;color:#fbbf24;cursor:pointer">
            VALIDATE SAP
          </button>
        </div>

        <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:16px">
          <div style={"background:#0a0f18;padding:10px;border-radius:6px;text-align:center;border:1px solid #{if c.sap_validated, do: "#166534", else: "#1e293b"}"}>
            <div style="font-size:10px;color:#64748b">SAP Validated</div>
            <div style={"font-size:16px;font-weight:700;color:#{if c.sap_validated, do: "#10b981", else: "#64748b"}"}><%= if c.sap_validated, do: "YES", else: "NO" %></div>
          </div>
          <div style="background:#0a0f18;padding:10px;border-radius:6px;text-align:center">
            <div style="font-size:10px;color:#64748b">Open Position</div>
            <div style="font-size:16px;font-weight:700;color:#38bdf8"><%= if c.open_position, do: "#{format_number(c.open_position)}t", else: "—" %></div>
          </div>
          <div style="background:#0a0f18;padding:10px;border-radius:6px;text-align:center">
            <div style="font-size:10px;color:#64748b">Discrepancies</div>
            <div style={"font-size:16px;font-weight:700;color:#{if length(c.sap_discrepancies || []) > 0, do: "#f59e0b", else: "#10b981"}"}><%= length(c.sap_discrepancies || []) %></div>
          </div>
        </div>

        <%= if c.sap_discrepancies && length(c.sap_discrepancies) > 0 do %>
          <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:8px">DISCREPANCIES</div>
          <table style="width:100%;border-collapse:collapse;font-size:11px">
            <thead><tr style="border-bottom:1px solid #1e293b">
              <th style="text-align:left;padding:4px;color:#64748b">Field</th>
              <th style="text-align:left;padding:4px;color:#64748b">Severity</th>
              <th style="text-align:right;padding:4px;color:#64748b">Contract</th>
              <th style="text-align:right;padding:4px;color:#64748b">SAP</th>
              <th style="text-align:left;padding:4px;color:#64748b">Message</th>
            </tr></thead>
            <tbody>
              <%= for d <- c.sap_discrepancies do %>
                <tr style="border-bottom:1px solid #1e293b11">
                  <td style="padding:6px 4px;color:#e2e8f0"><%= inspect(d.field) %></td>
                  <td style={"padding:6px 4px;font-weight:600;color:#{if d.severity == :high, do: "#ef4444", else: "#fbbf24"}"}><%= d.severity %></td>
                  <td style="padding:6px 4px;text-align:right;font-family:monospace"><%= inspect(Map.get(d, :contract_value)) %></td>
                  <td style="padding:6px 4px;text-align:right;font-family:monospace"><%= inspect(Map.get(d, :sap_value)) %></td>
                  <td style="padding:6px 4px;color:#94a3b8;font-size:10px"><%= d.message %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>

        <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-top:16px;margin-bottom:8px">EXTRACTED COMMERCIAL TERMS</div>
        <table style="width:100%;border-collapse:collapse;font-size:11px">
          <thead><tr style="border-bottom:1px solid #1e293b">
            <th style="text-align:left;padding:4px;color:#64748b">Type</th>
            <th style="text-align:left;padding:4px;color:#64748b">Parameter</th>
            <th style="text-align:center;padding:4px;color:#64748b">Op</th>
            <th style="text-align:right;padding:4px;color:#64748b">Value</th>
            <th style="text-align:left;padding:4px;color:#64748b">Unit</th>
            <th style="text-align:center;padding:4px;color:#64748b">Conf</th>
          </tr></thead>
          <tbody>
            <%= for clause <- (c.clauses || []) do %>
              <tr style="border-bottom:1px solid #1e293b11">
                <td style="padding:4px"><%= clause.type %></td>
                <td style="padding:4px;color:#e2e8f0"><%= clause.parameter %></td>
                <td style="padding:4px;text-align:center"><%= clause.operator %></td>
                <td style="padding:4px;text-align:right;font-family:monospace;font-weight:600"><%= format_val(clause.value) %></td>
                <td style="padding:4px;color:#64748b"><%= clause.unit %></td>
                <td style={"padding:4px;text-align:center;color:#{confidence_color(clause.confidence)}"}><%= clause.confidence %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% else %>
      <div style="background:#111827;border-radius:10px;padding:40px;text-align:center;color:#475569">
        Select a contract to review SAP alignment
      </div>
    <% end %>
    """
  end

  # --- Private helpers ---

  defp refresh_contracts(socket) do
    contracts = Store.list_by_product_group(socket.assigns.product_group)
    assign(socket, :contracts, contracts)
  end

  defp refresh_readiness(socket) do
    readiness = Readiness.check(socket.assigns.product_group)
    assign(socket, :readiness, readiness)
  end

  defp refresh_gate_report(socket) do
    report = StrictGate.full_report(socket.assigns.product_group)
    assign(socket, :gate_report, report)
  end

  defp refresh_currency(socket) do
    report = CurrencyTracker.currency_report(socket.assigns.product_group)
    assign(socket, :currency_report, report)
  end

  # Pipeline event formatting
  defp format_pipeline_event(:extraction_started, p), do: "Extracting #{p.file} for #{p.counterparty}..."
  defp format_pipeline_event(:extraction_complete, p), do: "Extracted #{p.clause_count} clauses from #{p.counterparty} v#{p.version}"
  defp format_pipeline_event(:extraction_failed, p), do: "Extraction failed: #{p.reason}"
  defp format_pipeline_event(:template_validation_complete, _), do: "Template validation complete"
  defp format_pipeline_event(:llm_validation_complete, _), do: "LLM verification complete"
  defp format_pipeline_event(:sap_validation_started, _), do: "Running SAP validation..."
  defp format_pipeline_event(:sap_validation_complete, p), do: "SAP validation: #{p.discrepancy_count} discrepancies"
  defp format_pipeline_event(:sap_validation_failed, p), do: "SAP validation failed: #{p.reason}"
  defp format_pipeline_event(:positions_refresh_started, _), do: "Refreshing positions..."
  defp format_pipeline_event(:positions_refresh_complete, p), do: "Positions: #{p.succeeded}/#{p.total} refreshed"
  defp format_pipeline_event(:full_chain_started, p), do: "Full chain: #{p.counterparty}..."
  defp format_pipeline_event(:full_chain_complete, p), do: "Full chain complete: #{p.counterparty} (Gate 1: #{p.gate1})"
  defp format_pipeline_event(:full_chain_failed, p), do: "Full chain failed: #{p.reason}"
  defp format_pipeline_event(:full_pg_chain_started, _), do: "Full product group refresh started..."
  defp format_pipeline_event(:full_pg_chain_complete, _), do: "Full product group refresh complete"
  defp format_pipeline_event(:product_group_extraction_complete, p), do: "Extracted #{p.total} contracts"
  defp format_pipeline_event(:product_group_validation_complete, _), do: "SAP validation complete"
  defp format_pipeline_event(:product_group_template_validation_complete, _), do: "Template validation complete"
  defp format_pipeline_event(event, _), do: "#{event}"

  # Colors
  defp status_color(:draft), do: "#64748b"
  defp status_color(:pending_review), do: "#a78bfa"
  defp status_color(:approved), do: "#10b981"
  defp status_color(:rejected), do: "#ef4444"
  defp status_color(:superseded), do: "#475569"
  defp status_color(_), do: "#64748b"

  defp status_bg(:draft), do: "#1e293b"
  defp status_bg(:pending_review), do: "#1e1b4b"
  defp status_bg(:approved), do: "#052e16"
  defp status_bg(:rejected), do: "#450a0a"
  defp status_bg(:superseded), do: "#0f172a"
  defp status_bg(_), do: "#1e293b"

  defp confidence_color(:high), do: "#10b981"
  defp confidence_color(:medium), do: "#f59e0b"
  defp confidence_color(:low), do: "#ef4444"
  defp confidence_color(_), do: "#64748b"

  defp confidence_bg(:high), do: "#052e16"
  defp confidence_bg(:medium), do: "#451a03"
  defp confidence_bg(:low), do: "#450a0a"
  defp confidence_bg(_), do: "#1e293b"

  defp finding_color(:missing_required), do: "#ef4444"
  defp finding_color(:missing_expected), do: "#f59e0b"
  defp finding_color(:low_confidence), do: "#fbbf24"
  defp finding_color(:value_suspicious), do: "#fb923c"
  defp finding_color(_), do: "#64748b"

  defp gate_color(:pass), do: "#10b981"
  defp gate_color(:fail), do: "#ef4444"
  defp gate_color(_), do: "#64748b"

  defp gate_icon(:pass), do: "PASS"
  defp gate_icon(:fail), do: "FAIL"
  defp gate_icon(_), do: "—"

  defp fmt_atom(nil), do: ""
  defp fmt_atom(atom), do: atom |> to_string() |> String.upcase()

  defp fmt_company(:trammo_inc), do: "Inc"
  defp fmt_company(:trammo_sas), do: "SAS"
  defp fmt_company(:trammo_dmcc), do: "DMCC"
  defp fmt_company(_), do: ""

  defp safe_atom(""), do: nil
  defp safe_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> nil
    end
  end
  defp safe_atom(_), do: nil

  defp format_val(nil), do: "—"
  defp format_val(val) when is_float(val) and val >= 1000, do: format_number(val)
  defp format_val(val) when is_float(val), do: Float.round(val, 2) |> to_string()
  defp format_val(val), do: to_string(val)

  defp format_number(val) when is_float(val) do
    val |> round() |> Integer.to_string()
    |> String.reverse() |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse() |> String.trim_leading(",")
  end
  defp format_number(val) when is_integer(val) do
    val |> Integer.to_string()
    |> String.reverse() |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse() |> String.trim_leading(",")
  end
  defp format_number(val), do: to_string(val)
end
