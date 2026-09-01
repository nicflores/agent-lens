# Backend guidelines

Rules for changing the AgentLens backend, and the reasoning behind them. Where a
rule looks arbitrary, the reasoning is the important half.

Two ideas govern almost everything here:

1. **Absent is not zero.** Every layer distinguishes "we measured and it was
   zero" from "we have nothing". Collapsing those is how a dashboard ends up
   confidently wrong.
2. **Adding a KPI is one file plus one config line.** Every abstraction exists to
   protect that. If a change would make adding a KPI require touching a second
   place, the abstraction has leaked and the change is wrong.

---

## 1. The shape of the system

```
LangSmith ──► Poller ──► Importer ──► runs + kpi_observations
                                            │
                                            ▼
                                   Rollup ──► kpi_rollups ──► Query ──► Cache ──► LiveView
                                            ▲                             ▲
                                Derived ────┘                    Broadcaster (single writer)
```

| Layer | Module | Rule |
|---|---|---|
| Domain (pure) | `AgentLens.Kpi.*` | no I/O, no processes, no database |
| Persistence | `AgentLens.Store.*` | Ecto schemas only; no business logic |
| Ingestion | `AgentLens.Ingestion.*` | writes runs and observations |
| Aggregation | `AgentLens.Rollup`, `.Derived` | observations → buckets |
| Read | `AgentLens.Query` | reads `kpi_rollups` and **nothing else** |
| Distribution | `AgentLens.Broadcaster`, `.Cache` | one writer, N readers |

**Processes only at the edges.** Pollers and the broadcaster own state or a
lifecycle. Everything else is a function over data. A GenServer is not a place to
put logic that is really just a function — `Kpi.Registry` returns a map, not a
process, deliberately.

---

## 2. The three kinds of KPI

| Kind | Cost | When |
|---|---|---|
| `:extracted` | free — arithmetic on the payload | inline on every run at ingest |
| `:judged` | a model call | sampled, asynchronous |
| `:derived` | cheap, needs other KPIs' rollups | on bucket close |

Plus a fourth **source** (not a kind): `:imported`, meaning LangSmith's own
evaluators scored it. `kpi_observations.source` is `extracted | judged |
imported`.

**Derived values go straight to `kpi_rollups`, never to `kpi_observations`.** A
derived value is a property of a bucket, not of any run — there is no run to
attach it to.

---

## 3. `aggregation` is data, not code

`AgentLens.Rollup` computes the **whole statistic set** — count, sum, min, max,
p50, p95, p99, distinct — for every KPI, and the definition's `aggregation`
selects which one the read path treats as the value.

> **`Rollup` must never mention a KPI.** No branching on slug, no special cases.
> If a new KPI requires editing the rollup layer, the abstraction has leaked.

The same applies to `Rollup.value_expression/1` and `combine_expression/1`: they
switch on the *aggregation*, never on the KPI.

**Percentiles do not compose.** A day's p95 is not the average, or the maximum,
of 24 hourly p95s. Each grain is computed from raw observations. Never build a
coarser bucket from finer ones.

When the read path *must* combine buckets to fit a point budget, percentiles take
the max and the series is flagged `downsampled?`. That is an envelope, and the UI
says so.

---

## 4. Absent is not zero

This is the invariant that most often gets broken by well-meaning changes.

- `compute/1` returns **`:skip`**, not `{:ok, 0.0}`, when a run carries no
  observation. A run still in flight has no outcome; scoring it zero would
  depress the rate with data that does not exist.
- `Status.evaluate/3` returns **`:unknown`** for an absent value, an inadequate
  sample, or stale data. **It must never fall through to `:good`.**
- `Query.series/5` omits missing buckets entirely. No zero-filling, no
  interpolation.
- Retention purges payloads before rows. A run whose payload is gone cannot be
  judged, and the judge tier reports that rather than inventing a score.

`kpi_definitions.first_observed_at` records where a series legitimately begins.
Charts start there.

---

## 5. Sampling honesty

`kpi_rollups` carries **both** `sample_n` (observations behind the value) and
`population_n` (runs the bucket could have drawn from).

