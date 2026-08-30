defmodule AgentLens.Kpi.FieldManifestTest do
  use ExUnit.Case, async: true

  alias AgentLens.Kpi.FieldManifest

  describe "flattened run columns" do
    test "accepts a known column" do
      assert :ok = FieldManifest.validate_path(:latency_ms)
      assert :ok = FieldManifest.validate_path(:status)
      assert :ok = FieldManifest.validate_path(:cost_usd)
    end

    # The typo this whole mechanism exists to catch.
    test "rejects an unknown column and names it" do
      assert {:error, message} = FieldManifest.validate_path(:latencey_ms)
      assert message =~ "latencey_ms"
    end

    test "suggests the known columns so the error is actionable" do
      assert {:error, message} = FieldManifest.validate_path(:nonsense)
      assert message =~ "latency_ms"
    end
  end

  describe "payload jsonb paths" do
    test "accepts a path rooted at a known LangSmith run key" do
      assert :ok = FieldManifest.validate_path({:payload, ["outputs", "text"]})
      assert :ok = FieldManifest.validate_path({:payload, ["extra", "metadata", "model"]})
    end

    test "rejects a path rooted at an unknown key" do
      assert {:error, message} = FieldManifest.validate_path({:payload, ["outpts", "text"]})
      assert message =~ "outpts"
    end

    test "rejects an empty path" do
      assert {:error, _} = FieldManifest.validate_path({:payload, []})
    end

    test "rejects non-string segments, since jsonb keys are strings" do
      assert {:error, _} = FieldManifest.validate_path({:payload, [:outputs, :text]})
    end
  end

  describe "feedback keys" do
    # Section 4's naming convention, enforced rather than documented.
    test "accepts a key following the kpi. convention" do
      assert :ok = FieldManifest.validate_path({:feedback, "kpi.toxicity"})
    end

    test "rejects a key that does not follow the convention" do
      assert {:error, message} = FieldManifest.validate_path({:feedback, "toxicity"})
      assert message =~ "kpi."
    end
  end

  describe "validate/1 over a whole requires/0 list" do
    test "accepts an empty list, as a derived KPI declares" do
      assert :ok = FieldManifest.validate([])
    end

    test "accepts a mixed list of valid paths" do
      assert :ok =
               FieldManifest.validate([
                 :latency_ms,
                 {:payload, ["outputs", "text"]},
                 {:feedback, "kpi.toxicity"}
               ])
    end

    test "reports the first invalid path" do
      assert {:error, message} = FieldManifest.validate([:latency_ms, :bogus_field])
      assert message =~ "bogus_field"
    end

    test "rejects a malformed entry" do
      assert {:error, _} = FieldManifest.validate(["latency_ms"])
    end
  end
end
