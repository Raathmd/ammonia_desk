defmodule AmmoniaDesk.ContractsLive do
  @moduledoc """
  Contract management LiveView with role-based tabs.

  Three roles, three views:
    - TRADER:     Readiness dashboard, contract impact preview, optimize gate
    - LEGAL:      Clause review, confidence flags, approve/reject workflow
    - OPERATIONS: SAP validation, open position refresh, discrepancy review

  Each role sees only what they need. All roles see real-time PubSub updates
  as pipeline tasks complete in the background on the BEAM.
  """
  use Phoenix.LiveView

  alias AmmoniaDesk.Contracts.{
    Store,
    Pipeline,
    LegalReview,
    SapValidator,
    Readiness,
    ConstraintBridge
  }

  @product_groups [:ammonia, :uan, :urea]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AmmoniaDesk.PubSub, "contracts")
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
      |> assign(:pipeline_status, nil)
      |> assign(:upload_error, nil)
      |> refresh_contracts()
      |> refresh_readiness()

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

  # --- Events: File Upload (simplified — no LiveView upload, uses form post) ---

  @impl true
  def handle_event("extract_contract", params, socket) do
    counterparty = Map.get(params, "counterparty", "") |> String.trim()
    cp_type = Map.get(params, "cp_type", "customer") |> String.to_existing_atom()
    file_path = Map.get(params, "file_path", "") |> String.trim()
    sap_id = Map.get(params, "sap_contract_id", "") |> String.trim()

    cond do
      counterparty == "" ->
        {:noreply, assign(socket, :upload_error, "Counterparty name is required")}

      file_path == "" ->
        {:noreply, assign(socket, :upload_error, "File path is required")}

      not File.exists?(file_path) ->
        {:noreply, assign(socket, :upload_error, "File not found: #{file_path}")}

      true ->
        opts = if sap_id != "", do: [sap_contract_id: sap_id], else: []
        Pipeline.extract_async(file_path, counterparty, cp_type, socket.assigns.product_group, opts)

        socket =
          socket
          |> assign(:pipeline_status, "Extracting #{Path.basename(file_path)}...")
          |> assign(:upload_error, nil)

        {:noreply, socket}
    end
  end

  # --- Events: Legal Review ---

  @impl true
  def handle_event("submit_for_review", %{"id" => id}, socket) do
    case LegalReview.submit_for_review(id) do
      {:ok, _} ->
        {:noreply, socket |> refresh_contracts() |> assign(:pipeline_status, "Submitted for legal review")}
      {:error, reason} ->
        {:noreply, assign(socket, :pipeline_status, "Submit failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("approve_contract", %{"id" => id, "reviewer" => reviewer}, socket) do
    notes = Map.get(socket.assigns, :review_notes, "")

    case LegalReview.approve(id, reviewer, notes: notes) do
      {:ok, _} ->
        {:noreply, socket |> refresh_contracts() |> refresh_readiness()
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

  # --- Events: Trader ---

  @impl true
  def handle_event("preview_constraints", _params, socket) do
    vars = AmmoniaDesk.Data.LiveState.get()
    preview = ConstraintBridge.preview_constraints(vars, socket.assigns.product_group)
    {:noreply, assign(socket, :constraint_preview, preview)}
  end

  @impl true
  def handle_event("check_readiness", _params, socket) do
    {:noreply, refresh_readiness(socket)}
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
          <a href="/" style="color:#64748b;text-decoration:none;font-size:12px">&larr; DESK</a>
          <span style="font-size:14px;font-weight:700;color:#e2e8f0;letter-spacing:1px">CONTRACT MANAGEMENT</span>
        </div>
        <div style="display:flex;align-items:center;gap:8px">
          <%# Product group selector %>
          <%= for pg <- @product_groups do %>
            <button phx-click="switch_product_group" phx-value-pg={pg}
              style={"padding:4px 12px;border-radius:4px;font-size:11px;font-weight:600;cursor:pointer;border:1px solid #{if @product_group == pg, do: "#38bdf8", else: "#1e293b"};background:#{if @product_group == pg, do: "#0c4a6e", else: "transparent"};color:#{if @product_group == pg, do: "#38bdf8", else: "#64748b"}"}>
              <%= pg |> to_string() |> String.upcase() %>
            </button>
          <% end %>
        </div>
      </div>

      <%# === ROLE TABS === %>
      <div style="background:#0d1117;border-bottom:1px solid #1b2838;padding:0 20px;display:flex;gap:2px">
        <%= for {role, label, icon, color} <- [{:trader, "Trader", "📊", "#38bdf8"}, {:legal, "Legal", "⚖️", "#a78bfa"}, {:operations, "Operations", "🏭", "#f59e0b"}] do %>
          <button phx-click="switch_role" phx-value-role={role}
            style={"padding:10px 20px;border:none;font-size:12px;font-weight:600;cursor:pointer;background:#{if @role == role, do: "#111827", else: "transparent"};color:#{if @role == role, do: color, else: "#475569"};border-bottom:2px solid #{if @role == role, do: color, else: "transparent"}"}>
            <%= icon %> <%= label %>
          </button>
        <% end %>
      </div>

      <%# === PIPELINE STATUS BAR === %>
      <%= if @pipeline_status do %>
        <div style="background:#0f1729;border-bottom:1px solid #1e293b;padding:8px 20px;font-size:12px;color:#38bdf8;display:flex;align-items:center;gap:8px">
          <div style="width:6px;height:6px;border-radius:50%;background:#38bdf8;animation:pulse 1.5s infinite"></div>
          <%= @pipeline_status %>
        </div>
      <% end %>

      <div style="display:grid;grid-template-columns:380px 1fr;height:calc(100vh - 100px)">
        <%# === LEFT: CONTRACT LIST === %>
        <div style="background:#0a0f18;border-right:1px solid #1b2838;overflow-y:auto;padding:14px">
          <%# Upload section %>
          <div style="margin-bottom:16px;padding:12px;background:#111827;border-radius:8px">
            <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:8px">INGEST CONTRACT</div>
            <form phx-submit="extract_contract">
              <input type="text" name="counterparty" placeholder="Counterparty name..." style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px;margin-bottom:6px" />
              <select name="cp_type" style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px;margin-bottom:6px">
                <option value="customer">Customer</option>
                <option value="supplier">Supplier</option>
              </select>
              <input type="text" name="file_path" placeholder="File path (PDF/DOCX)..." style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px;margin-bottom:6px" />
              <input type="text" name="sap_contract_id" placeholder="SAP Contract # (optional)" style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:6px 8px;border-radius:4px;font-size:11px;margin-bottom:6px" />
              <button type="submit" style="width:100%;padding:8px;border:none;border-radius:4px;font-weight:600;font-size:11px;background:#0c4a6e;color:#38bdf8;cursor:pointer">
                EXTRACT CLAUSES
              </button>
            </form>
            <%= if @upload_error do %>
              <div style="color:#ef4444;font-size:11px;margin-top:6px"><%= @upload_error %></div>
            <% end %>
          </div>

          <%# Contract list %>
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
                <span><%= contract.counterparty_type %> | v<%= contract.version %></span>
                <span><%= length(contract.clauses || []) %> clauses</span>
              </div>
              <div style="display:flex;gap:8px;margin-top:4px;font-size:10px">
                <span style={"color:#{if contract.sap_validated, do: "#10b981", else: "#64748b"}"}>
                  <%= if contract.sap_validated, do: "SAP ✓", else: "SAP ?" %>
                </span>
                <%= if contract.open_position do %>
                  <span style="color:#38bdf8">Pos: <%= format_number(contract.open_position) %>t</span>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>

        <%# === RIGHT: ROLE-SPECIFIC PANEL === %>
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
    <%# Readiness gate %>
    <div style="background:#111827;border-radius:10px;padding:20px;margin-bottom:16px">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
        <span style="font-size:14px;font-weight:700;color:#e2e8f0">READINESS GATE</span>
        <button phx-click="check_readiness"
          style="padding:6px 14px;border:1px solid #1e293b;border-radius:4px;font-size:11px;font-weight:600;background:transparent;color:#38bdf8;cursor:pointer">
          REFRESH
        </button>
      </div>
      <%= if @readiness do %>
        <% {status, data} = case @readiness do
          {:ready, report} -> {:ready, report}
          {:not_ready, issues, report} -> {:not_ready, {issues, report}}
        end %>
        <div style={"display:flex;align-items:center;gap:12px;padding:14px;border-radius:8px;margin-bottom:16px;background:#{if status == :ready, do: "#052e16", else: "#1c1917"};border:1px solid #{if status == :ready, do: "#166534", else: "#78350f"}"}>
          <div style={"width:14px;height:14px;border-radius:50%;background:#{if status == :ready, do: "#10b981", else: "#f59e0b"}"}></div>
          <div>
            <div style={"font-size:16px;font-weight:800;color:#{if status == :ready, do: "#10b981", else: "#f59e0b"}"}>
              <%= if status == :ready, do: "READY TO OPTIMIZE", else: "NOT READY" %>
            </div>
            <div style="font-size:11px;color:#94a3b8;margin-top:2px">
              <%= if status == :ready do %>
                All contracts approved, SAP validated, positions loaded, APIs fresh
              <% else %>
                <% {issues, _report} = data %>
                <%= length(issues) %> blocking issue(s) — see below
              <% end %>
            </div>
          </div>
        </div>

        <%# Report stats %>
        <% report = case @readiness do {:ready, r} -> r; {:not_ready, _, r} -> r end %>
        <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:16px">
          <div style="background:#0a0f18;padding:10px;border-radius:6px;text-align:center">
            <div style="font-size:10px;color:#64748b">Approved</div>
            <div style={"font-size:20px;font-weight:700;color:#{if report.approved > 0, do: "#10b981", else: "#64748b"}"}><%= report.approved %>/<%= report.total_contracts %></div>
          </div>
          <div style="background:#0a0f18;padding:10px;border-radius:6px;text-align:center">
            <div style="font-size:10px;color:#64748b">SAP Valid</div>
            <div style={"font-size:20px;font-weight:700;color:#{if report.sap_validated > 0, do: "#10b981", else: "#64748b"}"}><%= report.sap_validated %></div>
          </div>
          <div style="background:#0a0f18;padding:10px;border-radius:6px;text-align:center">
            <div style="font-size:10px;color:#64748b">Positions</div>
            <div style={"font-size:20px;font-weight:700;color:#{if report.positions_loaded > 0, do: "#38bdf8", else: "#64748b"}"}><%= report.positions_loaded %></div>
          </div>
          <div style="background:#0a0f18;padding:10px;border-radius:6px;text-align:center">
            <div style="font-size:10px;color:#64748b">APIs Fresh</div>
            <div style={"font-size:20px;font-weight:700;color:#{if length(report.apis_stale) == 0, do: "#10b981", else: "#f59e0b"}"}><%= length(report.apis_fresh) %>/5</div>
          </div>
        </div>

        <%# Blocking issues %>
        <%= if status == :not_ready do %>
          <% {issues, _report} = data %>
          <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:8px">BLOCKING ISSUES</div>
          <%= for issue <- issues do %>
            <div style="padding:8px 12px;margin-bottom:4px;border-radius:4px;background:#1c1917;border-left:3px solid #f59e0b;font-size:12px">
              <div style="color:#fbbf24;font-weight:600"><%= issue.category |> to_string() |> String.replace("_", " ") |> String.upcase() %></div>
              <div style="color:#c8d6e5;margin-top:2px"><%= issue.message %></div>
            </div>
          <% end %>
        <% end %>
      <% end %>
    </div>

    <%# Contract constraint preview %>
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
        <div style="font-size:12px;color:#475569;font-style:italic">Click PREVIEW to see how active contracts modify solver inputs</div>
      <% end %>
    </div>
    """
  end

  # === LEGAL PANEL ===

  defp render_legal_panel(assigns) do
    ~H"""
    <%= if @selected_contract do %>
      <% c = @selected_contract %>
      <%# Contract header %>
      <div style="background:#111827;border-radius:10px;padding:20px;margin-bottom:16px">
        <div style="display:flex;justify-content:space-between;align-items:flex-start">
          <div>
            <div style="font-size:18px;font-weight:700;color:#e2e8f0"><%= c.counterparty %></div>
            <div style="font-size:12px;color:#64748b;margin-top:2px">
              <%= c.counterparty_type %> | <%= c.product_group %> | v<%= c.version %> | <%= c.source_file %>
            </div>
          </div>
          <span style={"font-size:12px;font-weight:700;padding:4px 10px;border-radius:4px;background:#{status_bg(c.status)};color:#{status_color(c.status)}"}>
            <%= c.status |> to_string() |> String.upcase() |> String.replace("_", " ") %>
          </span>
        </div>

        <%# Review summary stats %>
        <%= if @review_summary do %>
          <div style="display:grid;grid-template-columns:repeat(5,1fr);gap:8px;margin-top:16px">
            <div style="background:#0a0f18;padding:8px;border-radius:4px;text-align:center">
              <div style="font-size:10px;color:#64748b">Total</div>
              <div style="font-size:16px;font-weight:700"><%= @review_summary.total_clauses %></div>
            </div>
            <div style="background:#0a0f18;padding:8px;border-radius:4px;text-align:center">
              <div style="font-size:10px;color:#64748b">High Conf</div>
              <div style="font-size:16px;font-weight:700;color:#10b981"><%= Map.get(@review_summary.confidence_breakdown, :high, 0) %></div>
            </div>
            <div style="background:#0a0f18;padding:8px;border-radius:4px;text-align:center">
              <div style="font-size:10px;color:#64748b">Medium</div>
              <div style="font-size:16px;font-weight:700;color:#f59e0b"><%= Map.get(@review_summary.confidence_breakdown, :medium, 0) %></div>
            </div>
            <div style="background:#0a0f18;padding:8px;border-radius:4px;text-align:center">
              <div style="font-size:10px;color:#64748b">Low Conf</div>
              <div style="font-size:16px;font-weight:700;color:#ef4444"><%= Map.get(@review_summary.confidence_breakdown, :low, 0) %></div>
            </div>
            <div style="background:#0a0f18;padding:8px;border-radius:4px;text-align:center">
              <div style="font-size:10px;color:#64748b">SAP</div>
              <div style={"font-size:16px;font-weight:700;color:#{if @review_summary.sap_validated, do: "#10b981", else: "#64748b"}"}><%= if @review_summary.sap_validated, do: "✓", else: "?" %></div>
            </div>
          </div>
        <% end %>

        <%# Action buttons %>
        <%= if c.status == :draft do %>
          <div style="margin-top:16px">
            <button phx-click="submit_for_review" phx-value-id={c.id}
              style="padding:8px 20px;border:none;border-radius:4px;font-weight:600;font-size:12px;background:#7c3aed;color:#fff;cursor:pointer">
              SUBMIT FOR LEGAL REVIEW
            </button>
          </div>
        <% end %>

        <%= if c.status == :pending_review do %>
          <div style="display:flex;gap:8px;margin-top:16px">
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

      <%# SAP discrepancies %>
      <%= if c.sap_discrepancies && length(c.sap_discrepancies) > 0 do %>
        <div style="background:#1c1917;border:1px solid #78350f;border-radius:8px;padding:14px;margin-bottom:16px">
          <div style="font-size:11px;color:#fbbf24;letter-spacing:1px;margin-bottom:8px">SAP DISCREPANCIES</div>
          <%= for d <- c.sap_discrepancies do %>
            <div style="padding:6px 0;border-bottom:1px solid #78350f22;font-size:12px">
              <span style={"font-weight:600;color:#{if d.severity == :high, do: "#ef4444", else: "#fbbf24"}"}>
                [<%= d.severity |> to_string() |> String.upcase() %>]
              </span>
              <span style="color:#c8d6e5;margin-left:6px"><%= d.message %></span>
              <%= if Map.has_key?(d, :contract_value) do %>
                <div style="font-size:10px;color:#94a3b8;margin-top:2px;margin-left:16px">
                  Contract: <%= inspect(d.contract_value) %> | SAP: <%= inspect(Map.get(d, :sap_value)) %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <%# Clause list %>
      <div style="background:#111827;border-radius:10px;padding:16px">
        <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:10px">EXTRACTED CLAUSES</div>
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
            <%# Extracted values %>
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
            <%# Original text %>
            <div style="font-size:11px;color:#94a3b8;line-height:1.4;font-style:italic;border-top:1px solid #1e293b;padding-top:6px">
              "<%= String.slice(clause.description, 0, 300) %><%= if String.length(clause.description) > 300, do: "..." %>"
            </div>
          </div>
        <% end %>
      </div>
    <% else %>
      <div style="background:#111827;border-radius:10px;padding:40px;text-align:center;color:#475569">
        Select a contract from the list to review its clauses
      </div>
    <% end %>
    """
  end

  # === OPERATIONS PANEL ===

  defp render_operations_panel(assigns) do
    ~H"""
    <%# Batch actions %>
    <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
      <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:12px">
        SAP OPERATIONS — <%= @product_group |> to_string() |> String.upcase() %>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
        <button phx-click="validate_all_sap"
          style="padding:10px;border:none;border-radius:6px;font-weight:600;font-size:12px;background:#92400e;color:#fbbf24;cursor:pointer">
          VALIDATE ALL vs SAP
        </button>
        <button phx-click="refresh_positions"
          style="padding:10px;border:none;border-radius:6px;font-weight:600;font-size:12px;background:#0c4a6e;color:#38bdf8;cursor:pointer">
          REFRESH OPEN POSITIONS
        </button>
      </div>
    </div>

    <%# Selected contract detail %>
    <%= if @selected_contract do %>
      <% c = @selected_contract %>
      <div style="background:#111827;border-radius:10px;padding:20px;margin-bottom:16px">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
          <div>
            <div style="font-size:16px;font-weight:700;color:#e2e8f0"><%= c.counterparty %></div>
            <div style="font-size:12px;color:#64748b">SAP: <%= c.sap_contract_id || "not linked" %></div>
          </div>
          <button phx-click="validate_sap" phx-value-id={c.id}
            style="padding:6px 14px;border:1px solid #78350f;border-radius:4px;font-size:11px;font-weight:600;background:transparent;color:#fbbf24;cursor:pointer">
            VALIDATE vs SAP
          </button>
        </div>

        <%# SAP validation status %>
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

        <%# Discrepancy detail %>
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

        <%# Extracted values for ops confirmation %>
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

  defp format_pipeline_event(:extraction_started, p), do: "Extracting #{p.file} for #{p.counterparty}..."
  defp format_pipeline_event(:extraction_complete, p), do: "Extracted #{p.clause_count} clauses from #{p.counterparty} v#{p.version}"
  defp format_pipeline_event(:extraction_failed, p), do: "Extraction failed for #{p.counterparty}: #{p.reason}"
  defp format_pipeline_event(:sap_validation_started, _), do: "Running SAP validation..."
  defp format_pipeline_event(:sap_validation_complete, p), do: "SAP validation complete (#{p.discrepancy_count} discrepancies)"
  defp format_pipeline_event(:sap_validation_failed, p), do: "SAP validation failed: #{p.reason}"
  defp format_pipeline_event(:positions_refresh_started, _), do: "Refreshing open positions from SAP..."
  defp format_pipeline_event(:positions_refresh_complete, p), do: "Positions refreshed: #{p.succeeded}/#{p.total} succeeded"
  defp format_pipeline_event(:product_group_extraction_complete, p), do: "Product group extraction complete: #{p.total} contracts"
  defp format_pipeline_event(:product_group_validation_complete, _), do: "Product group SAP validation complete"
  defp format_pipeline_event(:product_group_refresh_complete, _), do: "Product group fully refreshed"
  defp format_pipeline_event(event, _), do: "#{event}"

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
