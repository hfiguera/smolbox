defmodule SmolBox.ImageInventory do
  @moduledoc """
  Snapshot of image metadata inside one machine.

  `availability: :empty_or_unavailable` means the worker returned no entries.
  This is deliberately not proof that the cache is empty: smolvm returns the
  same response when the VM is not alive. The list endpoint does not start it.
  A separate running observation cannot make this snapshot atomic.
  `:observed` means at least one image was returned, not that any workload is ready.
  """
  alias SmolBox.{Error, Image, Validation}

  @enforce_keys [:images, :availability]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          images: [Image.t()],
          availability: :observed | :empty_or_unavailable
        }

  @doc false
  @spec from_wire(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(%{"images" => entries}) do
    if Validation.list?(entries, 1024) do
      decode(entries)
    else
      invalid()
    end
  end

  def from_wire(_body), do: invalid()

  defp decode(entries) do
    result =
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, images} ->
        case Image.from_wire(entry) do
          {:ok, image} -> {:cont, {:ok, [image | images]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, images} <- result do
      {:ok,
       %__MODULE__{
         images: Enum.reverse(images),
         availability: if(images == [], do: :empty_or_unavailable, else: :observed)
       }}
    end
  end

  defp invalid,
    do: {:error, %Error{category: :protocol, operation: :images, evidence: :dispatch_uncertain}}
end
