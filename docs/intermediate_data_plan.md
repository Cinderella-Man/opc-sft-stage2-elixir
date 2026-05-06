# Harvesting Intermediate Data from Tunex Convert: Research & Plan

## The Situation

Your `convert.exs` pipeline does Python→Elixir conversion through a multi-stage loop:

1. **Attempt loop** (up to 5 retries): LLM generates code → parse → naming fixup → validate (compile → credence fix → format → credo → credence check → tests). On failure, error feedback is appended and the LLM is called again.
2. **Refine loop** (up to 5 retries): A reviewer LLM critiques the passing code → if issues found, a refiner LLM applies fixes → validate again. On failure, error feedback drives another refinement attempt.

For 10k pairs you estimate 20–50k LLM exchanges. Right now, only the final passing result gets stored. Everything else — the failed attempts, the error messages, the reviewer feedback, the intermediate code that was "almost right" — is thrown away.

The question: **can this intermediate data be turned into useful training signal, or will it pollute your dataset?**

Short answer: **yes, it's valuable — but only with the right structure and filtering.** The research is overwhelmingly in favor of capturing this data, with several recent papers showing concrete gains from exactly this kind of process data. The key insight is that raw intermediate data is indeed noisy and needs to be stored in a structured way that supports multiple downstream uses: SFT on successful correction trajectories, DPO on pass/fail preference pairs, and step-level filtering to remove genuinely bogus steps.

---

## What the Research Says

### 1. Learning from Mistakes Works (LEMA, 2023)

The "Learning from Mistakes Makes LLM Better Reasoner" paper (An et al., 2023) directly tested training on error-correction pairs. They collected incorrect reasoning paths from various LLMs, then used GPT-4 to identify the mistake, explain why it was wrong, and generate a correction. When mixed with standard CoT fine-tuning data, this correction data consistently outperformed training on correct examples alone. The key finding: the model needs to see both the mistake *and* the structured correction, not just the mistake.

**Relevance to your case:** Your retry loop already generates exactly this — a failed attempt, the specific validation errors (compile, credo, credence, test failures), and then a corrected version. This is a naturally-occurring mistake-correction pair.

### 2. Negative Trajectories Improve Out-of-Domain Generalization (2025)

A recent paper ("Learning from Mistakes: Negative Reasoning Samples Enhance Out-of-Domain Generalization") found that incorporating failed trajectories into SFT yielded substantial out-of-domain generalization gains over positive-only training. The explanation: negative trajectories often contain valid intermediate reasoning despite having an incorrect final answer. They found 22 recurring patterns in negative chains that serve a dual role — they moderate loss descent to prevent overfitting during training and boost policy entropy by ~35% during inference.

**Relevance to your case:** Your intermediate attempts that fail validation often have *mostly correct* code with a specific localized error (a naming convention violation, a missing edge case, a credo issue). These aren't random garbage — they're instructive near-misses.

### 3. Step-Level Filtering Beats Trajectory-Level Filtering (WebSTAR, 2025–2026)

The WebSTAR paper found a striking result: even within *successful* trajectories, fewer than half the individual steps were actually correct. Training only on the correct steps (step-level filtering) with a dataset roughly half the size consistently outperformed training on all steps from successful trajectories (trajectory-level filtering). Their conclusion: **removing noisy steps is more beneficial than increasing dataset size for SFT.**

**Relevance to your case:** This is your exact concern. If attempt 1 produces garbage that doesn't even parse, you don't want to train on that exchange. But if attempt 3 produces code that compiles and passes credo but fails one test, that's a high-quality step. You need per-step quality signals to filter.

### 4. CodeFlow / IterPref: Iterative Debugging Creates Preference Pairs (2025)

The IterPref/CodeFlow framework generates preference pairs directly from iterative debugging. A model generates code, runs tests, refines iteratively until all tests pass. The final correct version is treated as "preferred" and earlier failed versions as "dispreferred." They then use a targeted DPO algorithm that penalizes only the error-specific tokens in dispreferred samples while rewarding all tokens in preferred samples. This achieved significant gains on code generation benchmarks.

**Relevance to your case:** Your convert loop is *literally* CodeFlow. You have the iterative refinement, the test execution, the progressive fixing. You're already generating this data — you're just not saving it.

