defmodule SmolBox.Runtime.ImageObservation do
  alias SmolBox.Runtime.Target
  @moduledoc false
  alias SmolBox.{Backend, Error, Image}
  alias SmolBox.Runtime.Session

  def run(session, record) do
    result =
      Session.io(session, record, :execution, fn ->
        Backend.pull_image(
          Target.connection(session.worker),
          record.machine_name,
          record.spec.command.source
        )
      end)

    case result do
      {:ok, %Image{} = image} ->
        Session.patch(session,
          state: :completed,
          evidence: :image_pulled,
          result: image,
          collection: :complete
        )

      {:error, %Error{} = error} ->
        Session.patch(session,
          state: :unknown,
          evidence: :unknown,
          last_error: %{error | operation: :pull_image, evidence: :unknown}
        )
    end
  end
end
