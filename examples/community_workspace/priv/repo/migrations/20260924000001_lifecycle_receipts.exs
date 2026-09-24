defmodule Workspace.Repo.Migrations.LifecycleReceipts do
  use Ecto.Migration

  def change do
    alter table(:workspace_actions) do
      add(:request_version, :bigint)
    end
  end
end