### 5. AgentHER: Failed Trajectories Can Be Relabeled (2026)

AgentHER adapts Hindsight Experience Replay to LLM agent trajectories. The core insight: a trajectory that fails goal A might be a correct demonstration for some alternative goal B. They convert discarded failures into SFT, DPO, and ShareGPT training data through prompt relabeling. Results: +7–12 percentage point improvement over success-only SFT, with 2× data efficiency.

**Relevance to your case:** Some of your failed conversions might actually be valid Elixir code that just doesn't match the exact specification. A conversion that fails because the function name doesn't match `foo?` convention but otherwise has excellent idiomatic code could be relabeled as a demonstration for a different task.

### 6. SFT vs RL on Self-Correction (SCoRe, 2024)

The SCoRe paper found that SFT on self-correction traces has a fundamental limitation: it tends to produce only minor edits and suffers from distribution shift (the model at inference time generates different first attempts than what it trained on). RL approaches (particularly multi-turn GRPO, as in the MURPHY paper) work better for teaching genuine self-correction. However, SFT on correction traces still provides a useful warm-start for RL.

**Relevance to your case:** If your goal is to teach the model to self-correct code, storing the full multi-turn trajectories is essential. But for pure SFT, the *corrected* final output is more important than the correction process itself. The process data shines when used for DPO or as RL initialization.

### 7. Data Quality: The "Less is More" Effect

Multiple papers confirm that for SFT, a smaller high-quality dataset beats a larger noisy one. The "Data Repetition Beats Data Scaling" paper showed that training for 128 epochs on 400 high-quality samples outperformed 1 epoch on 51,200 samples by 12–26 percentage points. Noise in training data at 30% levels can cause ~9% degradation on downstream tasks.

**Relevance to your case:** This means you should NOT blindly dump all intermediate exchanges into your SFT dataset. But with proper filtering and structuring, the intermediate data becomes a separate, complementary dataset that can be used alongside your clean final outputs.

---

## What Data to Store (The Taxonomy)

Based on the research, here's what you should capture at each stage, organized by what it's useful for:

### A. Per-Attempt Records (attempt loop)

For each call to `ConvertLoop.attempt`:

| Field | Description | Use |
|-------|-------------|-----|
| `index` | Dataset row index | Linkage |
| `entry_point` | Python function name | Linkage |
| `attempt_number` | Which attempt (1–5) | Quality signal |
| `prompt` | Full prompt sent to LLM | SFT input reconstruction |
| `system_prompt` | System prompt used | SFT input reconstruction |
| `raw_response` | Full LLM response | SFT candidate / DPO |
| `parse_ok` | Did Parser.parse_full succeed? | Step-level filter |
| `instruction` | Parsed instruction (if any) | Content |
| `module_code` | Parsed module code (if any) | DPO preferred/dispreferred |
| `test_code` | Parsed test code (if any) | DPO preferred/dispreferred |
| `naming_fixup_applied` | Was NamingFixup triggered? | Quality signal |
| `validation_stages` | Map of stage → pass/fail + output | Step-level filter |
| `validation_failures` | List of `{stage, message}` | Error-correction pairs |
| `final_module_code` | Post-validation module (formatted) | DPO candidate |
| `final_test_code` | Post-validation test (formatted) | DPO candidate |
| `outcome` | `:passed` / `:failed` / `:parse_error` / `:empty` / `:error` | Trajectory label |
| `timestamp` | When this attempt happened | Debugging |
| `llm_latency_ms` | How long the LLM call took | Cost analysis |

### B. Per-Refinement Records (refine loop)

For each call in `ConvertLoop.refine` / `do_refine`:

