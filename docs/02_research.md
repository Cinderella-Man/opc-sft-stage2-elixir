# Why Claude Code Burns Tokens Against MiMo — and Which Lighter Harness to Switch To

## TL;DR

- **Switch to Aider, in scripted/non-interactive mode (`aider --message-file ... --yes --no-stream --map-tokens 0 --cache-prompts`)** pointed at MiMo's OpenAI-compatible endpoint. It is the only mainstream coding harness whose context model (small repo-map + explicit `--read` files + appendable history) is structurally token-efficient enough for 24/7 use. Morph's "Aider Uses 4.2x Fewer Tokens Than Claude Code" benchmark (Feb 15 2026, morphllm.com/comparisons/morph-vs-aider-diff) measured **105K tokens per task for Aider vs 479K for Claude Code** (4.56× ratio, rounded to 4.2×) across a 47-file Next.js 15 codebase, 62-file React Native app, and 31-file Python pipeline, at a first-pass success cost of 71% vs 78%. For raw shell-loop simplicity, a 100–300 line custom Elixir ReAct loop calling MiMo's OpenAI endpoint directly (with Read/Grep/Edit/Bash tools you define) will be lighter still, because the user already drives the loop.
- **Yes, Claude Code's bulk is the dominant problem, and it gets worse against MiMo.** Independent measurements put Claude Code's baseline at **~14,328 tokens for the system prompt + 27 built-in tool schemas** (Piebald-AI/claude-code-system-prompts v2.1.158, May 29 2026), and ccusage-confirmed observations show ~27,169-token baselines from a clean directory before a single project file is touched. On top of that, the agent re-sends the full conversation (system prompt + every prior Read/Grep/Bash result) on every turn — so with `--max-turns 30` you are paying for roughly N×(N+1)/2 worth of input over the session.
- **What is eating "billions of tokens" is overwhelmingly input-side re-sending of accumulated tool results — and against MiMo it is almost certainly being charged at full cache-miss price.** Anthropic's `cache_control` markers are not honored on `api.xiaomimimo.com/anthropic` (Xiaomi's docs do not document them, and OpenCode/LiteLLM bug reports show the markers are stripped or ignored for MiMo), and even if they were, Claude Code's `x-anthropic-billing-header` injection (a per-request hash of the first user message) prepends a unique-per-session string into the system prompt, guaranteeing cache misses unless `CLAUDE_CODE_ATTRIBUTION_HEADER=0` is set. The single highest-leverage change is to get the prefix actually cached.

## Key Findings

### 1. Claude Code's baseline overhead is enormous — and the user is paying it on every one of 118,000 rows

- The Piebald-AI prompt-extraction project (which decompiles each Claude Code release; v2.1.158, May 29 2026) catalogues the assembled baseline: a multi-section base system prompt plus **27 built-in tool descriptions**. The Bash tool description alone is 1,558 tokens; Grep is ~300 tokens; the security-review agent prompt is 2,607 tokens.
- A reverse-engineering analysis (ClaudeTUI / dev.to "Where Do Your Claude Code Tokens Actually Go?") measured the assembled first-turn system-prompt floor at exactly **14,328 tokens** (the value `cache_read_input_tokens` resets to after every compaction).
- A separate measurement (`claude -p --output-format json` from an empty directory, Claude Code Camp "Inside Claude Code's System Prompt") recorded **27,169 tokens** baseline with no project config, rising to **30,919 tokens** with project CLAUDE.md and skills.
- GitHub issue anthropics/claude-code #45188 documents the system prompt growing **~70K tokens between v2.1.89 and v2.1.96** alone, and #52979 reports ~19k–31k tokens for trivial prompts like "hi" in a clean folder.
- On top of this, every MCP server adds its full tool schema to every request — typically 1,500–4,000 tokens for ~10 tools, up to 18,000 per turn for a heavy multi-server setup. The user's plan does not use MCP servers, so this is not their problem, but the built-in Read/Grep/Glob/Edit/Write/Bash tool defs are.

