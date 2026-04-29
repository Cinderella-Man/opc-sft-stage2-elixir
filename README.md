# Elixir SFT Dataset Converter

Convert Python coding exercises into idiomatic Elixir — producing a validated, high-quality supervised fine-tuning (SFT) dataset for training Elixir-aware code LLMs.

## The Problem

Elixir is severely underrepresented in code LLM training data. Models like CodeLlama, Qwen-Coder, and StarCoder can write passable Python but produce awkward, non-idiomatic Elixir — often just transliterating Python line-by-line rather than using pattern matching, pipes, guards, recursion with accumulators, and other core Elixir idioms.

There are no large-scale, publicly available Elixir SFT datasets. Building one from scratch would require thousands of hand-written examples.

## The Approach

We take [OpenCoder-LLM/opc-sft-stage2](https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2), a high-quality Python SFT dataset with ~118k coding exercises, and convert each exercise to Elixir using a local LLM with a multi-stage validation pipeline.

This is not a naive find-and-replace. For each exercise, the LLM rewrites **both** the instruction and the code:

- **Instructions** are rewritten to remove all Python references, replace Python types with Elixir equivalents (dict→map, set→MapSet), and adapt complexity claims for Elixir's data structures (linked lists, immutable data, no in-place mutation).
- **Code** is written as idiomatic Elixir — not a line-by-line transliteration. The LLM is prompted to use pattern matching, the pipe operator, guards, Enum/Stream, and recursion with accumulators.

