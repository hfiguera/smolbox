defmodule SmolBox.Embedded.NativePartialBranchHistory do
  @moduledoc false
  alias SmolBox.Embedded.{NativeBranchBacking, NativeBranchRetirement, PartialBranchChildAbsence}

  def retirement?(%{retirement: nil, backing: nil}), do: true

  def retirement?(
        %{retirement: %NativeBranchRetirement{proof: %PartialBranchChildAbsence{}} = saved} =
          authority
      ),
      do: NativeBranchRetirement.valid?(saved, authority) and backing?(authority)

  def retirement?(_), do: false
  defp backing?(%{backing: nil}), do: true

  defp backing?(%{backing: %NativeBranchBacking{} = saved} = authority),
    do: NativeBranchBacking.valid?(saved, authority)

  defp backing?(_), do: false
end