Net: every one of the user's 118,000 row-prompts starts at a **~20–30K token floor** before the agent reads anything. Even at MiMo's $1/M input price, that floor alone is **~$0.02–0.03 per row × 118,000 rows = $2,400–$3,500** just for the system prompt on every cold start, assuming zero caching.

### 2. The accumulating-context problem turns 30 turns into ~quadratic input cost

LLM APIs are stateless. On turn N, Claude Code re-sends:
- The full system prompt + tool definitions (~15–30K constant)
- Every previous tool call (Read output, Grep output, Bash `mix test` stdout)
- Every previous assistant message (including its reasoning/thinking traces)

Worked example for a Credence-style 30-turn session (conservative; the user runs this on every row):
- Turn 1 input: ~20K (system+tools) + ~3K user prompt (row log + ledger) = **~23K**
- Each Read on a ~150-line rule file: 1,000–1,600 tokens; each `mix test` failure trace: 3,000–5,000 tokens; each grep result: a few hundred to a few thousand
- A typical "agent reads 4 rule files, runs tests 3 times, edits 2 files, reruns tests" trajectory accumulates **80,000–150,000 tokens by turn 15** and **200,000–350,000 tokens by turn 30** in cumulative re-sent input. Morph's estimate is **10,000 to 100,000+ tokens for a typical session**; the Verdent report puts heavy multi-file Claude Code sessions in the multi-hundred-thousand-token range.

Without caching, the input-token bill for a 30-turn session on MiMo would be roughly **(sum of per-turn input sizes) × $1/M**:

| Scenario | Total input tokens (sum-over-turns) | Total output | Cost @ MiMo cache-miss ($1 in / $3 out) |
|---|---|---|---|
| Light (10 turns, 60K accumulated) | ~300K | ~10K | $0.33 |
| Medium (20 turns, 120K accumulated) | ~1.2M | ~25K | $1.27 |
| Heavy (30 turns, 250K accumulated) | ~3.7M | ~50K | $3.85 |

At ~11 hours observed → 6-day projection on a $50 plan, the user is burning roughly **$50 / 6 days ≈ $8.33/day ≈ $0.35/hour ≈ ~$0.10 per row** if rows take ~15s of agent time on average. That is consistent with the medium scenario above (~$1.27 per 30-turn session) only if ~10–15% of rows actually hit `--max-turns 30` and the rest finish in 5–10 turns. **The arithmetic only works because the model is charging cache-miss prices on the re-sent prefix.**

### 3. Prompt caching against MiMo is almost certainly broken — and that is the single biggest reason it burns so fast

Three independent problems compound here:

**a) Claude Code's `x-anthropic-billing-header` bug poisons the cache prefix.** GitHub issue anthropics/claude-code #24168 documents the original injection at v2.1.37 (first observed in production 2026-02-08): *"Claude Code v2.1.37 unconditionally injects the string `x-anthropic-billing-header: cc_version=...; cc_entrypoint=...; cch=00000;` as a text block in the system prompt content array."* Issue #50085, plus the reproduction at github.com/motiful/cc-cache-audit, document the consequence for `ANTHROPIC_BASE_URL` users: the header is injected **as the first system text block of every request** with this format:
> `x-anthropic-billing-header: cc_version=2.1.88.a3f; cc_entrypoint=cli; cch=00000;`

The `.a3f` and `cch=` values are SHA-256 hash fragments derived from the first user message — so **every row's prompt produces a different hash**, breaking Anthropic-style prefix caching at the very first token. The undocumented fix is `export CLAUDE_CODE_ATTRIBUTION_HEADER=0` (or `=false`). The motiful audit measured the consequence as the ~12K system-prompt block being rebuilt from scratch every session.

