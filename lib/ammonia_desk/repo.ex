defmodule AmmoniaDesk.Repo do
  use Ecto.Repo,
    otp_app: :ammonia_desk,
    adapter: Ecto.Adapters.Postgres
end