| Field | Description | Use |
|-------|-------------|-----|
| `index` | Dataset row index | Linkage |
| `phase` | `"review"` or `"refine"` | Distinguishes reviewer vs refiner |
| `refinement_attempt` | Which refinement round (1–5) | Quality signal |
| `reviewer_feedback` | Full reviewer response | SFT data for reviewer training |
| `no_issues_found` | Did reviewer approve? | Quality signal |
| `prompt` | Refinement prompt sent | SFT input |
| `raw_response` | LLM refinement response | SFT candidate |
| `parse_ok` | Parse success | Step-level filter |
| `module_code_before` | Code going into refinement | DPO dispreferred |
| `module_code_after` | Code coming out | DPO preferred (if passes) |
| `test_code_before` | Tests going in | DPO dispreferred |
| `test_code_after` | Tests coming out | DPO preferred (if passes) |
| `validation_failures` | What failed | Error signal |
| `outcome` | `:passed` / `:failed` / `:parse_error` | Label |

### C. Trajectory Summary (per task)

One record per dataset row that ties everything together:

| Field | Description | Use |
|-------|-------------|-----|
| `index` | Dataset row index | Primary key |
| `entry_point` | Function name | Identification |
| `total_attempts` | How many attempt-loop iterations | Difficulty signal |
| `total_refinements` | How many refine iterations | Difficulty signal |
| `total_llm_calls` | Total LLM exchanges | Cost |
| `final_outcome` | `:success` / `:failed` | Label |
| `final_instruction` | Final instruction text | SFT output |
| `final_module` | Final module code | SFT output |
| `final_test` | Final test code | SFT output |
| `attempt_outcomes` | List of per-attempt outcomes | Trajectory analysis |
| `failure_stages_hit` | Set of all validation stages that failed | Pattern analysis |

---

## How to Use This Data (5 Concrete Downstream Uses)

### Use 1: Multi-Turn SFT (Correction Chains)

Format successful correction chains as multi-turn conversations:

```
System: <your system prompt>
User: Convert this Python exercise to Elixir. [original prompt]
Assistant: [attempt 1 output — failed]
User: Your previous conversion had errors. [error feedback with validation output]
Assistant: [attempt 2 output — passed]
```

**Filter rule:** Only include chains where the final attempt passes. Only include the *last failing attempt* before success (not all failures). This gives you the "mistake → structured feedback → correction" triplet that LEMA showed is effective.

**Expected yield from 10k tasks:** If ~40% need >1 attempt, you get ~4,000 multi-turn correction examples on top of your 10k single-turn examples.

### Use 2: DPO Preference Pairs (CodeFlow Style)

For each task where you have both a failing and passing version:

- **Preferred:** The final passing code (module + test)
- **Dispreferred:** The last failing version that at least parsed successfully

**Filter rules:**
- Dispreferred must have `parse_ok: true` (if it didn't even parse, it's too noisy)
- Dispreferred must have compiled (compile failures are too far from correct to be useful for token-level DPO)
- Preferred and dispreferred should share the same prompt/instruction

**Expected yield:** ~3,000–5,000 preference pairs depending on your failure rate.

### Use 3: Reviewer Training Data

Your review loop generates structured code review data:

- **Input:** Elixir code + tests
- **Output:** Either "NO_ISSUES_FOUND" or specific, actionable feedback

This is directly usable for training a specialized code reviewer. Store every reviewer exchange regardless of what happens in refinement.

**Expected yield:** ~10,000 review examples (one per task).

### Use 4: Validation-Aware SFT (Staged Quality Labels)

Store which validation stages each attempt passed/failed. This lets you create graduated quality tiers:

- **Tier 1 (Gold):** Passes all 6 stages on first attempt → highest quality SFT
- **Tier 2 (Silver):** Passes all stages after refinement → good SFT
- **Tier 3 (Bronze):** Passes compile + tests but has credo/credence issues → acceptable with caveats
- **Tier 4 (Instructive failures):** Compiles but fails tests → DPO dispreferred only
- **Tier 5 (Noise):** Doesn't compile or parse → discard

Research shows that mixing quality tiers with appropriate weighting outperforms using only the top tier.

### Use 5: Error Pattern Mining

Aggregate `validation_failures` across all attempts to find systematic LLM weaknesses:

- Which credence rules get violated most? → Add to system prompt or few-shot examples
- Which functions need the most retries? → These are the hard cases, weight them higher in training
- Does the LLM keep making the same mistake across attempts? → These patterns are training signal for what NOT to do

---

## The Pollution Concern: When Intermediate Data Hurts

Your instinct is right — there are real risks. Here's when intermediate data hurts and how to mitigate:

### Risk 1: Parse Failures Are Pure Noise
If the LLM returns something that doesn't even have `---INSTRUCTION---` / `---MODULE---` / `---TEST---` markers, there's no usable code to extract. These are formatting failures, not reasoning failures.

**Mitigation:** Filter out any attempt where `parse_ok == false`. Never use these for SFT. Could potentially use them for DPO as extreme negatives, but the signal-to-noise ratio is poor.

### Risk 2: Early Attempts May Teach Bad Patterns
If attempt 1 produces wildly wrong code and you train on "prompt → wrong code → error → right code," the model might learn to produce wrong code first. This is the "pseudo reasoning paths" problem identified in the VLAA-Thinking paper.

**Mitigation:** For pure SFT, only use the final successful output. Use intermediate attempts exclusively for DPO (as dispreferred) or for multi-turn correction training where the error feedback is explicit.

### Risk 3: Bogus Reviewer Feedback
Sometimes the reviewer might give bad advice that leads refinement astray. If you train on this, you're teaching the model to follow bad reviews.

**Mitigation:** Only use reviewer feedback from cases where the subsequent refinement actually succeeded. If the reviewer said "add edge case X" and the refined code passed all tests including that edge case, the review was valid.

### Risk 4: NamingFixup Masks the Real Issue
When `NamingFixup.fix_is_prefix` programmatically renames `is_foo` → `foo?`, the LLM didn't actually learn anything. If you store the post-fixup code as if the LLM generated it, you're creating a mismatch.

