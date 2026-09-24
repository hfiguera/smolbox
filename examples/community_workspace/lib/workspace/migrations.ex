defmodule Workspace.Migrations do
  @moduledoc "Migration sources for this repository example; run Mix from its directory."
  def paths do
    [
      Path.join([File.cwd!(), "..", "durable_host", "priv", "repo", "migrations"]),
      Application.app_dir(:community_workspace, "priv/repo/migrations")
    ]
  end
end
