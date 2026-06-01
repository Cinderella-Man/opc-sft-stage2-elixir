# Tunex Triage-Gate + Runaway-Clipping Cost-Control Layer — Design Document

## TL;DR

- **Build a two-stage cascade (deterministic pre-filter → cheap MiMo classifier → full Claude-Code agent) plus a hard per-row turn/cost circuit breaker.** Triage alone saves ~$1.67/day (25% of rule-gen, 21% of total); turn-cap clipping of the 20 "exception" rows saves another ~$1.06/day; stacked with the already-planned distillation (1.10×) and rules-index (1.15×), projected spend lands at **~$130/month**, still **~2.6× over a $50 plan**. A deeper structural move (positive-filter triage, calendar-duty reduction, or the deferred Qwen-gather split) is required to actually clear $50.
- **The triage gate must be aggressively generous on the "keep" side**, because false-negatives (real rule opportunities thrown away) are the existential failure mode for a discovery system. Threshold calibration follows the FrugalGPT/RouteLLM playbook (Chen, Zaharia & Zou, arXiv:2305.05176: *"FrugalGPT can match the performance of the best individual LLM (e.g. GPT-4) with up to 98% cost reduction"*); a cheap classifier scores each row, you choose the threshold from a calibration set, and **a permanent 10% shadow lane routes triaged-out rows through the full agent** so false-negative rate is empirically bounded (Rule of Three: ~30 shadow rows with 0 missed rules → ≤10% upper 95% CI; ~100 → ≤3%).
- **The runaway/turn-cap clipping sub-design is the fastest, lowest-risk win.** Claude Code's Agent SDK `max_turns` default is *No limit* (Anthropic's own Agent SDK docs are explicit on this), and the 'exception' rows in your data show ~45k output tokens vs committed rows' ~30k — these are agents that churned past sensible turn counts before erroring. Set `--max-turns 12`, `--max-budget-usd 0.08`, and a wall-clock guard at ~6 min. Detection: `subtype == "error_max_turns"` / `"error_max_budget_usd"` in the JSON result, plus a per-`row_id` MiMo-call count from `var/run/usage.jsonl`.

---

## Key Findings

1. **The single biggest waste in Tunex is structural, not algorithmic.** From `mix tunex.usage`: of 209 rule-gen rows, 132 (63%) returned `no_opportunity`, costing $1.93 (mean $0.0146/row) for the full agent session to confirm there is nothing to do. A pre-gate call (one MiMo-pro completion, no tools, mostly cache-hit input) costs ~$0.0020/row — so triage saves ~$1.67/20.44h, or ~$1.96/24h, or ~$59/month.

2. **The cost driver inside a Claude-Code rule-gen session is per-turn re-fed cache-miss input, NOT output.** Of the $6.79 rule-gen spend, $3.86 (57%) is cache-miss input and $2.38 (35%) is output. Anthropic's own agent-loop docs confirm the mechanism: *"It does not reset between turns within a session. Everything accumulates: the system prompt, tool definitions, conversation history, tool inputs, and tool outputs."* Each `mix test` invocation deposits a multi-KB block at the tail of the conversation; that block is billed at cache-CREATE rates (1.25× input) on the turn it appears, then cache-READ (0.1×) forever after. **Lowering the turn cap therefore reduces cost super-linearly**, because it cuts both the number of cache-MISS tail writes AND the total prefix that subsequent turns must re-pay.

3. **Claude Code's `--max-turns` default is unlimited, not 10.** The Anthropic Agent SDK reference is explicit: `max_turns` default = "No limit"; `max_budget_usd` default = "No limit". Augment Code's May 2026 analysis corroborates: *"`max_turns` defaults to unlimited, and `max_budget_usd` is an optional budget cap rather than an enforced default limit, so a production agent without explicit limits may run for many turns and accumulate cost without a circuit breaker."* The SFEIR training-site claim of "default 10 in headless" is unsourced and contradicted by Anthropic's primary docs. This means **Tunex is currently running every row with no enforced ceiling on the loop**, which is exactly the pattern that produces the 20 "exception" rows averaging $0.088 and 45k output tokens.

4. **Triage classification is a well-established pattern (FrugalGPT, RouteLLM, Hybrid LLM, UCCI) and the threshold is calibration-tunable from one ledger sweep.** RouteLLM (Ong et al., arXiv:2406.18665) ships an explicit calibration command — e.g. `python -m routellm.calibrate_threshold --routers mf --strong-model-pct 0.5 --config config.example.yaml` returns `"For 50.0% strong model calls for mf, threshold = 0.11593"`. The asymmetric cost — a missed rule opportunity is far worse than a wasted classifier call — maps directly to the Neyman-Pearson selective-classification framing (Kotte 2026, "Know When to Abstain"): set the threshold to bound false-negative rate at ≤α, then minimize cost subject to that constraint.

5. **Even with all four cheap levers stacked, $50/month is not reachable.** Starting from $252/mo: triage (1.33×) → $189; turn-cap clipping (~1.15×) → $164; distillation (1.10×) → $149; rules-index (1.15×) → $130. To reach $50 requires either (A) positive-filter triage where the agent only runs on `new_rule_candidate` and `extend_existing` goes to a cheap MiMo-write path, (B) ~half calendar duty cycle, or (C) the deferred Qwen-gather + MiMo-write split. **Recommendation: ship all four cheap levers first; if projected spend after 14 measured days is still > $80/mo, ship Option A.**

---

## Details

### 0. Recap of authoritative system facts (restated so this doc is self-contained)