A toxicity score from 3 judged runs must not render identically to one from 400.
Any new aggregation or read path must carry both numbers through.

`Query.latest/3` picks the finest grain that is **adequately sampled**, not
simply the finest with data. At modest traffic an hour bucket holds fewer runs
than `min_sample_n`, so reading only the finest grain leaves every card
permanently grey — which misinforms exactly as much as a false green.

---

## 6. Time, partitions and retention

- **Every timestamp column in our own tables is `timestamptz`.** Ecto's
  `:utc_datetime_usec` creates `timestamp` *without* zone; comparing the two
  makes PostgreSQL reconcile them using the *session* time zone, which silently
  attaches values to the wrong buckets on a non-UTC connection. The bug is
  invisible on a UTC machine, which is what makes it worth a standing rule: if
  you add a timestamp column, make it `timestamptz` and add it to
  `NormalizeTimestampsToTimestamptz` if you are altering an existing table.

  The exceptions are `oban_jobs`, `oban_peers` and `schema_migrations`, which
  are not ours. Oban uses naive UTC deliberately and expects it — **do not
  "fix" those**. The rule is about tables we define and compare against each
  other.
- `runs` is partitioned weekly by `start_time`; `kpi_observations` monthly by
  `occurred_at`.
- **`occurred_at` is the run's `start_time`**, not when we computed the value. It
  is the partition key, and being stable is what lets recomputation *conflict and
  dedupe* rather than insert a duplicate. Never partition an observations-like
  table by a computation timestamp.
- PostgreSQL requires the partition key in every unique index, which is why the
  dedupe keys look wider than §7 of the spec describes.
- **No foreign key from observations to runs.** Retention drops partitions on
  independent clocks, and a FK would block dropping a `runs` partition its
  observations outlived.
- **Retention is `DROP PARTITION`, not `DELETE`** — constant time, and it takes
  the index entries with it. Payload purging is the one genuine `UPDATE`, because
  a payload is a column rather than a partition.
- Partitions must exist *before* the rows do. `AgentLens.Boot` runs in `init/1`
  so the supervision tree blocks until they exist; the importers also ensure a
  range for any batch they are about to write, because backfill reaches further
  back than the boot sweep provisions.

---

## 7. Ingestion

- **Two cursors per workspace**, `:runs` and `:feedback`, advancing
  independently. Feedback is written *after* the run it attaches to, so a shared
  watermark would either stall runs behind a slow evaluator or skip feedback that
  had not landed.
- **Every poll re-reads an overlap window** behind its watermark, because runs
  can be updated after creation. Everything therefore **upserts**; importing the
  same page twice must converge, never accumulate.
- Watermarks are **monotonic**. A page of only older records must not rewind the
  cursor.
- **Orphan feedback holds the cursor back.** A score whose run is not stored yet
  is skipped *and the watermark does not advance past it*, so it is retried
  rather than lost. Draining stops when a page makes no progress, or orphans
  would loop forever.
- A failed poll records the error and **leaves the cursor alone**, so the window
  is retried rather than skipped.
- Agent identity is the **LangSmith workspace**, taken from the workspace polled
  — never from a payload field. Trusting the payload would let a misconfigured
  agent write into another's series.

---

## 8. Read path

- **Never compute on read.** `Query` touches `kpi_rollups` only. No aggregation
  over `runs` or `kpi_observations`. If a page needs something the rollups do not
  have, add it to the rollup, not to the query.
- **One writer, N readers.** `Broadcaster` computes and publishes; LiveViews
  subscribe. Load must never scale with how many people are looking.
- The ETS cache is `:public` with `read_concurrency` and readers touch it
  directly — a mount must be a table lookup, not a message to a process that
  twenty dashboards would queue behind.
- Per-agent **threshold overrides apply wherever status is judged**, loaded once
  per summary rather than per KPI.

---

## 9. Boot and failure

- `Kpi.Registry` validates every configured module at boot and **refuses to
  start** on a problem: an unknown required field, an unregistered or cyclic
  `depends_on`, malformed thresholds. A typo becomes a startup error naming the
  field rather than a `nil` crash in a worker at 3am.
- `FieldManifest` is what makes `requires/0` checkable. If you store a new
  column, add it there.