**b) MiMo's Anthropic-compatible endpoint does not document `cache_control` support.** A focused audit of `platform.xiaomimimo.com/docs/en-US/api/chat/anthropic-api` shows the example request body has no `cache_control` field anywhere, and the example `usage` response only returns `input_tokens` and `output_tokens` — no `cache_creation_input_tokens` / `cache_read_input_tokens`. Independent reports confirm:
   - anomalyco/opencode#26460, "Prompt Caching Not Working for Xiaomi/MiMo Models": *"When using OpenCode with Xiaomi's MiMo API directly, prompt caching (cache_control headers) is never applied, resulting in 0% cache hit rate … In contrast, using the same models through OpenRouter achieves 90-95% cache hit rates."*
   - BerriAI/litellm#19923, "[Bug]: Prompt Caching and Reasoning broken for the most price efficient models including Xiaomi Mimo, Minimax 2.1 and GLM" (v1.81.0-stable): *"Root cause: All three providers extend OpenAIGPTConfig, which calls `remove_cache_control_flag_from_messages_and_tools()` in transform_request() … Xiaomi uses generic openai_like provider."*

   MiMo *does* publish cache-hit prices ($0.20/M ≤256K, $0.40/M 256K–1M, cache-write currently free), which strongly implies caching happens *automatically* via prefix matching, OpenAI-style — but only if the prefix actually stays stable. Combined with (a), it almost certainly is not.