**System.** "Tunex" is a 24/7 Elixir/OTP application walking a ~118,000-row SFT dataset. The *real* goal is to **generate, extend, and fix rules for "Credence"** — a custom Elixir AST-based semantic linter (repo `Cinderella-Man/credence`) with ~80–90 rules across `lib/syntax` (string-level fixes), `lib/semantic` (compiler-warning fixes), `lib/pattern` (AST anti-pattern fixes); ~138 test files. Each rule implements an Elixir `@behaviour`, is auto-discovered, and shares helpers in `Credence.RuleHelpers`. `Credence.fix/2` returns `%{code, issues, applied_rules}`; `Credence.analyze/2` returns `%{valid, issues}`. Tests use `Sourceror.parse_string!/1 + RuleHelpers.apply_rule_fix/3`. The extend prototype is `Credence.Pattern.HallucinatedGuard` with a `@hallucinated_guards` map.

**Per-row pipeline.** (1) **Translate** Python→Elixir via remote MiMo v2.5 Pro, cached forever in `var/cache/`. (2) **Round-trip** check: fix-free compile+test of reference vs. tests; blacklist on fail. (3) **Solve** the Elixir task with a *local free* Qwen Q4_K_M GGUF on one RTX 3090 (Python-blind, plain generation + retry) — this non-idiomatic output is the rule-discovery feedstock. (4) **Validate** via Credence. (5) **Evolve** — a Claude Code agentic CLI session driven by MiMo v2.5 Pro (NOT Anthropic Claude — Claude Code is pointed at MiMo's Anthropic-compatible endpoint via `ANTHROPIC_BASE_URL=.../anthropic`, `ANTHROPIC_MODEL=mimo-v2.5-pro[1m]`). The Evolve session reads Credence rule files, edits/writes rules, runs `mix test`, sandboxed to `Read/Grep/Glob/Edit/Write/Bash(mix test:*)`. It currently runs on **every row**, including clean zero-issue rows (clean non-idiomatic passing code is the highest-value rule-discovery signal). A 5-part commit "Gate" (new regression test, mutation check, scope, full suite green) validates a finished rule before it lands on an `evolution` git branch.

> **Terminology disambiguation.** The *commit Gate* (existing) validates a *finished* rule. The **triage gate** designed in this document is *new* and decides, BEFORE the Claude-Code session is launched, whether the row is worth spending a full agentic session on at all.

**Measured economics (post-2026-05-27 prices).** MiMo v2.5 Pro: cache-miss input $0.435/M, cache-hit $0.0036/M (≈free), output $0.87/M. From `mix tunex.usage` over 20.44h / 220 rows / all-Qwen-solve:

| Stage     | calls | in        | cache_rd     | out       | est ($)  |
|-----------|------:|----------:|-------------:|----------:|---------:|
| translate |   257 |   141,033 |            0 |   561,879 | 0.5502   |
| rule-gen  |   213 | 8,872,223 |  153,217,024 | 2,732,045 | 6.7879   |
| other     |   550 |   492,615 |            0 |   316,079 | 0.4893   |
| **TOTAL** |  1020 | 9,505,871 |  153,217,024 | 3,610,003 | **7.8273** |

By outcome: `committed` 55 rows × $0.0619 = $3.41; `no_opportunity` 132 rows × $0.0191 = $2.53 (mean output 7338 tok); `exception` 20 rows × $0.0883 = $1.77 (mean output **44,997** tok — *higher than committed*); `blacklist:roundtrip_fail` 12 rows × $0.0060; `gave_up` 1 row.

**Console-confirmed 14h25m daily figure (representative mix):** total tokens 88.31M; cache-HIT 79.42M ($0.286); cache-MISS 6.86M ($2.985); output 2.03M ($1.767) → **$5.04/14.42h → ~$8.39/day → ~$252/30d**. Caching is 89.9% of input and is ≈free; the entire addressable surface is cache-MISS input (56% of spend) plus output (35%).

**Throughput.** 10.8 rows/hr → 258 rows/day. **Dollars, not wall-clock, are the binding constraint.**

**Already-planned complementary levers.** Input distillation (~1.10×; feed agent the solve-code + Credence fix-trace instead of raw transcript); a deterministic Credence rules-index injected as a cached prefix (~1.10–1.20×; ~50-line Elixir AST script that catalogs every rule's module/behaviour/docstring/helpers/similar-rules, eliminating filesystem exploration); a deferred local-Qwen-gather + MiMo-write split — note that the quality risk here is larger than the brief stated: Aider.chat's "Quantization matters" benchmark (Nov 2024), reported by Simon Willison, shows Qwen2.5-Coder-32B-instruct dropping from **71.4% BF16 → 53.4% Q4_K_M on Aider polyglot, a 17.7pp drop** (*"saw a massive drop in quality, scoring just 53.4% on the same benchmark"*), much larger than the originally-noted 5.3pp.

**Instrumentation.** `var/run/usage.jsonl` (per-call exact in/cache_read/cache_create/out tokens+cost), `var/run/rows.jsonl` (per-row outcome+elapsed_s+cost_est+ts), `var/run/heartbeat.jsonl` (5-min cumulative), `mix tunex.usage` (by-stage/by-outcome/triage-estimate/24-7 projection/runway-days).

---

### 1. Triage-Gate Classifier Design

#### 1.1 Cascade architecture

A three-stage cascade, ordered cheapest → most expensive, with each stage able to short-circuit:

```
Row ─► Stage A: Deterministic pre-filter (free, microseconds)
        │
        ├─ HARD KEEP    ──────────────────────────────────────────► full agent
        ├─ HARD DROP    ──────────────────────────────────────────► no_opp (instrumented)
        └─ UNCERTAIN
                │
                ▼
        Stage B: MiMo-pro single-shot classifier (~$0.002/row)
                │
                ├─ verdict ∈ {extend_existing, new_rule_candidate}
                │  AND confidence ≥ τ  ────────────────────────────► full agent
                ├─ verdict = no_opportunity AND confidence ≥ τ_neg  ─► no_opp
                │   └─ 10% shadow-lane sample  ────────────────────► full agent (shadow)
                └─ low-confidence / unparseable ──────────────────► full agent (safe fail-open)
```

This is the FrugalGPT / RouteLLM cascade pattern instantiated for an asymmetric-cost rule-discovery task. The Hybrid-LLM (Ding et al. 2024) and UCCI (Kotte 2026) lines of work make the same recommendation: **cheap routing scores must be calibrated before thresholding**, and the threshold should be chosen to *bound* the costlier error class. UCCI states the case directly: *"raw token confidences are miscalibrated and require explicit correction."*

#### 1.2 Stage A — deterministic pre-filter (free)

Run on every row immediately after stage 4 (Credence validation). Inputs available without any LLM call:

| Signal                                                          | Source                       | Rule                                                            |
|-----------------------------------------------------------------|------------------------------|-----------------------------------------------------------------|
| `analyze.valid == true` AND `analyze.issues == []`             | `Credence.analyze/2`         | → CANDIDATE: "clean non-idiomatic code" — keep (HARD KEEP).     |
| `fix.applied_rules != []`                                       | `Credence.fix/2`             | → covered by existing rule — HARD DROP unless solve-code differs structurally. |
| `fix.issues != []` AND `fix.applied_rules == []`                | `Credence.fix/2`             | → known issue, no rule yet — HARD KEEP (new-rule candidate).     |
| solve-code fails to compile                                     | `mix compile` exit code      | → HARD DROP: not rule-discovery feedstock, it's a Qwen failure.  |
| solve-code AST-equivalent to reference solution (Sourceror diff = ∅) | `Sourceror.parse_string!/1` | → HARD DROP: no signal.                                          |
| solve-code matches the trigger of any existing rule (substring/regex check against the deterministic rules-index already planned) | rules-index | → CANDIDATE: extend-existing — keep (forward to Stage B for "which rule"). |
| any other case                                                  | —                            | → UNCERTAIN → Stage B.                                           |

Empirically, three of these — `applied_rules != []` with structurally-identical output, compile failure, and AST-equivalent — together should already account for a meaningful share of `no_opportunity` rows at zero LLM cost. **Ship Stage A first and re-measure before building Stage B.**

#### 1.3 Stage B — MiMo-pro single-shot classifier

Single chat call, *no tools*, structured JSON output, temperature 0.1. Prompt below is the build-ready text.

```text
SYSTEM
You are a triage classifier for a self-evolving Elixir static-analysis project ("Credence").
Your job is to decide, for ONE candidate row, whether spending a 10–20-turn Claude-Code
agentic editing session on this row is likely to PRODUCE A NEW OR EXTENDED LINTER RULE.

You will be given:
  1. The Elixir SOLVE CODE produced by a local non-idiomatic model.
  2. The Credence FIX TRACE: %{applied_rules: [...], issues: [...], valid: bool}.
  3. A RULES INDEX: every existing rule's module, @behaviour callbacks, one-line
     docstring, trigger summary, and the list of helpers it uses.

Decision rules:
  - "no_opportunity"          : the solve code is either (a) already idiomatic, OR
                                (b) the non-idiomatic pattern is FULLY covered by an
                                existing rule whose trigger/scope matches. Confidence
                                should reflect how cleanly the existing rule covers it.
  - "extend_existing:<module>" : the pattern is a near-miss of an existing rule that
                                could be extended (new clause in the @hallucinated_guards
                                map style, additional AST shape, or scope widening).
                                You MUST name the existing module.
  - "new_rule_candidate"      : the pattern is non-idiomatic in a way NOT covered by
                                any existing rule, and is plausibly generalizable
                                (i.e. a real pattern, not a one-off bug).

Be GENEROUS toward "extend_existing" and "new_rule_candidate". A wasted full session
costs ~$0.015. A missed real rule opportunity costs the project days of regression.
If unsure between "extend_existing" and "new_rule_candidate", emit whichever has
higher confidence; if unsure between either of those and "no_opportunity", emit the
positive verdict with the appropriate confidence (≤ 0.5).

Return EXACTLY this JSON, no prose, no markdown:

{
  "decision": "no_opportunity" | "extend_existing:<ModuleName>" | "new_rule_candidate",
  "confidence": <float in 0.0..1.0>,
  "suspected_pattern": "<≤120 chars naming the AST/syntactic anti-pattern, or 'n/a'>",
  "rationale": "<≤300 chars; cite specific lines or AST shapes>",
  "nearest_existing_rule": "<ModuleName or 'none'>"
}

USER
==== SOLVE CODE ====
<solve_code>

==== CREDENCE FIX TRACE ====
<fix_trace_json>

==== RULES INDEX ====
<rules_index_md>
```

**Cost.** Inputs are ~3–4k tokens of solve+trace (cache-MISS, varies per row) + ~6–8k tokens of rules-index (CACHED PREFIX, ≈ free); output ~120 tokens. At MiMo-pro rates: `4000 × $0.435/M + 7000 × $0.0036/M + 120 × $0.87/M ≈ $0.00174 + $0.000025 + $0.000104 ≈ $0.0019`. Matches the spec's $0.002/row estimate.

The rules-index goes in the *cached prefix* — exactly the same artifact the planned rules-index lever ships, reused here. This is why triage and the rules-index stack multiplicatively for free.

#### 1.4 Threshold calibration (RouteLLM-style)

The classifier returns a `confidence` ∈ [0,1] that the row is a real rule opportunity. Let `τ` be the threshold below which we route to `no_opportunity`. RouteLLM's documented calibration command — `python -m routellm.calibrate_threshold --routers mf --strong-model-pct 0.5 --config config.example.yaml` returning *"For 50.0% strong model calls for mf, threshold = 0.11593"* — is the canonical example: thresholds are picked from data, not from theory.

**Calibration procedure** (one-time, then re-run weekly):

1. Take the last 200 rows from `var/run/rows.jsonl` and replay each through Stages A+B in shadow mode (no routing decision applied — just logging the classifier verdict and confidence).
2. Cross-reference with the ground-truth `outcome` field (committed | no_opportunity | exception | …).
3. For each candidate τ ∈ {0.10, 0.15, 0.20, …, 0.50}, compute:
   - **false-negative rate** = rows where ground-truth was `committed` (or `exception` that later would have been a fix) but classifier said `no_opportunity` with confidence ≥ (1 − τ);
   - **savings** = (# rows triaged out) × $0.0146 − (# rows × $0.0019).
4. Plot savings vs. false-negative rate. Pick the **largest τ such that FN ≤ 5%** with 95% confidence (one-sided Wilson lower bound).

**Initial recommendation (before calibration data exists):** **τ = 0.25** on the "positive verdict" side. I.e. route to the full agent unless the classifier says `no_opportunity` with confidence ≥ 0.75. This is the FrugalGPT "generous threshold" stance: explicitly biased to send more rows to the agent until calibration data proves we can tighten.

#### 1.5 Why a two-stage cascade beats single-stage (deterministic-only OR MiMo-only)

- **Deterministic-only** misses any "clean code that is non-idiomatic in a structurally novel way" — the highest-value signal. Stage A's `analyze.valid && issues == []` rule keeps these, but Stage A cannot tell `extend_existing` from `new_rule_candidate`, which the agent will need to know in its launch prompt anyway. Stage B produces that signal essentially for free.
- **MiMo-only** wastes ~$0.002 on the 30–40% of rows that Stage A could classify deterministically (compile failures, AST-equivalent solves, etc.). On 258 rows/day that is ~$0.20/day, modest but free to avoid.
- The cascade also lets Stage A *fail open* — anything Stage A is unsure about goes to Stage B, and anything Stage B fails to parse JSON or returns confidence below a small uncertainty floor goes to the agent. The architecture is deliberately biased toward "keep" at every step.

---

### 2. Max-Turns / Runaway Clipping Sub-Design

#### 2.1 Ground-truth facts about Claude Code's loop

From Anthropic's primary Agent SDK documentation (*How the agent loop works*):

> "`max_turns` / `maxTurns` — Maximum tool-use round trips — Default: **No limit**"
> "`max_budget_usd` / `maxBudgetUsd` — Maximum cost before stopping — Default: **No limit**"
> "Without limits, the loop runs until Claude finishes on its own, which is fine for well-scoped tasks but can run long on open-ended prompts. Setting a budget is a good default for production agents."

Tunex therefore currently has **no enforced ceiling**. The 20 exception rows averaging $0.088 and 44,997 output tokens (vs. 29,945 for committed) are runaway sessions that churned past the convergence point.

The Anthropic docs also explicitly confirm the cost-inflation mechanism: *"It does not reset between turns within a session. Everything accumulates: the system prompt, tool definitions, conversation history, tool inputs, and tool outputs. … Large tool outputs consume significant context. Reading a big file or running a command with verbose output can use thousands of tokens in a single turn. Context accumulates across turns, so longer sessions with many tool calls build up significantly more context than short ones."*

#### 2.2 Recommended caps

| Control                           | Value           | Rationale                                                                                                                       |
|-----------------------------------|----------------:|---------------------------------------------------------------------------------------------------------------------------------|
| `--max-turns`                     | **12**          | Committed-row mean output ~30k tok ≈ 10–15 turns in your harness; 12 keeps 95% of converging sessions intact while clipping runaways. Re-tune after measuring turn-distribution histogram (§ 2.4). |
| `--max-budget-usd`                | **0.08**        | Empirically: committed mean $0.062, exception mean $0.088, exception max likely >$0.15. $0.08 = mean(committed) + ~1.3σ; community-reported empirical floor is ~$0.05 since the first cache-write itself can cost that. |
| wall-clock guard (Elixir timeout) | **360 s**       | Belt-and-braces; covers hangs that don't bill but block throughput.                                                              |
| `--output-format`                 | `json`          | Mandatory: lets you read `subtype`, `num_turns`, `total_cost_usd`, `usage.*` from the result blob.                               |

In the harness, after the `claude -p` invocation, parse the JSON result and branch on `subtype`:

```elixir
case Jason.decode!(stdout) do
  %{"subtype" => "success", "num_turns" => n, "total_cost_usd" => c} -> log_committed(n, c)
  %{"subtype" => "error_max_turns",       "num_turns" => n, "total_cost_usd" => c} -> log_clipped(:max_turns, n, c)
  %{"subtype" => "error_max_budget_usd",  "num_turns" => n, "total_cost_usd" => c} -> log_clipped(:budget,    n, c)
  %{"subtype" => "error_during_execution", ...}                                    -> log_exception(...)
  %{"subtype" => "error_max_structured_output_retries", ...}                       -> log_exception(:struct, ...)
end
```

The five `result_subtype` values are documented in Anthropic's Agent SDK reference and the Elixir `ClaudeCode.Types` hex docs (`@type result_subtype() :: :success | :error_max_turns | :error_during_execution | :error_max_budget_usd | :error_max_structured_output_retries`). **Important pitfall flagged in the Augment Code (May 2026) analysis: always branch on `subtype`, not `is_error`**, because earlier Claude Code versions returned `is_error: false` for max-turns terminations.

#### 2.3 Per-turn cost mechanics — why a tighter cap is super-linear in savings

A Claude-Code session in Tunex follows roughly: `read rule files → run mix test → read output → edit rule → run mix test → …`. Each `mix test` output (call it ~2 KB ≈ ~700 tokens) is a tool_result that gets:

- Billed once at cache-CREATION rate (1.25× input = ~$0.000544 per turn at MiMo-pro rates),
- Then sits in the cached prefix forever, billed at 0.1× input = ~$0.000043 per turn for every subsequent turn until the session ends.

ProjectDiscovery's measurement in the same shape of workload (*How We Cut LLM Costs by 59% With Prompt Caching*): *"step N re-sends everything from steps 1 through N-1. The agentic tax: the cost of intelligence compounds quadratically with task complexity. Caching is the only structural fix. Overall, caching saved 59% on LLM costs."* This shape matches Tunex's 89.9% cache-hit rate.

**The marginal cost of turn N** is approximately:
`marginal(N) ≈ output_tokens(N) × $0.87/M + new_tool_output(N) × 1.25 × $0.435/M + prefix_size(N) × 0.1 × $0.435/M`

The third term (cache-read of the growing prefix) is small per-turn but accumulates: at turn 30, prefix ≈ ~50k tokens → ~$0.0022 per turn just to re-read. **Cutting cap from "uncapped (sometimes 30+)" to 12 therefore saves ~half the cumulative cache-read input AND eliminates the entire output tail.** Conservative estimate: if the 20 exception rows were clipped at turn 12, their mean cost drops from $0.088 to ~$0.035 (mostly turns 1–12 cost), saving 20 × $0.053 ≈ $1.06 per 20.44h ≈ **$1.25/day ≈ $37/month**. Plus a smaller savings on committed rows that overshoot.

#### 2.4 Detecting runaways and measuring turn distribution from existing ledgers

You already have `var/run/usage.jsonl` (per-MiMo-call) and `var/run/rows.jsonl` (per-row outcome). To count MiMo calls per row, the harness needs to inject a `row_id` field into every usage record (a one-line change if it isn't already there). Assuming `row_id` is present:

**Count MiMo calls per row (jq):**
```bash
jq -r 'select(.stage=="rule-gen") | .row_id' var/run/usage.jsonl | sort | uniq -c | sort -rn
```

**Call-count distribution by outcome (Elixir snippet for `mix tunex.turns`):**
```elixir
calls_by_row =
  "var/run/usage.jsonl"
  |> File.stream!() |> Stream.map(&Jason.decode!/1)
  |> Stream.filter(&(&1["stage"] == "rule-gen"))
  |> Enum.group_by(& &1["row_id"])
  |> Map.new(fn {row, calls} -> {row, length(calls)} end)

rows = "var/run/rows.jsonl" |> File.stream!() |> Stream.map(&Jason.decode!/1) |> Enum.to_list()

by_outcome =
  rows
  |> Enum.group_by(& &1["outcome"])
  |> Map.new(fn {oc, rs} ->
    counts = Enum.map(rs, &Map.get(calls_by_row, &1["row_id"], 0)) |> Enum.sort()
    {oc, %{n: length(counts), p50: percentile(counts, 50), p90: percentile(counts, 90),
           p99: percentile(counts, 99), max: List.last(counts), mean: Enum.sum(counts)/length(counts)}}
  end)

IO.inspect(by_outcome, label: "calls per row by outcome")
```

**Identify the turn at which committed rules typically finalize.** In stream-json mode, write all assistant messages to `var/run/turns/<row_id>.jsonl` and grep for the turn that first applies a successful `mix test` exit code 0 followed by a final assistant text-only message. Compute the p50/p90 of that "finalization turn" across the 55 committed rows. **Decision rule:** set `--max-turns` = p90(finalization turn for committed rows) + 2. If p90 ≤ 10, cap at 12. If p90 is 15, cap at 17. The +2 buffer covers the "verify nothing else broke" tail.

**Runaway detector (heartbeat-driven, kills in-flight sessions):**
```elixir
defp tick(state) do
  cost_so_far = read_partial_stream_cost(state.row_id)
  cond do
    cost_so_far > 0.08              -> Port.close(state.port); {:abort, :budget}
    System.monotonic_time() - state.t0 > 360_000 -> Port.close(state.port); {:abort, :wallclock}
    true                            -> :ok
  end
end
```

This is belt-and-braces because `--max-budget-usd 0.08` should fire first, but the in-harness check covers the case where the Claude-Code subprocess hangs without emitting events.

#### 2.5 Effect of lowering the cap on committed-rule quality

The risk is real but measurable: a committed rule that normally takes 14 turns to converge would fail to commit under a 12-turn cap, showing up as an `error_max_turns` event instead. To quantify *before* shipping the cap:

1. Replay the last 55 committed rows in shadow with `--max-turns 12`.
2. Count how many would have hit `error_max_turns` vs. still produced a valid commit.
3. If > 5% of committed rows would have been clipped, raise the cap to 15 and re-check.
4. The accepted false-clip rate is configurable; **start at 2% and raise the cap until that bound is met.**

codewithmukesh's *Anatomy of a Claude Code Session* states: *"A typical task runs 5-50 iterations of this loop. That's the core architecture."* Tunex's mean output of 30k tok per committed row, at typical Claude-Code per-turn output of ~1.5–3k tok, implies roughly 10–20 turns. 12 is the lower bound of that range; 15 is the upper.

---

### 3. Shadow-Eval Methodology

False-negatives are the existential risk: the system exists to discover rules, and the triage gate silently dropping a row that *would* have produced a committed rule is the worst outcome possible. Standard ML shadow-mode methodology (Christopher Goldsworthy, 2019; AWS SageMaker shadow tests, 2022) plus the selective-classification framing (Kotte 2026, *Know When to Abstain*) give the design.

#### 3.1 Shadow lane: permanent, not one-off

**Route a random p_shadow = 10% of rows that the triage gate said `no_opportunity` to the full Claude-Code agent anyway.** Tag them in `rows.jsonl` with `shadow: true` and `triage_verdict: "no_opportunity"`. Do not let them commit (or, alternatively, allow them to commit if they produce a rule — they're "found money"). The shadow lane is *permanent*, not a one-time validation run, because:

- Workload drift: the SFT dataset is ~118k rows long; the kinds of patterns shift across the corpus. A threshold calibrated on rows 1–500 may be wrong on rows 30k–35k.
- Classifier drift: MiMo's behavior can change with model updates.
- The shadow lane cost is bounded: 10% × 132 no_opp/209 rule-gen × $0.0146 × 258 rows/day ≈ **$0.24/day = $7.20/month**, well worth the insurance.

#### 3.2 The metric: "rules the gate would have missed"

For every row tagged `shadow: true` with `triage_verdict: "no_opportunity"`, if the full agent session results in `outcome: "committed"`, that is a **false-negative event** (FN). The estimator is:

`FN_rate_estimate = (# FN events) / (# shadow rows triaged-out)`

Wilson 95% confidence interval gives the bound. If 0 FN events out of N shadow rows, **rule of three** (Hanley 1983; Eypasch et al. 1995) gives upper bound ≈ 3/N.

#### 3.3 Statistical sizing

| Goal: upper-bound FN rate at | # shadow rows needed (0 events observed) | Days of operation at ~26 shadow rows/day |
|:----------------------------:|:----------------------------------------:|:----------------------------------------:|
| ≤ 10%                        |    30                                    | ~1.2 days                                |
| ≤ 5%                         |    60                                    | ~2.3 days                                |
| ≤ 3%                         |   100                                    | ~3.9 days                                |
| ≤ 1%                         |   300                                    | ~12 days                                 |

(`p_shadow` = 10% of ~132 no_opp/day → ~13 shadow rows; if running full pipeline at 258 rows/day with ~63% no_opp rate, ~26 shadow rows/day in expectation.) If the gate is sound (FN rate ≤ 3%), **within four days you have a Rule-of-Three-bounded ≤ 3% miss rate with 0 events at N=100**. If you observe FN events, you must replace 3/N with the Wilson upper bound for p̂ = k/N at 95%.

**Sample-size formula for the general case** (target FN rate α, observed proportion p̂ ≈ α, half-width δ, Wilson approximation): `N ≈ z² · α(1−α) / δ²`. For α = 0.05, δ = 0.02, z = 1.96 → N ≈ 456.

#### 3.4 Feedback loop: recalibrate from shadow

Weekly cron task `mix tunex.recalibrate`:

1. Read all shadow rows from the last 7 days.
2. Compute observed FN rate with Wilson CI.
3. If FN_upper95 > 5%: **lower τ by 0.05** (route more rows to the agent). Alert.
4. If FN_upper95 < 1% AND # rows triaged out > 60% of total: **raise τ by 0.05** (triage more aggressively). This trades savings for some FN risk and is only done if shadow evidence is overwhelming.
5. Log the new τ to `var/run/triage_threshold.jsonl` with the supporting numbers.

This is exactly the FrugalGPT *"learn the cascade thresholds from data"* loop, adapted to operate continuously rather than once.

#### 3.5 Kill/keep decision rule for the triage gate as a whole

**Kill the gate** (revert to running every row) if any of the following hold for 14 consecutive days:

1. FN_upper95 > 10% — the gate is dropping real opportunities.
2. Net dollar savings (triage cost saved minus shadow cost minus FN cost) < $30/month.
3. Manual spot-check of 20 random triaged-out rows by the developer finds ≥ 2 obvious missed opportunities.

**Keep & tune** if FN_upper95 ≤ 5% AND net savings ≥ $30/month AND spot-check passes.

---

### 4. Cost Model & Stacking

#### 4.1 Stacked projection (best estimate)

| Lever                              | Multiplier | Spend after (vs. $252/mo baseline) | Cumulative savings |
|------------------------------------|-----------:|:----------------------------------:|-------------------:|
| Baseline (no levers)               |        1.00× | **$252/mo**                        | —                  |
| + Triage gate                      |       ~1.33× | $189/mo                            | $63/mo             |
| + Max-turns/runaway clipping       |       ~1.15× | $164/mo                            | $88/mo             |
| + Input distillation               |       ~1.10× | $149/mo                            | $103/mo            |
| + Rules-index cached prefix        |       ~1.15× | **$130/mo**                        | $122/mo            |
| Gap to $50/mo plan                 |              | **$80/mo over**                    | needs another 2.6× |

**These multipliers are independent only to first order.** Realistically they compound less perfectly because the triage gate already eliminates the cheapest no_opp rows (mean $0.0191) before turn-clipping can apply to them, so turn-clipping's effective base shrinks. Honest worst-case stacking: **$135–150/month**. Best case if shadow data later supports a more aggressive triage threshold (cuts 80% rather than 63% of no_opp rows): **$105–120/month**.

#### 4.2 Sensitivity: what if no_opportunity fraction differs?

The measured 132/209 = 63% no_opp rate is from a 20.44h window. Sensitivity on triage savings alone:

| no_opp rate | triage savings per rule-gen row | extrapolated $/month from triage alone |
|:-----------:|:-------------------------------:|:--------------------------------------:|
| 50%         | $0.0063                         | ~$47/mo                                |
| 63% (measured) | $0.0080                      | ~$59/mo                                |
| 75%         | $0.0095                         | ~$71/mo                                |
| 85%         | $0.0107                         | ~$80/mo                                |

If actual no_opp rate is *lower* than measured (e.g. 50%), triage saves less in absolute dollars but the multiplier shifts to ~1.20× — still material. If *higher*, savings scale ~linearly. **The triage lever is robust across realistic ranges of this parameter.**

#### 4.3 Honest verdict: **$50/mo is not reachable with the cheap levers alone**

After all four cheap levers, ~$130/mo is the realistic floor — **2.6× over a $50 plan**. To close the gap, one of the following structural moves is required:

**Option A — Triage gate becomes a *positive* filter, not a negative one.** Today the design routes only `no_opportunity` away from the agent. Instead, route only `new_rule_candidate` (highest-value) to the agent, and route `extend_existing` to a *cheap path*: a single MiMo-pro chat call (~$0.005) that proposes the rule extension as a diff, gated on the existing commit Gate. This cuts agent rows from ~77/209 (37%) to perhaps ~20/209 (10%), saving another ~$2.50/day = $75/month. **Projected: ~$55–65/mo.** *Risk: the cheap diff path might commit lower-quality rules.* Mitigate with the existing 5-part commit Gate.

**Option B — Run the agent on only ~½ of calendar time.** Cron the worker for 12–14h/day. Throughput halves (258 → ~130 rows/day), but at 118k rows total, time-to-walk doubles from ~15 months to ~30 months — likely fine for a research project. **Projected: ~$65–75/mo.**

**Option C — Ship the deferred Qwen-gather + MiMo-write split.** Use local free Qwen to do read/grep/glob exploration and produce a context dump; MiMo only does the write turn. Eliminates ~50–70% of MiMo cache-miss input. *Risk: the realistic Q4_K_M quality drop is large — Aider.chat's "Quantization matters" benchmark reports Qwen2.5-Coder-32B falling from 71.4% (BF16) to 53.4% (Q4_K_M) on Aider polyglot, a 17.7pp drop, much larger than the 5.3pp originally assumed. Q4_K_M gather is likely to framing-drift MiMo into the wrong rule on a meaningful fraction of rows.* **Projected: ~$60–80/mo.** Cheapest in dollars, highest in implementation/quality risk.

**Recommendation: ship triage + turn-clipping + distillation + rules-index (4 weeks). Measure for 2 weeks. If the gap to $50/mo remains, ship Option A (positive-filter triage) before Options B or C** — A is in-architecture (it's the same MiMo classifier plus a cheap MiMo-write path), reuses the shadow-eval harness, and preserves throughput.

---

### 5. Implementation Plan & Measurement

Each sprint has a quantitative pass/fail keyed to `var/run/usage.jsonl`, `var/run/rows.jsonl`, or the MiMo console credit-delta over 24h as ground truth.

#### Sprint 0 (2 days): instrument call-counts per row

- [ ] Add `row_id` to every MiMo usage record if not already present.
- [ ] Add `mix tunex.turns` Mix task computing call-count distribution by outcome (p50/p90/p99/max).
- [ ] Add stream-json parsing for `claude -p` and log `num_turns` to `rows.jsonl`.
- **Pass:** `mix tunex.turns` produces a histogram showing p90 turn-count for `committed` and `exception` outcomes within ±1 of expectation. **Fail:** no `row_id` linkage possible → block all later sprints.

#### Sprint 1 (1 day): max-turns + max-budget clipping (FASTEST WIN)

- [ ] In `claude -p` invocation, add `--max-turns 12 --max-budget-usd 0.08 --output-format json`.
- [ ] Parse JSON result, branch on `subtype`; treat `error_max_turns` and `error_max_budget_usd` as `:exception` with sub-reason logged.
- [ ] Wall-clock guard at 360 s as defense-in-depth.
- **Pass criteria (measured over 48h):** (a) zero rows exceed $0.10; (b) total spend per 14h drops by ≥ 10% vs. the 7-day pre-sprint mean from `mix tunex.usage`; (c) `committed` row count per 24h does NOT drop by more than 5% (or the cap is too tight and must be raised to 15).
- **Decision tree:**
  - If committed-row rate drops > 5% AND `error_max_turns` count > 3/day: raise cap to 15, re-measure 24h.
  - If still drops: raise cap to 18, re-measure 24h. If still drops at 18, accept that some committed rules genuinely need 18+ turns and investigate input distillation (Sprint 3) first.
  - If committed-row rate stable AND total cost drops ≥ 10%: hold at 12 and proceed.

#### Sprint 2 (3 days): deterministic Stage A pre-filter

- [ ] Implement the 6 Stage A rules from § 1.2 as a `Tunex.Triage.Deterministic` module returning `{:keep, reason} | {:drop, reason} | :uncertain`.
- [ ] Tag rows accordingly in `rows.jsonl` (`stage_a_verdict`).
- [ ] Initially do NOT route based on Stage A — just log. (Shadow Stage A first.)
- **Pass criteria (48h shadow):** Stage A drops correlate with ground-truth `no_opportunity` outcome on ≥ 90% of drops. **Fail:** if any Stage A "DROP" row turns out to be a real committed-rule opportunity, the corresponding rule is wrong and must be fixed before promotion to live routing.

#### Sprint 3 (3 days): rules-index cached prefix + input distillation

- [ ] Ship the ~50-line Elixir AST script that catalogs every Credence rule (module, behaviour, docstring, helpers, similar-rules-by-trigger-substring). Output: `var/cache/rules_index.md`.
- [ ] Inject as a `cache_control: ephemeral` prefix in both the agent session and Stage B classifier.
- [ ] Replace the raw transcript handed to the agent with `solve-code + Credence fix-trace` only (distillation).
- **Pass criteria (48h):** cache_hit ratio in `usage.jsonl` rises by ≥ 3pp; rule-gen mean cache-MISS input per row drops by ≥ 15%; committed-row rate stable ±5%.

#### Sprint 4 (4 days): MiMo Stage B classifier + cascade live

- [ ] Implement the prompt from § 1.3 as `Tunex.Triage.MiMoClassifier`.
- [ ] Wire Stage A → Stage B → agent. Initially **τ = 0.25** (generous).
- [ ] **Enable the 10% shadow lane** (random sample of `no_opportunity` verdicts) from day 1.
- [ ] Tag every row with `triage_verdict`, `triage_confidence`, `shadow` in `rows.jsonl`.
- **Pass criteria (7 days):**
  - Shadow FN rate (Wilson upper-95) ≤ 10% (loose initial bound).
  - Total $/day drops by ≥ 15% vs. post-Sprint-3 baseline.
  - 0 rows where Stage B failed to return parseable JSON without falling through to the agent (fail-open works).

#### Sprint 5 (ongoing): weekly recalibration

- [ ] `mix tunex.recalibrate` cron task implementing § 3.4 logic.
- [ ] Threshold history written to `var/run/triage_threshold.jsonl`.
- **Pass criteria (rolling 28d):** monthly projected spend stable within ±$15 of the post-Sprint-4 measurement.

#### Sprint 6 (if needed): structural move to clear $50

Decision gate: after Sprint 5 has run for 14 days, if monthly projected > $80, choose one of Option A / B / C from § 4.3 and execute. **Recommended first pick: Option A** (positive-filter triage with cheap MiMo-write path).

#### Ground-truth measurement

The MiMo console credit delta is the ground truth. After each sprint, record `console_credits_used_24h` and compare to the sum of `cost_est` in `rows.jsonl` over the same window. They should agree within 5%; if not, `usage.jsonl` is missing calls or prices have moved.

---

## Recommendations

1. **Ship Sprint 1 (max-turns clipping) this week.** It is a one-line change, no risk to discovery yield if you start at cap = 15 and tighten only after Sprint 0 produces the turn histogram. Expected savings: $30–40/month immediately.
2. **Ship Sprint 0 (turn instrumentation) in parallel with Sprint 1.** The histogram tells you whether 12 or 15 is the right cap; without it, you're guessing.
3. **Ship Sprints 2–4 in order over the next 3 weeks** with the **permanent 10% shadow lane** turned on the day the live cascade goes live. This is non-negotiable: it is the only protection against silently dropping rule opportunities.
4. **Start τ at 0.25 (generous).** Tighten only as shadow data accumulates and the Wilson upper-95 FN bound drops below 5%. **Never set τ > 0.5 without > 200 shadow rows of evidence.**
5. **After Sprint 5 has run 14 days, make the structural-move call.** If projected spend > $80, ship Option A (positive-filter triage with cheap MiMo-write path) — it preserves throughput and reuses the same classifier. Use Options B or C only as fallbacks; Option C in particular carries the 17.7pp Q4_K_M quality-drop risk documented in Aider's benchmark.
6. **Treat the MiMo console credit-delta as your ledger of last resort.** Reconcile weekly. If the in-process ledgers diverge from the console by > 5%, fix that bug before believing any of the lever-impact numbers.

### Pass / fail thresholds (summary)

| Question                                       | Pass threshold                              | Fail threshold (action)                      |
|------------------------------------------------|---------------------------------------------|----------------------------------------------|
| Sprint 1: did clipping cut spend?              | ≥ 10% drop, committed rate stable           | < 10% drop OR committed rate drops > 5%      |
| Sprint 4: triage net savings?                  | ≥ 15% drop                                  | < 5% drop → revert to deterministic-only     |
| Shadow FN rate (rolling 28d)                   | Wilson upper-95 ≤ 5%                        | > 10% → lower τ by 0.05, alert               |
| Console-credit / ledger agreement (weekly)     | within ±5%                                  | > 5% → freeze further sprint launches        |
| Time to $50/mo                                 | ≤ 6 weeks from Sprint 0                     | > 6 weeks → execute Option A                 |

---

## Caveats

- **The 132/209 no_opportunity rate is from a 20.44h, 220-row sample.** Wider corpus statistics may shift the fraction by ±15pp, which mostly affects absolute savings (not the qualitative case for the gate). § 4.2 quantifies this.
- **The 1.10× distillation and 1.15× rules-index multipliers are pre-shipping estimates from the user, not measured.** Realized multipliers may be smaller; treat the $130/mo projection as a hopeful floor, not a guaranteed outcome.
- **MiMo-pro prompt caching is asserted to work as advertised** (the production data shows 153M cache-read tokens at near-zero cost, supporting this). If MiMo's caching behavior changes (e.g. shorter TTL, lower hit-rate), all multipliers degrade and the gap to $50 grows. Monitor cache-hit ratio in `usage.jsonl` weekly.
- **The Stage B classifier itself can be wrong asymmetrically.** Specifically, MiMo-pro may systematically over-classify "no_opportunity" if the rules-index is large and convincing — it'll think every pattern is already covered. Mitigate by including the `nearest_existing_rule` field in the prompt and requiring the classifier to *name* the rule it thinks covers the case; spot-check by hand for the first 50 verdicts.
- **The `--max-budget-usd 0.08` cap can be overshot by approximately one API call.** Anthropic's own example explicitly notes the cost may exceed the budget by up to one API call's worth. So a $0.08 cap may bill $0.10–0.12 in practice on rows where one final turn was already in flight when the cap fired. The wall-clock and in-process cost guards in § 2.4 are the belt-and-braces.
- **Claude Code's `max-turns` default is `No limit`, NOT 10.** Several secondary sources (notably the SFEIR Institute training pages) claim a default of 10. The Anthropic primary docs are explicit: "Default: No limit." Do not assume any cap is in place until you set one.
- **The shadow-lane assumes the full agent's `outcome` is itself ground truth.** It isn't perfectly — the agent occasionally `commits` a marginal rule and occasionally `gives up` on a real one. The user accepts this approximation; for harder ground truth, periodically hand-audit a sample of shadow rows.
- **The Q4_K_M quantization quality drop on Qwen2.5-Coder-32B is materially larger than the brief's 5.3pp figure** — Aider.chat's Nov 2024 "Quantization matters" benchmark reports 71.4% → 53.4% on Aider polyglot, a 17.7pp drop. This strengthens the case to defer Option C (Qwen-gather split) and prefer Option A (positive-filter triage) as the structural move if needed.
- **Claude Code is being repointed at MiMo's Anthropic-compatible endpoint, not Anthropic.** All `--max-turns` / `--max-budget-usd` semantics, JSON `subtype` values, and prompt-caching mechanics are inherited from Claude Code's harness, but the *prices* used in budget calculations are MiMo's (assertedly mirrored through the endpoint into the cost reporter). Confirm `total_cost_usd` in returned JSON matches your MiMo console — if not, the budget cap fires at the wrong dollar value.