- **Never `String.to_atom/1` on external input** — LangSmith payloads, job args,
  database values, URL segments. Atoms are not garbage collected. Use
  `to_existing_atom/1` and handle the failure.
- Tagged tuples for expected failure; `raise` only for programmer error. The
  registry's boot refusal is the one justified raise.

---

## 10. Drift and derived KPIs

- Derived KPIs declare `depends_on/0`. Without it the wiring would live in the
  rollup module, which is exactly the leak the behaviour prevents.
- **The drift baseline excludes unhealthy periods.** A rolling baseline that
  contains a past incident reads as drift for the whole length of the baseline
  *after* recovery — 30 days of false alarms. The baseline keeps only buckets
  inside the source KPI's own thresholds.
- That filtering uses `Thresholds.classify/3` directly, **not**
  `Status.evaluate/3`: the question is "was this period anomalous", not "is this
  bucket individually trustworthy". Consulting `min_sample_n` at hour grain would
  discard the entire baseline.
- PSI bins are sized to the sample (~20 observations per bin). Fixed bins are
  biased upward on small samples and read as drift on demonstrably stable data.

---

## 11. Judged KPIs and backfill

The local judge tier exists so a KPI added today has *history*. A LangSmith
online evaluator only scores traces going forward, so without it the chart begins
the day you switched the evaluator on — and drift has no baseline for a month.

- `judge_prompt/1` and `parse_score/1` are optional callbacks. The KPI writes a
  prompt and reads a string; the worker owns every model call.
- An unparseable reply is a **failure**, not a skip — the run is still judgeable
  and should be retried.
- The LLM client points at a **LiteLLM proxy**, not a provider SDK. Routing, keys
  and cost accounting already live there.
- Backfill is many small Oban jobs that queue their own successors, so it stays
  pausable and retryable.

---

## 12. Configuration

- Clients are chosen by **whether they are actually configured**. No
  `LANGSMITH_API_KEY` means the mock, so a deploy that lost its credentials
  degrades rather than crashes. Same for `LITELLM_ENDPOINT`.
- **But say so.** The UI shows a "Mock data" badge when the mock is live.
  Generated numbers must never be mistaken for measured ones.
- Asking explicitly for a real client without credentials still fails loudly.
- Mocks are **deterministic** — hash-derived, no `:rand`, no process state — so
  the same window returns identical data forever. That is what makes them usable
  as drift fixtures rather than filler.

---

## 13. Testing conventions

- **Test-first.** Write it, watch it fail, then implement. A test that passes on
  first run has proved nothing about its ability to catch a regression.
- **Name the failure the test prevents.** Most tests here carry a one-line
  comment explaining what would break. That comment is the valuable part.
- Do not couple two contracts in one test. If a test asserts both what a
  publisher sends *and* what a subscriber does with it, it will pass or fail for
  reasons unrelated to either.
- Long-lived processes (`Broadcaster`, `Cache`) are shared across tests. Clear
  the cache in `setup`, and do not depend on their accumulated state.
- The **acceptance test** in `registry_test.exs` defines a KPI inside the test
  file and asserts it registers and evaluates with no other module touched. If a
  change breaks it, the one-file-plus-one-line promise is broken.

---

## 14. Quality gates

```bash
mix precommit    # compile --warnings-as-errors, unused deps, format, credo --strict, test
mix dialyzer
```

Both must be clean. `credo --strict` and `--warnings-as-errors` are gates, not
suggestions — they were wired up in Phase 0 precisely so they constrain code as
it is written rather than being retrofitted.

---

## 15. Checklist before shipping a backend change

- [ ] Adding a KPI is still one file plus one config line
- [ ] No branching on KPI slug in `Rollup`, `Query`, or any component
- [ ] `:skip` used where there is no observation; no zeros invented
- [ ] `:unknown` cannot fall through to `:good`
- [ ] `sample_n` and `population_n` both carried through
- [ ] New timestamp columns are `timestamptz`
- [ ] No `String.to_atom/1` on anything external
- [ ] Writes upsert; re-running converges
- [ ] Read path touches `kpi_rollups` only
- [ ] `mix precommit` and `mix dialyzer` pass
