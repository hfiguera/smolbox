defmodule SmolBox.ArtifactPath do
  @moduledoc false

  def valid?(path, kind) when kind in [:image, :checkpoint] do
    is_binary(path) and byte_size(path) <= 1024 and String.valid?(path) and
      String.starts_with?(path, "/") and
      String.ends_with?(
        path,
        if(kind == :checkpoint, do: [".smolcheckpoint", ".checkpoint"], else: ".smolmachine")
      ) and
      not String.contains?(path, ["\0", "/../", "/./", "//"])
  end

  def valid?(_path, _kind), do: false
end