The approach is based on the [Self-Refine](https://arxiv.org/abs/2303.17651) paper (Madaan et al., 2023), which demonstrates that LLMs can iteratively improve their own output through feedback loops, achieving 5-40% improvement over single-pass generation.

## Pipeline Architecture

Each exercise goes through a 6-step pipeline:

```
┌─────────────────────────────────────────────────────────────┐
│  1. CONVERT                                                 │
│     LLM rewrites instruction + code + tests for Elixir      │
│     Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST---   │
├─────────────────────────────────────────────────────────────┤
│  2. COMPILE         mix compile --warnings-as-errors        │
│  3. FORMAT          mix format --check-formatted            │
│  4. LINT            mix credo --strict                      │
│  5. TEST            mix test                                │
├─────────────────────────────────────────────────────────────┤
│  Any failure → errors fed back to LLM → retry (up to 3x)   │
├─────────────────────────────────────────────────────────────┤
│  6. REFINE (Self-Refine loop)                               │
│     a. REVIEW: LLM reviews working code for edge cases,     │
│        idiom issues, missing tests                          │
│     b. IMPROVE: LLM applies review feedback                 │
│     c. VALIDATE: run steps 2-5 on improved version          │
│     d. If improved version fails → keep original (safe)     │
└─────────────────────────────────────────────────────────────┘
```

### Validation Details

The converter creates a real Mix project (`elixir_sft_workspace/`) with Credo as a dependency. For each exercise:

- **Compile** (`mix compile --warnings-as-errors --force`): Catches syntax errors like `a div b` (should be `div(a, b)`), undefined functions, bad pattern matches, and unused variables.
- **Format** (`mix format --check-formatted`): Ensures code follows standard Elixir formatting. If not formatted, the code is auto-formatted and the formatted version is saved.
- **Credo** (`mix credo --strict`): Catches style issues — non-idiomatic naming, missing parens, unnecessary complexity. ModuleDoc and TagTODO checks are disabled since they don't apply to generated exercises.
- **Test** (`mix test`): Runs the ExUnit tests that mirror the original Python assertions.

### Self-Refine Step

After initial validation passes, a separate review-then-improve cycle runs:

1. **Review call**: The LLM acts as a code reviewer, examining the working code for edge cases (empty input, nil, single element, negative numbers, unicode), idiomatic improvements (better pattern matching, guards, pipe usage), and missing test coverage.
2. **Improve call**: The LLM applies the review feedback, producing an improved module and expanded test suite.
3. **Re-validate**: The improved version goes through the full compile→format→credo→test pipeline. If it fails any check, the original passing version is kept. You never lose working code.

The output records whether refinement was applied, the review feedback text, and test count before/after — so you can measure the impact of the refinement step.

### Error Recovery

- **Thinking model support**: Qwen3 and similar models split output into `reasoning_content` and `content`. If the model burns all tokens on thinking (empty `content`), the converter retries with `/no_think` and a shorter prompt.
- **Parse failures**: If the LLM doesn't follow the delimiter format, the previous output is included in the retry prompt so it can see what went wrong.
- **Auto-resume**: When restarted without an explicit start index, the converter reads the last `index` from both the output and errors JSONL files and resumes from the next row.
- **Errors file**: Every failed row is saved to a separate `_errors.jsonl` with the full original data, failure reason, and timing — ready for a later retry pass.

## Source Dataset

[OpenCoder-LLM/opc-sft-stage2](https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2) has four subsets:

| Subset | Rows | Recommended | Notes |
|---|---|---|---|
| `educational_instruct` | ~118k | **Start here** | Clean algorithmic problems (palindromes, sorting, search, etc.) that translate naturally to Elixir |
| `evol_instruct` | ~111k | Good second pass | More complex, evolved problems |
| `mceval_instruct` | ~36k | Maybe | May already contain some multi-language examples |
| `package_instruct` | ~171k | **Skip** | Heavily Python-package-specific (numpy, pandas, matplotlib) — doesn't translate meaningfully |

## Requirements

- **Elixir** 1.15+ (for Mix, ExUnit, and the formatter)
- **llama.cpp** server running locally on `http://127.0.0.1:8080`
- **A capable model**: Qwen3-27B, Qwen2.5-Coder-32B, or Codestral recommended. Smaller models produce lower-quality Elixir and have higher failure rates.
- **Internet connection** for the first run (downloads the parquet file from HuggingFace)

Elixir dependencies (auto-installed via `Mix.install`):
- `req` — HTTP client for LLM API calls and dataset download
- `explorer` — Parquet file reading
- `jason` — JSON encoding/decoding

## Usage

### Preview (test with 3 examples first)

```bash
# Thinking disabled (fast, recommended for Qwen3)
elixir preview_conversion.exs

# Thinking enabled (slow, uses more tokens)
elixir preview_conversion.exs --think
```

The preview runs 3 hardcoded examples through the full pipeline and shows every step in detail. Use this to check whether your model produces good Elixir before committing to the full run.

### Full Conversion

```bash
# Start from the beginning
elixir convert_to_elixir.exs educational_instruct

# Auto-resumes if output file exists
elixir convert_to_elixir.exs educational_instruct

# Start from a specific index
elixir convert_to_elixir.exs educational_instruct 500

# With thinking enabled
elixir convert_to_elixir.exs educational_instruct 0 --think
```

### Output Files

| File | Contents |
|---|---|
| `elixir_sft_<subset>.jsonl` | Successful conversions — one JSON object per line |
| `elixir_sft_<subset>_errors.jsonl` | Failed rows with original data and failure reason |
| `convert_log_<subset>.txt` | One-line-per-row status log |

### Output Schema (Success)

```json
{
  "index": 42,
  "instruction": "Write an Elixir function to find the missing number...",
  "elixir_code": "defmodule MissingNumber do\n  ...\nend",
  "elixir_test": "defmodule MissingNumberTest do\n  ...\nend",
  "original_instruction": "Write a python function to find the missing number...",
  "python_code": "def missing_number(nums):\n    ...",
  "entry_point": "missing_number",
  "original_entry_point": "missing_number",
  "attempts": 1,
  "formatted_clean": true,
  "refined": true,
  "review_feedback": "1. Missing guard for empty list...",
  "tests_before": 3,
  "tests_after": 6
}
```

### Output Schema (Error)

```json
{
  "index": 11,
  "entry_point": "longest_substring_without_repeating_characters",
  "instruction": "Write a function to find...",
  "code": "def longest_substring...",
  "testcase": ["assert ..."],
  "failure_reason": "thinking exhausted all 4096 tokens",
  "elapsed_s": 201.5
}
```

## Verbose Logging

Every step is logged to stdout with indentation showing the call hierarchy. A typical successful conversion looks like:

```
────────────────────────────────────────────────────────────
[1/118278] Converting: missing_number
────────────────────────────────────────────────────────────
  Building initial prompt from Python: Write a python function to find...
  Prompt built (742 chars). Starting conversion attempts...
  ── Attempt 1/3 ──
  Sending prompt to LLM (742 chars, max_tokens=4096)...
    Tokens: prompt=480 completion=512 finish=stop
  LLM responded in 24.3s (1847 chars)
  Parsing structured output (looking for delimiters)...
  ✓ Parsed: instruction=89 module=342 test=267 chars
  Running validation pipeline...
      Cleaning old lib/*.ex and test/*_test.exs...
      Writing 342 chars → lib/solution.ex
      Writing 267 chars → test/solution_test.exs
      [1/4] Running `mix compile --warnings-as-errors --force`...
        ✓ Compilation passed
      [2/4] Running `mix format --check-formatted`...
        ✓ Already properly formatted
      [3/4] Running `mix credo --strict` on lib/solution.ex...
        ✓ No credo issues
      [4/4] Running `mix test test/solution_test.exs`...
        ✓ All tests passed
      ✓ All 4 checks passed
  ✓ Conversion succeeded on attempt 1

  ═══ Refinement Phase ═══
      [Step 1/3] Asking LLM to review the working code for issues and edge cases...
      Review prompt: 892 chars
        Tokens: prompt=480 completion=340 finish=stop
      Review received in 18.2s (612 chars)
      Reviewer found 8 lines of feedback:
         1. Missing guard for empty list — add pattern match
         2. No test for missing zero
         ... (6 more lines)
      [Step 2/3] Asking LLM to apply review feedback and improve the code...
      Refine prompt: 1456 chars
      Refinement received in 31.5s (1240 chars)
      ✓ Parsed: module=520 test=480 chars
      [Step 3/3] Validating refined code...
          [1/4] Running `mix compile --warnings-as-errors --force`...
            ✓ Compilation passed
          [2/4] Running `mix format --check-formatted`...
            ✓ Already properly formatted
          [3/4] Running `mix credo --strict` on lib/solution.ex...
            ✓ No credo issues
          [4/4] Running `mix test test/solution_test.exs`...
            ✓ All tests passed
      ✓ Refined version passed all checks!
      Tests: 3 original → 6 after refinement
✓ SUCCESS: missing_number | 1 attempt(s) | 74.0s | 520 chars | refined ✨ | tests: 3→6
```

## Model Notes

This was developed and tested with **Qwen3-27B** (Q5_K_M quantization) running on llama.cpp. Key considerations:

- **Qwen3 is a thinking model.** It splits output into `reasoning_content` (chain-of-thought) and `content` (answer). With `max_tokens=2048`, it can burn the entire budget on thinking and produce empty `content`. The converter handles this by prepending `/no_think` to disable chain-of-thought, which is faster and sufficient for this task.
- **Larger models produce better Elixir.** 27B+ parameter models generally know enough Elixir to produce idiomatic code. Smaller models (7B, 13B) tend to produce Python-with-different-syntax.
- **The validation pipeline catches model mistakes.** Common errors include `a div b` instead of `div(a, b)`, missing `do` keywords, calling nonexistent functions like `String.alphanumeric?/1`, and incorrect pattern matching syntax. The retry loop with error feedback fixes most of these.

## Project Structure

```
.
├── convert_to_elixir.exs        # Full converter with validation + refinement
├── preview_conversion.exs       # Preview script (3 examples, full pipeline)
├── README.md
├── elixir_sft_workspace/        # Created on first run (Mix project for validation)
│   ├── mix.exs
│   ├── lib/solution.ex          # Overwritten per exercise
│   ├── test/solution_test.exs   # Overwritten per exercise
│   └── .credo.exs
├── elixir_sft_educational_instruct.jsonl         # Output (created during run)
├── elixir_sft_educational_instruct_errors.jsonl   # Errors (created during run)
└── convert_log_educational_instruct.txt           # Log (created during run)
```

## Dev notes

```
jq -r 'select(.index >= 100 and .index <= 124) | .elixir_code' elixir_sft_educational_instruct.jsonl > dump.txt
```

## License

The source dataset [OpenCoder-LLM/opc-sft-stage2](https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2) is released under the Apache 2.0 license. The conversion scripts in this repository are provided as-is for research and educational use.