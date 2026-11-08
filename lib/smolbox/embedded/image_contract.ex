defmodule SmolBox.Embedded.ImageContract do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.{Image, Source}

  def source(%Source{} = source),
    do: %{"reference" => source.reference, "platform" => Source.oci_platform(source)}

  def source?(wire), do: match?({:ok, _}, decode_source(wire))

  def image?(wire) do
    Shape.keys?(wire, ~w(reference digest size architecture os layerCount)) and
      match?({:ok, %Image{digest_kind: :configuration}}, Image.from_wire(wire))
  end

  def matches?(wire, source) do
    with true <- image?(wire),
         {:ok, source} <- decode_source(source),
         {:ok, image} <- Image.from_wire(wire),
         do: Image.matches?(image, source),
         else: (_ -> false)
  end

  defp decode_source(wire) do
    architecture =
      case wire do
        %{"platform" => "linux/amd64"} -> "x86_64"
        %{"platform" => "linux/arm64"} -> "aarch64"
        _ -> nil
      end

    if Shape.keys?(wire, ~w(reference platform)) and architecture != nil,
      do: Source.oci(id: "native-pull", reference: wire["reference"], architecture: architecture),
      else: :error
  end
end
