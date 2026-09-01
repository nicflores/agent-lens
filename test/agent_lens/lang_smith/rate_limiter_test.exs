defmodule AgentLens.LangSmith.RateLimiterTest do
  use ExUnit.Case, async: true

  alias AgentLens.LangSmith.RateLimiter

  defp limiter(opts) do
    name = :"limiter_#{System.unique_integer([:positive])}"
    start_supervised!({RateLimiter, Keyword.put(opts, :name, name)})
    name
  end

  describe "a full bucket" do
    test "lets a burst through without waiting" do
      limiter = limiter(capacity: 5, refill_per_second: 1.0)

      for _ <- 1..5 do
        assert {:ok, 0} = RateLimiter.acquire(limiter)
      end
    end

    test "reports what is left" do
      limiter = limiter(capacity: 5, refill_per_second: 0.001)

      {:ok, 0} = RateLimiter.acquire(limiter)

      assert RateLimiter.available(limiter) < 5.0
    end
  end

  # Backfill is what this exists for: a cold start drains ninety days as fast
  # as the API will answer.
  describe "an exhausted bucket" do
    test "makes the caller wait rather than exceeding the budget" do
      limiter = limiter(capacity: 1, refill_per_second: 50.0)

      {:ok, 0} = RateLimiter.acquire(limiter)
      {:ok, waited} = RateLimiter.acquire(limiter)

      assert waited > 0
    end

    test "refills over time" do
      limiter = limiter(capacity: 2, refill_per_second: 200.0)

      {:ok, _} = RateLimiter.acquire(limiter)
      {:ok, _} = RateLimiter.acquire(limiter)
      Process.sleep(50)

      assert RateLimiter.available(limiter) >= 1.0
    end

    test "never refills past its capacity" do
      limiter = limiter(capacity: 2, refill_per_second: 1_000.0)
      Process.sleep(20)

      assert RateLimiter.available(limiter) <= 2.0
    end
  end

  # Rate limits are an org-wide budget. Per-process limits would multiply by the
  # number of agents, and the real ceiling would drift up with every agent added.
  describe "sharing one budget" do
    test "concurrent callers queue against the same bucket" do
      limiter = limiter(capacity: 2, refill_per_second: 100.0)

      results =
        1..6
        |> Task.async_stream(fn _ -> RateLimiter.acquire(limiter) end,
          max_concurrency: 6,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == 6
      assert Enum.any?(results, fn {:ok, waited} -> waited > 0 end)
    end
  end
end
