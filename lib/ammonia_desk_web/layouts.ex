defmodule AmmoniaDesk.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
      <title>Ammonia Desk</title>
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