**Mitigation:** Store a `naming_fixup_applied` flag. For SFT, use the post-fixup version (it's the correct code). For DPO, the pre-fixup version (with `is_` names) makes an excellent dispreferred example paired with the fixed version.

---

## Implementation Plan

### Phase 1: Add a Trajectory Logger Module

Create a `Tunex.TrajectoryLogger` module that writes to a separate JSONL file (`trajectories_<subset>.jsonl`):

```elixir
defmodule Tunex.TrajectoryLogger do
  @moduledoc """
  Logs intermediate LLM exchanges and validation results
  for downstream training data extraction.
  """

  def open(subset) do
    path = "trajectories_#{subset}.jsonl"
    file = Tunex.JSONL.open_append(path)
    %{file: file, path: path}
  end

  def log_attempt(logger, data) do
    entry = %{
      type: "attempt",
      index: data.index,
      entry_point: data.entry_point,
      attempt_number: data.attempt_number,
      prompt: data.prompt,
      raw_response: data.raw_response,
      parse_ok: data.parse_ok,
      module_code: data.module_code,
      test_code: data.test_code,
      naming_fixup_applied: data.naming_fixup_applied,
      validation_failures: format_failures(data.validation_failures),
      validation_passed: data.validation_failures == [],
      outcome: data.outcome,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      llm_latency_ms: data.llm_latency_ms
    }
    Tunex.JSONL.append_to(logger.file, entry)
  end

  def log_review(logger, data) do
    entry = %{
      type: "review",
      index: data.index,
      entry_point: data.entry_point,
      code_reviewed: data.module_code,
      test_reviewed: data.test_code,
      reviewer_feedback: data.feedback,
      no_issues_found: data.no_issues,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    Tunex.JSONL.append_to(logger.file, entry)
  end

  def log_refinement(logger, data) do
    entry = %{
      type: "refinement",
      index: data.index,
      entry_point: data.entry_point,
      refinement_attempt: data.attempt_number,
      prompt: data.prompt,
      raw_response: data.raw_response,
      parse_ok: data.parse_ok,
      module_before: data.module_before,
      module_after: data.module_after,
      test_before: data.test_before,
      test_after: data.test_after,
      validation_failures: format_failures(data.validation_failures),
      validation_passed: data.validation_failures == [],
      outcome: data.outcome,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    Tunex.JSONL.append_to(logger.file, entry)
  end

  def close(logger), do: File.close(logger.file)

  defp format_failures(nil), do: []
  defp format_failures(failures) do
    Enum.map(failures, fn {stage, msg} ->
      %{stage: to_string(stage), message: msg}
    end)
  end
end
```

### Phase 2: Instrument ConvertLoop

The changes to `convert.exs` are surgical — add logging calls after each LLM response and validation:

**In `ConvertLoop.attempt/6`:** After each `LLM.call` result and each `Validator.run`, call `TrajectoryLogger.log_attempt/2`.

**In `ConvertLoop.refine/5`:** After the reviewer responds, call `TrajectoryLogger.log_review/2`.

**In `do_refine/7`:** After each refinement attempt and validation, call `TrajectoryLogger.log_refinement/2`.

The logger needs to be threaded through as a parameter (or use a named process / ETS table for concurrent access from the async stream).

### Phase 3: Post-Processing Scripts

After the full convert run, process `trajectories_*.jsonl` with extraction scripts:

**`extract_correction_pairs.exs`** — Builds multi-turn SFT examples:
- Groups entries by index
- Finds sequences of [failed_attempt, ..., successful_attempt]
- Takes the last failure + success as a correction pair
- Filters: parse_ok required, at minimum compiled

**`extract_dpo_pairs.exs`** — Builds DPO preference data:
- For each index, pairs the final passing code (preferred) with the best failing version (dispreferred)
- "Best failing" = highest validation stage reached (compiled > parsed > nothing)
- Outputs in the standard DPO format: `{prompt, chosen, rejected}`

**`extract_reviews.exs`** — Builds reviewer SFT data:
- Pairs code input with reviewer output
- Filters: only reviews where subsequent refinement succeeded (validates the review was useful)

**`analyze_failures.exs`** — Generates failure pattern reports:
- Aggregates credence rules, credo issues, test failure patterns
- Identifies high-retry-count tasks
- Outputs statistics for prompt engineering improvements

### Phase 4: Concurrent-Safe Storage

Since you run with `--workers N`, the logger needs to handle concurrent writes. Options:

1. **File-per-worker** (simplest): Each worker writes to `trajectories_<subset>_w<id>.jsonl`, merge later
2. **GenServer serializer**: A single process handles all writes, workers send messages
3. **ETS + periodic flush**: Buffer in ETS, flush to disk periodically

Recommendation: **file-per-worker** is the most robust. Your workspace pool already assigns worker IDs, so this maps naturally. Merge is trivial: `cat trajectories_*_w*.jsonl > trajectories_all.jsonl`.

---

## Expected Data Yield

For 10k source tasks, assuming typical failure distributions:

| Data Type | Estimated Count | Use |
|-----------|----------------|-----|
| Final passing outputs (what you already store) | ~8,000–9,000 | Primary SFT |
| Multi-turn correction examples | ~3,000–4,000 | Multi-turn SFT |
| DPO preference pairs (compiled but failed tests) | ~2,000–3,000 | DPO training |
| DPO preference pairs (credence/credo failures) | ~1,500–2,500 | DPO training |
| Reviewer feedback examples | ~8,000–9,000 | Reviewer SFT |
| Refinement correction pairs | ~2,000–3,000 | Multi-turn SFT |
| Pure noise (parse failures, empty responses) | ~1,000–2,000 | Discard |

Total usable training examples: roughly **3–4× what you currently store**, with the DPO pairs being arguably more valuable per-sample than additional SFT examples.

---

## Recommendation

**Do it.** The research consensus is clear: intermediate process data is valuable when properly structured and filtered. The key principles:

1. **Store everything, filter later.** Disk is cheap. Write all exchanges to a separate trajectories file. Post-process into specific training formats after the run.

2. **Never mix raw intermediate data into your primary SFT dataset.** Keep the clean final outputs separate. The intermediate data feeds into DPO, multi-turn SFT, and reviewer training as distinct datasets.

3. **Step-level quality signals are essential.** Your validation pipeline already gives you rich per-step signals (parse success, compile, credo, credence, tests). Store them all. They're your filtering mechanism.

4. **The "almost right" attempts are the most valuable.** Code that compiles, passes credo, but fails one test is *excellent* DPO dispreferred data. Code that doesn't parse is noise. Your validation stages are a natural quality ladder.

5. **Start simple.** Phase 1 (logger module) and Phase 2 (instrument the loops) take maybe 2–3 hours. Phase 3 (extraction scripts) you can build iteratively as you explore the data. Don't over-engineer upfront.
