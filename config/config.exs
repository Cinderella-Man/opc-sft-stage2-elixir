import Config

config :tunex,
  # ── Dataset ──────────────────────────────────────────────────────────
  subset: "educational_instruct",
  dataset_base:
    "https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2/resolve/refs%2Fconvert%2Fparquet",

  # ── Retry budget (Refine dropped → no max_refine_retries) ───────────
  max_retries: 5,

  # ── Chat providers (Translate + Solve) ──────────────────────────────
  # `token_param` names the request field carrying the output-token cap
  # (Mimo: max_completion_tokens; vLLM/OpenAI-compatible Qwen: max_tokens).
  # The per-stage floor (see `stage_max_tokens`) is injected at call time by
  # LLM.for_stage; a provider-level value here is only a fallback.
  providers: %{
    xiaomi_mimo_2_5_pro: %{
      url: "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
      model: "mimo-v2.5-pro",
      token_param: :max_completion_tokens,
      max_completion_tokens: 32_768,
      stream: false
    },
    local_qwen_non_thinking: %{
      url: "http://localhost:8000/v1/chat/completions",
      model: "Qwen/Qwen3.6-27B",
      temperature: 0.7,
      top_p: 0.8,
      top_k: 20,
      presence_penalty: 1.5,
      token_param: :max_tokens,
      max_tokens: 8_192,
      chat_template_kwargs: %{enable_thinking: false},
      stream: false
    },
    local_qwen_thinking: %{
      url: "http://localhost:8000/v1/chat/completions",
      model: "Qwen/Qwen3.6-27B",
      temperature: 0.7,
      top_p: 0.8,
      top_k: 20,
      presence_penalty: 1.5,
      token_param: :max_tokens,
      max_tokens: 8_192,
      stream: false
    }
  },

  # ── Stage → provider (the rule-gen stage is hardcoded, not here) ────
  # Overridable per-stage via TUNEX_TRANSLATE_PROVIDER / TUNEX_SOLVE_PROVIDER
  # (the GPU-less remote-dev path sets TUNEX_SOLVE_PROVIDER=xiaomi_mimo_2_5_pro).
  stages: %{
    translate: :xiaomi_mimo_2_5_pro,
    solve: :local_qwen_thinking
  },

  # ── Per-stage output-token floors ───────────────────────────────────
  # Translate needs room for instruction + tests + reference (32k floor);
  # Solve emits a single module+tests (8k floor). On Translate truncation the
  # ceiling is raised up to `translate_ceiling` (≤ Mimo's 131k max).
  stage_max_tokens: %{
    translate: 32_768,
    solve: 8_192
  },
  translate_ceiling: 131_072,

  # ── Claude Code (rule-gen) — Mimo via the Anthropic-compatible endpoint
  # auth_token lives in secrets.exs (see claude_code_auth_token).
  claude_code: %{
    base_url: "https://token-plan-sgp.xiaomimimo.com/anthropic",
    model: "mimo-v2.5-pro[1m]",
    max_turns: 30,
    # Wall-clock safety cap for one rule-gen session (slow Mimo + many turns).
    # A hung session is killed → treated as gave_up. Lower max_turns to speed
    # rows up if sessions routinely run long.
    timeout_ms: 1_200_000
  },

  # ── Credence clone (path dep target + push origin) ──────────────────
  credence_clone: "/home/car/projects/credence",

  # ── Storage layout (keep-vs-wipe split, see plan #16) ───────────────
  cache_dir: "var/cache",
  run_dir: "var/run",

  # ── Budget — Mimo is the only paid dependency ───────────────────────
  # Prices are USD per token (Mimo ≤256K tier: $1/M in, $3/M out).
  # runaway_ceiling_usd is a safety abort only (catches loops, not rationing);
  # tune for a CC rule-gen session on every row. PLACEHOLDER — see plan
  # "Unresolved": confirm the real ceiling after first runs.
  budget: %{
    price_in_per_token: 1.0 / 1_000_000,
    price_out_per_token: 3.0 / 1_000_000,
    price_cache_read_per_token: 0.3 / 1_000_000,
    runaway_ceiling_usd: 500.0,
    # 429-streak → fatal; transient (5xx/network) retry/backoff before halt.
    max_consecutive_429: 5,
    transient_retries: 5,
    transient_backoff_ms: 2_000
  }

config :logger,
  level: :debug

if File.exists?("config/secrets.exs") do
  import_config "secrets.exs"
end
