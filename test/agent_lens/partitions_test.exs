defmodule AgentLens.PartitionsTest do
  use ExUnit.Case, async: true

  alias AgentLens.Partitions

  describe "spec/2 for the weekly runs table" do
    test "names the partition by ISO year and week" do
      assert %{name: "runs_2026w36"} = Partitions.spec(:runs, ~D[2026-08-31])
    end

    test "covers exactly seven days, starting Monday" do
      %{from: from, to: to} = Partitions.spec(:runs, ~D[2026-08-31])

      assert DateTime.to_date(from) == ~D[2026-08-31]
      assert DateTime.to_date(to) == ~D[2026-09-07]
      assert Date.day_of_week(DateTime.to_date(from)) == 1
    end

    # The case naive year-based naming gets wrong: 1 January 2026 is a Thursday,
    # so it belongs to ISO week 1 of 2026, whose Monday falls in December 2025.
    test "uses the ISO week year across a year boundary" do
      assert %{name: "runs_2026w01", from: from} = Partitions.spec(:runs, ~D[2026-01-01])
      assert DateTime.to_date(from) == ~D[2025-12-29]
    end

    test "gives every day of a week the same partition" do
      names =
        for offset <- 0..6 do
          ~D[2026-08-31]
          |> Date.add(offset)
          |> then(&Partitions.spec(:runs, &1))
          |> Map.get(:name)
        end

      assert Enum.uniq(names) == ["runs_2026w36"]
    end

    test "gives the next week a different partition" do
      this_week = Partitions.spec(:runs, ~D[2026-08-31])
      next_week = Partitions.spec(:runs, ~D[2026-09-07])

      refute this_week.name == next_week.name
      assert this_week.to == next_week.from
    end

    test "accepts a DateTime as well as a Date" do
      assert %{name: "runs_2026w36"} = Partitions.spec(:runs, ~U[2026-08-31 13:45:00Z])
    end
  end

  describe "spec/2 for the monthly observations table" do
    test "names the partition by year and month" do
      assert %{name: "kpi_observations_2026m08"} =
               Partitions.spec(:kpi_observations, ~D[2026-08-31])
    end

    test "runs from the first of the month to the first of the next" do
      %{from: from, to: to} = Partitions.spec(:kpi_observations, ~D[2026-08-15])

      assert DateTime.to_date(from) == ~D[2026-08-01]
      assert DateTime.to_date(to) == ~D[2026-09-01]
    end

    test "rolls over the year in December" do
      %{name: name, to: to} = Partitions.spec(:kpi_observations, ~D[2026-12-15])

      assert name == "kpi_observations_2026m12"
      assert DateTime.to_date(to) == ~D[2027-01-01]
    end
  end

  describe "specs/3 covering a range" do
    test "returns one partition per week, inclusive of both ends" do
      specs = Partitions.specs(:runs, ~D[2026-08-31], ~D[2026-09-14])

      assert Enum.map(specs, & &1.name) == ["runs_2026w36", "runs_2026w37", "runs_2026w38"]
    end

    test "returns one partition per month" do
      specs = Partitions.specs(:kpi_observations, ~D[2026-08-15], ~D[2026-10-02])

      assert Enum.map(specs, & &1.name) == [
               "kpi_observations_2026m08",
               "kpi_observations_2026m09",
               "kpi_observations_2026m10"
             ]
    end

    test "returns a single partition when both ends fall in one bucket" do
      assert [%{name: "runs_2026w36"}] = Partitions.specs(:runs, ~D[2026-08-31], ~D[2026-09-04])
    end

    test "never returns duplicates" do
      specs = Partitions.specs(:runs, ~D[2026-01-01], ~D[2026-12-31])
      names = Enum.map(specs, & &1.name)

      assert Enum.uniq(names) == names
    end

    test "returns nothing when the range is inverted" do
      assert [] = Partitions.specs(:runs, ~D[2026-09-14], ~D[2026-08-31])
    end

    test "produces contiguous partitions with no gaps" do
      specs = Partitions.specs(:kpi_observations, ~D[2026-01-01], ~D[2026-12-31])

      specs
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [earlier, later] ->
        assert earlier.to == later.from, "gap between #{earlier.name} and #{later.name}"
      end)
    end
  end

  describe "spec/2 rejects an unpartitioned table" do
    test "raises for a table that is not partitioned" do
      assert_raise ArgumentError, ~r/kpi_rollups/, fn ->
        Partitions.spec(:kpi_rollups, ~D[2026-08-31])
      end
    end
  end
end
