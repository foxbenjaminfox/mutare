defmodule Mutare.InstallTest do
  use ExUnit.Case, async: true

  alias Mutare.Install

  describe "requirement/1" do
    test "on 0.x, names the full version, holding the window to its minor" do
      assert Install.requirement("0.4.0") == "~> 0.4.0"
      assert Install.requirement("0.4.3") == "~> 0.4.3"
    end

    test "from 1.0, major.minor is enough" do
      assert Install.requirement("1.0.0") == "~> 1.0"
      assert Install.requirement("1.2.3") == "~> 1.2"
    end

    test "every suggested 0.x requirement admits its version and later patches, nothing else" do
      for minor <- 0..9, patch <- 0..9 do
        requirement = Install.requirement("0.#{minor}.#{patch}")
        assert Version.match?("0.#{minor}.#{patch}", requirement)
        assert Version.match?("0.#{minor}.#{patch + 1}", requirement)
        if patch > 0, do: refute(Version.match?("0.#{minor}.#{patch - 1}", requirement))
        refute Version.match?("0.#{minor + 1}.0", requirement)
      end
    end

    test "a pre-release keeps its release's window, floored at the pre-release" do
      assert Install.requirement("0.5.0-rc.1") == "~> 0.5.0-rc.1"
      assert Install.requirement("1.2.0-rc.1") == "~> 1.2-rc.1"
      assert Install.requirement("1.0.0-alpha.2.x") == "~> 1.0-alpha.2.x"
    end

    # Hex matches as `allow_pre: false` does: a pre-release only where the requirement names one.
    test "every suggested pre-release requirement admits it, its successors and its release" do
      for major <- 0..2, minor <- 0..4, patch <- 0..2 do
        release = "#{major}.#{minor}.#{patch}"
        requirement = Install.requirement(release <> "-rc.1")

        for admitted <- [release <> "-rc.1", release <> "-rc.2", release],
            do: assert(Version.match?(admitted, requirement, allow_pre: false))

        next_breaking = if major == 0, do: "0.#{minor + 1}.0", else: "#{major + 1}.0.0"
        refute Version.match?(next_breaking, requirement, allow_pre: false)
      end
    end
  end
end