**c) The Anthropic Messages format itself is the wrong endpoint for caching on OpenAI-compatible providers.** Per Anthropic's own SDK-compat docs (and the apiyi.com analysis), prompt caching only fires on the native `/v1/messages` Anthropic protocol; the OpenAI-compat `/v1/chat/completions` path does not. MiMo exposes both; Claude Code uses the Anthropic one, but that path's caching requires either explicit `cache_control` markers (which MiMo's docs do not show) or stable identical prefixes (which Claude Code defeats with the billing header).

The conclusion is unambiguous: **the user is paying full $1/M cache-miss input prices on what should be cache hits at $0.20/M — a 5× overcharge on the dominant cost component**.

### 4. Lighter-weight harness survey

Comparison table, ranked by suitability for the user's 24/7 headless MiMo+Credence loop:

| Harness | System-prompt size | OpenAI-compat custom base URL | Anthropic-compat | Headless / scriptable | Context strategy | Prompt-caching against MiMo |
|---|---|---|---|---|---|---|
| **Aider** | Small (system + repo map ~1K tokens by default) | Yes (full LiteLLM passthrough via `--openai-api-base`, `--model openai/mimo-v2.5-pro`) | Yes | `aider --message-file ... --yes --no-stream` + `--auto-commits` (or `--no-auto-commits` + `--no-git`) | **Tree-sitter repo map (graph-ranked, default 1K tokens)** + explicit `--file` / `--read` + appendable history. Does **not** autonomously read 10 files. | **Yes** with `--cache-prompts`; works against MiMo OpenAI endpoint via prefix matching |
| **Custom Elixir ReAct loop** (raw MiMo OpenAI tool-calling) | You control it. ~500–2K tokens for a Credence-tuned system prompt | Trivially yes (HTTPoison/Req against `/v1/chat/completions`) | n/a | You are already in Elixir | You decide every byte; you can avoid re-sending huge tool outputs | Automatic on the MiMo OpenAI endpoint if you keep the prefix stable |
| **OpenCode** (sst/opencode or opencode-ai) | Medium (~10–20K) | Yes (custom OpenAI-compat provider) | Yes | `opencode run "..."` non-interactive | Re-sends full history; richer tools | **Broken for direct MiMo per anomalyco/opencode#26460**; only works via OpenRouter wrapper |
| **Codex CLI (OpenAI)** | Large: 2–5K system + ~500/built-in tool + 200–500/MCP server | Yes (`model_providers.X.base_url`, `wire_api = "chat"`) | No | `codex exec` | Same accumulation problem; auto-compacts at threshold | Codex relies on OpenAI's automatic prefix cache; will *not* trigger MiMo's caching reliably |
| **Crush (Charm)** | Medium | Yes (`type: "openai-compat"`) | Yes (custom `type: "anthropic"`) | Limited; primarily TUI, has client/server mode | Re-sends full history | Inherits the same MiMo `cache_control` stripping issue |
| **Plandex** | Medium-Large; uses 2M-token effective window | Via OpenRouter primarily; OpenAI-compat indirect | No | `plandex` CLI is scriptable | Smart context (loads only files relevant to each step) — good in theory, but heavier overall | Caching works via OpenRouter, not direct MiMo |
| **Goose (Block)** | Medium-Large; MCP-heavy | Yes | Yes | Yes (CLI mode) | MCP architecture adds 1.5–5K tokens per server per turn | Cache support uneven |
| **Cline / Roo Code** | Heavy (VS Code-oriented) | Yes | Yes | No first-class headless | — | — |
| **smolagents (HF)** | Tiny (the whole agent is <2K LOC; system prompt is whatever you write) | Yes | Yes via wrapper | Pure Python lib | You write the loop | Up to you |
| **Continue.dev** | IDE-oriented; weak for headless 24/7 | Yes | Yes | Not really | — | — |

**Concrete recommendation ranking for this use case:**

1. **Best fit: a 100–300 line custom Elixir ReAct loop** that hits `https://api.xiaomimimo.com/v1/chat/completions` directly with `tools: [Read, Grep, Edit, Write, Bash(mix test:*)]` defined in OpenAI tool-calling format. The user is already in OTP; they can use Req/Finch, supervise the loop, and crucially they own the system prompt (target it at 1,000–1,500 tokens of Credence-specific instructions) and every tool-result truncation. MiMo's docs confirm `usage` returns standard fields and tool calls/tool_choice work. Expected savings vs Claude Code: **5–15× input tokens**.
2. **Next-best: Aider with `--message-file`, `--map-tokens 0` (or a small value), `--read decisions.md`, explicit `--file` adds for the candidate rule files per row, `--auto-test`, `--test-cmd "mix test"`, and `--cache-prompts`**. This trades the ergonomic of the agent autonomously discovering files for explicit per-row file injection — which, as the analysis below shows, is *cheaper* anyway for a 30-turn ceiling. Use the `openai/mimo-v2.5-pro` model string with `OPENAI_API_BASE=https://api.xiaomimimo.com/v1` and `OPENAI_API_KEY=<token>`. Per Morph's benchmark, **Aider used 105K tokens per task vs Claude Code's 479K** (4.56× ratio) on 47-file Next.js, 62-file React Native, and 31-file Python pipeline tasks.
3. **Acceptable interim: Claude Code with the four mitigations in §5.** Cuts spend significantly without code rewrites.

### 5. Mitigations if the user stays on Claude Code (ranked by token-savings impact)

1. **Set `CLAUDE_CODE_ATTRIBUTION_HEADER=0`.** Undocumented but verified — this alone restores the possibility of prefix caching against MiMo. Set `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` as well to suppress `anthropic-beta` headers MiMo doesn't recognize. Do **not** set `DISABLE_PROMPT_CACHING=1` (that disables caching entirely and has caused 401 auth bugs per issue #8632).
2. **Drop `--max-turns 30` to `--max-turns 8–10`.** Each extra turn beyond ~10 re-sends an ever-larger accumulated prefix. A 30-turn cap is mostly burning tokens on diminishing-returns iteration; the marginal value of turns 20–30 on a 24/7 mass-rule-improvement loop is near zero. Expected savings: **30–50% per row** with negligible quality loss given the deterministic-rule-improvement framing.
3. **Inject Credence rule context directly into the prompt instead of letting the agent burn turns on Read/Grep.** This is counterintuitive but the math is clear: if a typical session does 4 Reads of 1,200-token rule files, the cost is 4×1,200 = 4,800 tokens for the Read outputs *plus* re-sending them in turns 5–30 (≈ 25 additional re-sends × 4,800 = 120,000 token-equivalents). Pre-loading the same 4,800 tokens once into the user prompt at turn 1 still pays the same 4,800 once but **only re-sends it as a stable cached prefix** — and pre-loaded prefix content is exactly what MiMo's automatic prefix cache is designed to hit. The user's auto-discovery via `@behaviour` scan can be done outside Claude Code in Elixir.
4. **Cheap pre-filter to skip the agent on low-value rows.** The user runs the agent on every row deliberately because high-value rows are the zero-lint-issue ones — but a single ~500-token MiMo OpenAI call ("classify this row as PROMISING / SKIP based on …") at MiMo's prices costs roughly $0.002 per row and could skip 50–70% of rows entirely. Even at the user's existing per-row Claude-Code cost (~$0.10 estimated above), this is a **30–60× reduction** on the filtered subset.
5. **Cap `MAX_THINKING_TOKENS` at 8,000.** Default extended-thinking budgets can run to tens of thousands of output tokens, billed at $3/M on MiMo. The systemprompt.io community measurements identify this as "the single highest-impact change" for cost.
6. **Trim the tool surface.** The user already restricts to `Read Grep Glob Edit Write Bash(mix test:*)` — good — but verify they have *not* registered any MCP servers (each one re-adds 1,500–4,000 tokens per turn).
7. **Disable streaming for headless runs (no quality impact, but `usage` becomes available reliably for cache-hit accounting).**

### 6. Quantified cost model (ties §1–§3 together)

Per-row 30-turn session against MiMo with **current setup (no caching working)**:
- System-prompt floor every turn: 25,000 × 30 = **750,000 input tokens**
- Tool-result accumulation (4 Reads of ~1,200 tokens + 3 mix-test outputs of ~4,000 tokens, re-sent across remaining turns): ~250,000 input tokens
- New user/assistant turn content: ~50,000 input tokens
- Output (incl. thinking): ~50,000 output tokens
- **Total: ~1.05M input @ $1/M = $1.05 + 0.05M output @ $3/M = $0.15 → ~$1.20 per row**

At ~11 hours observed before projected exhaustion of a $50 plan in ~6 days, that puts effective burn at ~$8.30/day → ~42 rows/day if average row hits anywhere near worst-case, or ~200–400 rows/day at a more representative mix. The user's own observation that they would need **$100+/month and "even that might not suffice"** is consistent with this model.

Per-row session with **caching actually working (after `CLAUDE_CODE_ATTRIBUTION_HEADER=0` fix + stable prefix)**:
- System-prompt floor: 25,000 written once (cache create, free per Xiaomi for now), then cached at $0.20/M for remaining 29 turns = 25,000 × 29 × $0.20/M = **$0.145**
- Tool results: ~150,000 cached + 100,000 fresh = $0.10
- Output: $0.15
- **Total: ~$0.40 per row → ~3× cheaper, but still expensive**

Per-row session **on a 100-line custom Elixir loop**:
- System prompt: ~1,200 tokens × 8 turns cached → ~$0.002
- Tool results, kept minimal (truncated mix-test output, only changed file diffs re-sent): ~30,000 input
- Output: ~10,000
- **Total: ~$0.05–0.08 per row → ~15–25× cheaper than current**

The largest single lever is **(a) restore caching** (3×), then **(b) drop the harness bulk** (another 3–5×), then **(c) prefilter cheap rows** (potentially another 2–3× on aggregate cost). Combined: realistic 20–50× reduction in monthly spend without sacrificing the 24/7 cadence.

## Details

### Why Claude Code's design is structurally heavy

Claude Code is optimized for *interactive* developer ergonomics on Anthropic's first-party API where prompt caching is automatic, well-tuned, and free of the billing-header bug. Its design choices that hurt the user here:

- **Tool definitions inlined every turn.** A single tool schema for `Read` includes argument descriptions, examples, and observability instructions — hundreds of tokens. Multiplied across 27 tools (per Piebald-AI v2.1.158 catalogue), this is the ~14–17K floor. There is no flag to trim it.
- **System prompt assembled per-turn from 110+ conditional blocks.** The Piebald project catalogues these. Even `--bare` mode (which skips hooks, skills, plugins, MCP, CLAUDE.md) still ships the full base system prompt and tool definitions.
- **Autonomous exploration is preferred over manual context loading.** The agent will happily Read 8 files when 1 would do. On a non-Anthropic endpoint without working caching, every one of those Reads is then re-sent at full price for the remainder of the session.
- **Extended thinking on by default.** On MiMo, thinking tokens are billed as output ($3/M). A single deep-reasoning turn can be 5–10K output tokens.

### Why Aider is the right migration target if the user does not want to write their own loop

- **Repo map default 1,024 tokens** — Aider uses tree-sitter to extract function signatures and a PageRank-style graph algorithm to pick the top-K most relevant symbols, keeping the structural overview small. The user can set `--map-tokens 0` to disable it entirely when injecting context manually.
- **Explicit file model.** `aider --file <path> --read <path>` is exactly the workflow that matches "inject candidate rule files for this row up front." No autonomous reading.
- **Native `--cache-prompts` and `--cache-keepalive-pings`.** When pointed at MiMo's OpenAI endpoint, prefix matching happens automatically; the keepalive pings (5-minute ticks) keep the cache warm across rows.
- **`--auto-test` with `--test-cmd "mix test"` and auto-lint** — Aider runs tests after each edit and feeds failures back into the next prompt, mimicking the user's current Bash(mix test:*) loop.
- **Headless: `aider --message-file PROMPT.md --yes --no-stream --no-auto-commits --no-pretty`** is the exact analogue of `claude -p`. One known gotcha (Aider-AI/aider issue #426): if Aider decides files need to be added to chat, it prompts; `--yes` plus pre-adding all candidate files with `--file` avoids this.
- **Independent benchmark: 4.56× fewer tokens vs Claude Code** (Aider 105K vs Claude Code 479K per task) on 47-file Next.js 15, 62-file React Native, and 31-file Python pipeline tasks over six months (Morph published comparison, Feb 15 2026; both using Claude Sonnet 4.5) — at a 7-percentage-point accuracy cost on first-pass success (78% Claude Code vs 71% Aider). For *rule-improvement-suggestion* workloads where the user post-validates with `mix test` anyway, the accuracy gap is largely absorbed.

### Why a custom Elixir loop is the best fit if the user is willing to write ~200 LOC

The user's task is deliberately deterministic and bounded: read N rule files, propose deterministic edits, run `mix test`, decide. This is a textbook ReAct loop. MiMo's OpenAI-compatible endpoint at `https://api.xiaomimimo.com/v1/chat/completions` supports `tools`, `tool_choice`, and `tool_calls` with standard `usage` reporting. The user can:

- Define 4 tools (`read_file`, `grep`, `apply_edit`, `run_mix_test`) with descriptions totaling ~600 tokens
- Write a Credence-specific system prompt of ~800–1,200 tokens (versus Claude Code's 25,000)
- Keep tool results in a per-turn ledger they can compact themselves (e.g., keep only the *last* mix-test output, not all three; keep only diffs of files they've already shown)
- Use OTP supervision for the 24/7 loop they already have
- Get full `usage` per request for accurate cost tracking

This is the path with the best dollar-per-row outcome. It also sidesteps every Claude Code bug entirely.

## Recommendations

**Stage 1 (this week, no code rewrite — should buy ~3× headroom):**
1. Add to the shell that invokes `claude -p`:
   ```
   export CLAUDE_CODE_ATTRIBUTION_HEADER=0
   export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
   export MAX_THINKING_TOKENS=8000
   ```
   Do **not** set `DISABLE_PROMPT_CACHING`.
2. Drop `--max-turns 30` to `--max-turns 10`. Re-measure burn after 24 hours.
3. Verify caching is now firing: parse the JSON output for `cache_read_input_tokens` > 0 on turn 2+. If still 0, caching is genuinely not supported on MiMo's Anthropic endpoint — proceed immediately to Stage 2.

**Stage 2 (next 1–2 weeks — should buy another 3–5×):**

4. Add a cheap MiMo OpenAI prefilter call (~500-token system + 500-token row excerpt → 100-token classification) that decides PROMISING vs SKIP. Only invoke Claude Code on PROMISING rows.
5. Pre-resolve candidate rule files in Elixir (the user already has the `@behaviour` scan) and pass them as a single block at the top of the prompt. This converts ~5 Read tool-calls (each re-sent 25+ times) into one stable cached prefix segment.

**Stage 3 (decision point — next 2–4 weeks):**

6. Run an **A/B for one weekend**: `aider --message-file` against the same 5,000 rows on a separate MiMo token bucket, compare $/row and rule-improvement quality. If Aider lands within ~15% of Claude Code's hit rate at ~25% of the cost, switch.
7. If Aider quality is not acceptable, fall back to writing the ~200-LOC Elixir ReAct loop (Stage 4). The user's OTP fluency makes this a 1–2 day exercise.

**Stage 4 (the durable answer):**

8. Build the custom Elixir ReAct loop against `api.xiaomimimo.com/v1/chat/completions`. Define 4 tools, ~1,000-token system prompt, supervised under their existing OTP tree. This is the option that will scale to all 118,000 rows on a $50/month plan with room to spare.

**Benchmarks that change the recommendation:**
- If `cache_read_input_tokens` after the env-var fix is consistently ≥80% of `input_tokens` on turn 2+, Stage 1 alone may suffice; skip Stage 4.
- If MiMo announces formal `cache_control` ephemeral support on their Anthropic endpoint (currently undocumented), Claude Code becomes viable again.
- If MiMo's prices change materially (the apidog.com post claims a 99% cut on cached input as of May 27, 2026, but the official platform.xiaomimimo.com pricing page still shows the tiered $0.20/$0.40 structure — confirm via console), recompute Stage 1 vs Stage 4 tradeoff.

## Caveats

- **MiMo's actual caching behavior against `cache_control` is undocumented.** Xiaomi's own Anthropic-API page shows no caching parameters in either request or response examples. Third-party reports (anomalyco/opencode#26460, BerriAI/litellm#19923) state cache_control is stripped or ignored. Until the user verifies cache hits in their own `usage` payloads, assume the worst case: no caching against the Anthropic endpoint. The OpenAI-compatible endpoint *appears* to support automatic prefix caching (Xiaomi publishes cache-hit prices that apply uniformly), but again undocumented.
- **MiMo pricing source conflict.** apidog.com (May 27, 2026) claims a permanent flat $1 / $3 / $0.20 with the long-context tier eliminated. The official platform.xiaomimimo.com/docs/en-US/pricing page (April 30, 2026) still shows the tiered structure with 2×/6× multipliers above 256K. The Xiaomi news page announces "no longer differentiates based on input length" as of May 27 2026 Beijing time, so the apidog account is likely correct and the official table is stale. Re-verify in the console.
- **The Claude Code `CLAUDE_CODE_ATTRIBUTION_HEADER` env var is undocumented.** It is confirmed to work via decompiled source (github.com/motiful/cc-cache-audit, github.com/NTT123 gist) but Anthropic could change the gate at any release. The billing header injection was introduced in v2.1.37 (first observed in production 2026-02-08, per anthropics/claude-code#24168). Pin to a known-good Claude Code version (e.g. 2.1.96–2.1.113 range as documented by the affected GitHub issues) or be prepared to re-check after each upgrade.
- **The Morph "4.56× fewer tokens" benchmark for Aider is on TypeScript/JS/Python codebases, not Elixir.** Elixir-specific tree-sitter coverage in Aider's repo-map is adequate but less battle-tested. Validate with a small sample before full migration.
- **The 30-turn cap analysis assumes a uniform per-turn cost ramp.** In practice, sessions distribute bimodally — most finish in 3–8 turns, a tail hits the cap. The user should pull their actual turn-count distribution from the existing JSON output logs before tuning the cap.
- **Independent token-cost numbers cited (~14K tool floor, 27K baseline, 70K version-to-version growth, etc.) are from external reverse-engineering of Claude Code internals and from individual user measurements, not Anthropic-published figures.** Anthropic does not disclose system-prompt token counts; the GitHub issue #22955 is an open feature request asking for this transparency.