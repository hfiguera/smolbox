defmodule SmolBox.DurableHost.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :smolbox_durable_host, adapter: Ecto.Adapters.Postgres
end
