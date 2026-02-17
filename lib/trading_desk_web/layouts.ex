defmodule TradingDesk.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
      <title>Trading Desk</title>
      <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
      <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/phoenix@1.7.10/priv/static/phoenix.min.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@0.20.1/priv/static/phoenix_live_view.min.js"></script>
      <script>
        document.addEventListener("DOMContentLoaded", function() {
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

          let Hooks = {}
          Hooks.Slider = {
            mounted() {
              this.el.addEventListener("input", (e) => {
                this.pushEvent("update_var", {key: this.el.dataset.key, value: e.target.value})
              })
            },
            updated() {
              // Don't let server override slider while user is dragging
            }
          }

          Hooks.VesselMap = {
            mounted() {
              if (typeof L === 'undefined') return;
              const data = JSON.parse(this.el.dataset.mapdata || '{}');
              const map = L.map(this.el, {
                center: data.center || [20, 0],
                zoom: data.zoom || 2,
                zoomControl: true,
                attributionControl: false
              });
              L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
                maxZoom: 18
              }).addTo(map);
              this._map = map;
              this._renderData(data);
            },
            updated() {
              if (!this._map) return;
              const data = JSON.parse(this.el.dataset.mapdata || '{}');
              this._map.eachLayer(function(layer) {
                if (!(layer instanceof L.TileLayer)) layer.remove();
              });
              this._renderData(data);
            },
            _renderData(data) {
              const map = this._map;
              (data.terminals || []).forEach(function(t) {
                L.circleMarker([t.lat, t.lon], {
                  radius: 7, fillColor: t.color || '#38bdf8', fillOpacity: 0.85,
                  color: '#e2e8f0', weight: 1.5
                }).bindPopup('<b>' + t.name + '</b>').addTo(map);
              });
              (data.routes || []).forEach(function(r) {
                L.polyline([[r.from_lat, r.from_lon], [r.to_lat, r.to_lon]], {
                  color: r.active ? '#10b981' : '#334155',
                  weight: r.active ? 3 : 1.5,
                  dashArray: r.active ? null : '6 4',
                  opacity: r.active ? 0.9 : 0.4
                }).addTo(map);
              });
              (data.vessels || []).forEach(function(v) {
                var icon = L.divIcon({
                  html: '<div style="color:' + (v.color || '#f59e0b') + ';font-size:16px;line-height:1">&#9650;</div>',
                  iconSize: [16, 16], className: ''
                });
                L.marker([v.lat, v.lon], {icon: icon})
                  .bindPopup('<b>' + v.name + '</b><br>' + (v.status || ''))
                  .addTo(map);
              });
            }
          }

          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: {_csrf_token: csrfToken},
            hooks: Hooks
          })
          liveSocket.connect()
        })
      </script>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        button:disabled { opacity: 0.5; cursor: not-allowed; }
        input:focus, button:focus { outline: 2px solid #38bdf8; outline-offset: 2px; }
      </style>
    </head>
    <body>
      <%= @inner_content %>
    </body>
    </html>
    """
  end
end
