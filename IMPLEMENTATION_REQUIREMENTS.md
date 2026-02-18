# Trading Desk — Complete Implementation Requirements

This document captures ALL features built across 35+ commits on the ammonia_desk branch.
Use this as context when re-implementing against the `trading_desk` repo (https://github.com/Raathmd/trading_desk.git).

The repo is an Elixir/Phoenix LiveView application for commodity trading optimization.
Branch to create: `claude/contract-parsing-setup-Yt0za` from `main`.

---

## 1. CONTRACT PARSING & VALIDATION PIPELINE

### 1.1 Document Reader (`contracts/document_reader.ex`)
- Extract text from PDF, DOCX, DOCM, TXT files
- DOCM support (same ZIP+XML as DOCX, skip VBA macros)
- Table extraction: `<w:tbl>` elements rendered as pipe-delimited rows
- Paragraphs and tables interleaved in document order

### 1.2 Parser (`contracts/parser.ex`)
- Deterministic Elixir pattern matching for 30 canonical clause types
- Section-based merging: numbered headings merged with body paragraphs before matching
- Per-clause field extraction for all types: INCOTERMS, PRODUCT_AND_SPECS, QUANTITY_TOLERANCE, PRICE, PAYMENT, DELIVERY_PERIOD, LOADING_RATE, DEMURRAGE, LAYTIME, WEIGHT_QUALITY, INSURANCE, FORCE_MAJEURE, GOVERNING_LAW, ARBITRATION, SANCTIONS, ASSIGNMENT, TITLE_RISK, NOTICES, CONFIDENTIALITY, TERMINATION, DEFAULT_AND_REMEDIES, TRADE_RULES, ORIGIN, DESTINATION, NOMINATION, SHIPPING_TERMS, VESSEL_APPROVAL, ENVIRONMENTAL, PENALTY_VOLUME_SHORTFALL, PENALTY_LATE_DELIVERY
- Auto-detection of contract family from text content using anchor scoring
- `extract_embedded_penalties/2` second-pass scanner for penalty sub-clauses within DEFAULT_AND_REMEDIES

### 1.3 Clause Struct (`contracts/clause.ex`)
- Fields: clause_id, category, anchors_matched, extracted_fields, confidence scoring

### 1.4 Contract Struct (`contracts/contract.ex`)
- Identity, versioning, metadata
- Fields: contract_number, family_id, file_hash, file_size, network_path, last_verified_at, verification_status, previous_hash, template_type, incoterm, term_type, company, graph_item_id, graph_drive_id

### 1.5 Template Registry (`contracts/template_registry.ex`)
- 30 canonical clause types with LP variable mappings
- 7 family signatures with detection anchors:
  - vessel_purchase_fob, vessel_sale_cfr, vessel_dap, domestic_cpt, domestic_multimodal, lt_sale_cfr, lt_purchase_fob
- Trammo Inc/SAS/DMCC templates per contract type × incoterm
- Dynamic clause/family registration via `:persistent_term`

### 1.6 Template Validator (`contracts/template_validator.ex`)
- Extraction completeness checking against templates
- Works with canonical clause IDs and family coverage

### 1.7 Contract Store (`contracts/store.ex`)
- ETS store, single-active enforcement per counterparty
- Versioned storage with `update_verification/2`, `list_all/0`

### 1.8 Legal Review (`contracts/legal_review.ex`)
- Role-based approval workflow (TRADER, LEGAL, OPERATIONS)
- Approve/reject with reviewer identity

### 1.9 SAP Client & Validator (`contracts/sap_client.ex`, `contracts/sap_validator.ex`)
- SAP data retrieval (on-network only)
- Comparison of extracted vs SAP values

### 1.10 LLM Validator (`contracts/llm_validator.ex`)
- Local LLM second-pass verification of parser output

### 1.11 Pipeline (`contracts/pipeline.ex`)
- Async BEAM tasks for full extraction flow
- `extract/5` computes file hash, stores family_id and network_path
- `full_extract_async`, `ingest_copilot_async/3`, `ingest_copilot_batch_async/2`
- CurrencyTracker stamping

### 1.12 Readiness Gate (`contracts/readiness.ex`)
- All contracts + APIs must pass before solver can run
- 4-level gate: extraction → review → activation → product group master

### 1.13 Constraint Bridge (`contracts/constraint_bridge.ex`)
- Maps clauses to solver variables
- `penalty_schedule/1`: per-counterparty penalty exposure (rate_per_ton, open_qty, max_exposure)
- `aggregate_open_book/1`: total purchase/sale obligations, net position, penalty exposure

### 1.14 Currency Tracker (`contracts/currency_tracker.ex`)
- GenServer with per-event staleness thresholds (SAP: 60min, positions: 30min)

### 1.15 Hash Verifier (`contracts/hash_verifier.ex`)
- SHA-256 hashing of document bytes
- Single and batch verification against network copies

### 1.16 Inventory (`contracts/inventory.ex`)
- Batch ingestion from directories with manifest support
- Contract number extraction, version chain with previous_hash audit trail

---

## 2. COPILOT INTEGRATION (M365 Copilot as extraction service)

### 2.1 CopilotClient (`contracts/copilot_client.ex`)
- Primary extraction service — reads contract documents, returns structured clause data
- `full_scan/3`: initial pass sends all documents to Copilot
- `delta_scan/2`: hash-checks, only re-extracts changed documents
- Structured prompts include canonical clause inventory and family signatures
- `extract_file/3`, `extract_files/2` for Graph API download → text → LLM

### 2.2 CopilotIngestion (`contracts/copilot_ingestion.ex`)
- `ingest/3`: accepts Copilot structured JSON with pre-extracted clauses
- `ingest_with_hash/2`, `ingest_batch/2`
- `cross_check/1`: runs deterministic parser and compares against Copilot
- Handles unknown clause types via dynamic registration

---

## 3. NETWORK SCANNER (Zig binary for SharePoint)

### 3.1 Zig Scanner (`native/scanner/`)
- Port binary: scan, check_hashes, diff_hashes, fetch, hash_local commands
- Graph API integration for SharePoint file listing and metadata
- SHA-256 hashing on raw bytes
- JSON line protocol over stdin/stdout

### 3.2 NetworkScanner (`contracts/network_scanner.ex`)
- GenServer port wrapper managing Zig process lifecycle
- Graph API OAuth2 token refresh (client_credentials flow)
- `delta_scan/1`: check hashes → fetch changed → return content + new hashes

### 3.3 ScanCoordinator
- Orchestrates flow: scanner for hashes → app compares → Copilot extracts changed
- App-initiated scan flow with clear separation of concerns

---

## 4. SOLVE PIPELINE

### 4.1 Pipeline (`solver/pipeline.ex`)
- Check contract hashes before every solve (via Zig scanner)
- If contracts changed: wait for Copilot to ingest → then solve
- If scanner unavailable: solve with existing data + stale warning
- Broadcasts phases via PubSub: `:checking_contracts` → `:ingesting` → `:solving` → done
- Both solve and monte_carlo modes

### 4.2 Solver Port (`solver/port.ex`)
- v2 protocol: single solver binary for all product groups
- Sends model descriptor + variables with each request
- Binary encoding/decoding per product group

### 4.3 Model Descriptor (`solver/model_descriptor.ex`)
- Encodes frame definitions into binary model descriptors matching Zig solver's `parse_model()` format

### 4.4 Generic Zig LP Solver (`native/solver/solver.zig`)
- Model-descriptor-driven LP engine (no hardcoded product groups)
- HiGHS v1.13.1 LP solver
- 5 objective modes: max_profit, min_cost, max_roi, cvar_adjusted, min_risk

### 4.5 Solve Audit (`solver/solve_audit.ex`)
- Immutable audit record per pipeline execution
- Fields: id, mode, product_group, trader_id, trigger, caller_ref
- Contract snapshot: contracts_used, contracts_checked, contracts_stale
- Variables snapshot: variables, variable_sources (per-API timestamps)
- Result: result, result_status
- Timeline: started_at, contracts_checked_at, ingestion_completed_at, solve_started_at, completed_at

### 4.6 Solve Audit Store (`solver/solve_audit_store.ex`)
- ETS storage with 4 index tables
- Queries: list_recent, find_by_contract, find_by_trader, find_by_time_range
- DAG-ready: trader_decision_chain (with contract/variable deltas)
- product_group_timeline (management view)
- compare_paths (auto-runner vs trader alignment score)
- performance_summary (aggregated metrics)

---

## 5. MULTI-PRODUCT-GROUP SUPPORT

### 5.1 ProductGroup Registry
- Frame behaviour with 4 frame configs
- Each product group defines: variables, routes, constraints, API sources, signal thresholds, contract term mappings

### 5.2 Frames
- **ammonia_domestic**: 22 variables, river routes (Don→StL, Don→Mem, Geis→StL, Geis→Mem)
- **ammonia_international**: 24 variables, ocean routes (Trinidad/Jubail/Yuzhnyy → Tampa/India/NWE)
- **sulphur_international**: 23 variables
- **petcoke**: 19 variables

### 5.3 VariablesDynamic
- Frame-driven variable management for non-ammonia-domestic product groups

---

## 6. DATA INTEGRATIONS

### 6.1 API Integrations (7 sources in `data/apis/`)
- **USGS**: river stage/flow from Water Services API (4 Mississippi gauges)
- **NOAA**: weather observations (temp, wind, vis, precip) from 4 stations
- **USACE**: lock delay/status from NDC API with LPMS fallback
- **EIA**: nat gas spot prices with FRED fallback
- **Market**: ammonia prices via Argus/ICIS/custom feed
- **Broker**: barge freight rates via broker API/TMS
- **Internal**: inventory, outages, barges, capital via SAP/SCADA/unified API

### 6.2 Vessel Tracking (`data/apis/vessel_tracking.ex`)
- AIS integration via VesselFinder, MarineTraffic, AISHub
- Mississippi River bounding box, waypoint enrichment, fleet summary

### 6.3 Tides (`data/apis/tides.ex`)
- NOAA CO-OPS for 5 Lower Mississippi stations
- Water levels, tidal predictions, current velocity at SW Pass

### 6.4 Vessel Weather (`data/apis/vessel_weather.ex`)
- Combines vessel GPS with nearest NOAA weather + tidal station
- Worst-case fleet weather for solver

### 6.5 Poller (`data/poller.ex`)
- Uses DeltaConfig intervals per source
- Real API modules with graceful fallback to simulated data
- `status/0` public API exposing last poll time, errors, intervals for all 9 sources

### 6.6 LiveState (`data/live_state.ex`)
- Supplementary data store for non-variable data (vessels, tides)

### 6.7 Ammonia Prices (`data/ammonia_prices.ex`)
- GenServer with seeded Fertecon/FMB benchmark prices
- FOB: NOLA $380, Trinidad $345, Middle East $320, Yuzhnyy $295
- CFR: Tampa $420, India $375, NW Europe $410, Morocco $390
- Domestic: NOLA barge $385/ST, Corn Belt $520/ST
- 15-minute refresh interval, `price_summary/0`, `nola_buy_price/0`

---

## 7. DELTA-TRIGGERED AUTO-SOLVER

### 7.1 DeltaConfig (`config/delta_config.ex`)
- Admin-configurable per-product-group: thresholds, poll intervals, cooldown, MC scenarios
- Persisted to SQLite, changes broadcast via PubSub
- 20 variable thresholds (river_stage: 0.5ft, lock_hrs: 2.0hrs, temp_f: 5.0°F, etc.)
- Default cooldown: 5 minutes, default scenarios: 1000

### 7.2 AutoRunner (`scenarios/auto_runner.ex`)
- Delta-only triggering using DeltaConfig thresholds
- Rich trigger details per breach: key, variable_index, baseline_value, current_value, threshold, delta
- History: last 20 results with triggers, timestamp, distribution, audit_id
- BSV chain commitment for every auto-solve

---

## 8. BSV BLOCKCHAIN

### 8.1 AutoSolveCommitter (`chain/auto_solve_committer.ex`)
- Every auto-solve stored on-chain with full payload
- Canonical binary format: header + timestamp + variables + MC result + trigger bitmask
- SHA-256 hashed, ECDSA signed with server key, AES-256-GCM encrypted
- Config changes also committed (type 0x05) for audit trail

### 8.2 Chain Payload (`chain/payload.ex`)
- Dynamic magic headers, product codes, variable-length variable sections (v2 format)

---

## 9. PERSISTENCE

### 9.1 SQLite via Ecto
- Repo module with SQLite adapter (ecto_sqlite3)
- Schemas: ContractRecord, SolveAuditRecord, SolveAuditContract (join), ScenarioRecord
- Tables: contracts, solve_audits (JSON text), solve_audit_contracts, scenarios
- DB.Writer: async persistence from ETS to SQLite
- WAL mode enabled for concurrent reads during writes

### 9.2 Snapshot WAL
- Append-only WAL files, daily rotation
- Length-prefixed ETF frames with MD5 hash chain (tamper-evident)
- Synchronous fsync on every write
- SnapshotRestore: restore_sqlite, restore_ets, fill_gaps, verify_all

---

## 10. SAP S/4HANA INTEGRATION

### 10.1 SAP Positions (`contracts/sap_positions.ex`)
- OData-based `refresh_positions/1` and `refresh_all/0`
- Seeded realistic positions for 10 contracts
- Purchase open: 309,500 MT, Sale open: 237,000 MT, Net long: +72,500 MT
- `book_summary/0` for UI

### 10.2 SAP Refresh Scheduler
- GenServer for periodic background refresh (default 15min)
- Decoupled from solve pipeline

### 10.3 SAP Webhook
- POST `/api/sap/ping` — SAP calls when position changes, triggers immediate refresh
- GET `/api/sap/status` — health check

### 10.4 SAP Write-Back Stubs
- `create_contract/1` and `create_delivery/1` (OData POST stubs)

---

## 11. AI / LLM

### 11.1 Analyst (`analyst.ex`)
- Claude-powered explanations using Anthropic API (claude-sonnet-4-5-20250929)
- `explain_solve/2`, `explain_distribution/2`, `explain_agent/1`
- `explain_solve_with_impact/4`: post-solve per-contract position impact
- Generic for all product groups (builds prompts dynamically from frame definition)
- Non-blocking: spawn + broadcast via PubSub
- 300 token limit, 15s timeout

### 11.2 Intent Mapper (`intent_mapper.ex`)
- Claude interprets trader plain-text action against current variables + SAP positions
- Returns structured intent: variable_adjustments, affected_contracts, risk_notes
- Variables auto-adjusted before solve if intent maps to solver keys

---

## 12. LIVEVIEW UI (`trading_desk_web/live/scenario_live.ex`)

### 12.1 Tab Structure (6 tabs)
- **Trader**: solve results, analysis, MC distribution, objective mode selector, route map, fleet/tides
- **Contracts**: ammonia price board (8 benchmarks), open book summary, per-contract detail table with penalties
- **Solves**: table of all manual and auto solves (NEW)
- **Map**: larger 450px Leaflet.js map, fleet tracking table, tides/currents
- **Agent**: auto-runner results, trigger details, AI explanation, distribution chart, sensitivity
- **APIs**: all data source statuses with thresholds (NEW enhancements)

### 12.2 Solves Tab (NEW)
- Table columns: Time, Source (MANUAL/AUTO badge), Mode, Result, Trigger/Adjustments
- Manual solves show: trader ID, variable adjustments (key: old → new)
- Auto solves show: trigger variables with delta values that exceeded thresholds
- Color-coded signal badges (STRONG GO, GO, HOLD, NO GO)
- Merges SolveAuditStore records with AutoRunner history
- Deduplicates by audit_id, sorted newest first, up to 50 entries
- Refreshes on tab switch and when new solves complete

### 12.3 APIs Tab
- **Live Data Feeds**: all 9 poller sources with status badge, last called timestamp, poll interval
- **SAP S/4HANA OData**: position refresh, create contract/delivery stubs, webhook ping
- **Ammonia Pricing**: Fertecon/FMB benchmark status
- **AI/LLM**: Claude analyst and intent mapper configuration status
- **Auto-Solve Delta Thresholds** (NEW): 4-column grid showing all 20 variable thresholds with formatted values (units, currencies), cooldown interval, scenario count, enabled/disabled

### 12.4 Header
- Pricing ticker: NOLA Barge, FOB Trinidad, FOB Mid East, FOB Yuzhnyy
- Auto-runner status indicator with signal and profit

### 12.5 Trader Tab Features
- Product group picker dropdown
- Objective mode selector: max_profit, min_cost, max_roi, cvar_adjusted, min_risk
- Trader action textarea (plain-text input for intent mapper)
- Pre-solve review popup: AI interpretation, variable changes, affected contracts, SAP book
- Post-solve impact display: per-contract position impact table
- Leaflet.js route map with terminal markers and route lines
- Fleet tracking table and tides/currents panels
- AI explanation card (purple accent)

### 12.6 Contracts Tab
- 8-benchmark ammonia price board with source attribution
- Open book summary: purchase open vs sale open, net position
- Per-contract detail table: counterparty, direction, incoterm, total/open quantities, progress bar, penalty clauses

### 12.7 Defensive Mounting
- `safe_call/2` wraps all GenServer calls — page renders even when services still starting
- Uses `catch` (not `rescue`) for spawned tasks to handle Erlang exits

### 12.8 Contracts Management UI (`contracts_live.ex`)
- Route: `/contracts`
- Three role-based views: TRADER (readiness gate), LEGAL (clause review), OPERATIONS (SAP validation)
- Real-time PubSub updates

---

## 13. SEED DATA

### 13.1 Seed Contracts (10 contracts in `priv/contracts/seed/`)
Purchase side:
- 01 NGC Trinidad LT FOB: 180k MT/yr, $355 FOB, $15/MT shortfall
- 02 SABIC Al Jubail LT FOB: 150k MT/yr, $330 FOB, $12/MT shortfall
- 03 Ameropa Yuzhnyy spot FOB: 23k MT, $305 FOB, war risk shared
- 04 LSB Donaldsonville domestic FOB: 32k MT/yr, $335 FOB, river stage FM

Sale side:
- 05 Mosaic Tampa LT CFR: 100k MT/yr, $425 CFR, $20/MT late + $18/MT shortfall
- 06 IFFCO India LT CFR: 120k MT/yr, index+$8, $15/MT late + $12/MT shortfall
- 07 OCP Morocco spot CFR: 20k MT, $395 CFR, $22/MT late delivery
- 08 Nutrien StL domestic barge: 20k MT/yr, $415 FOB, $12/MT shortfall
- 09 Koch Memphis domestic barge: 16k MT/yr, $390 FOB, $10/MT shortfall
- 10 BASF NWE spot DAP: 15k MT, $470 DAP, $25/MT late delivery

### 13.2 Seed Loader (`contracts/seed_loader.ex`)
- Loads all 10 from priv/contracts/seed/
- Parses, detects family + incoterm, sets open position
- Auto-approves for solver testing

---

## 14. APPLICATION STRUCTURE

### 14.1 App Name
- Module namespace: `TradingDesk` (was `AmmoniaDesk`)
- App atom: `:trading_desk`

### 14.2 Supervision Tree (`application.ex`)
- All GenServers: LiveState, Poller, AutoRunner, Store, SolveAuditStore, DeltaConfig, SapRefreshScheduler, NetworkScanner, AmmoniaPrices, SnapshotLog, CurrencyTracker

### 14.3 Router
- `/` → ScenarioLive (main desk)
- `/contracts` → ContractsLive (management)
- `/api/sap/ping` → SAP webhook
- `/api/sap/status` → SAP health check

### 14.4 Dependencies
- ecto_sql + ecto_sqlite3 (SQLite with WAL mode)
- req (HTTP client)
- jason (JSON)
- phoenix_live_view
