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
    # Non-pro V2.5 (310B MoE, 15B active) — the SOLVE model. Weaker than the pro,
    # so its less-idiomatic output is the rule-discovery feedstock; translate +
    # rule-gen stay on the stronger pro. (Replaces the deprecated mimo-v2-pro,
    # which auto-routes to V2.5 on 2026-06-01 and is removed by 2026-06-30.)
    xiaomi_mimo_2_5: %{
      url: "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
      model: "mimo-v2.5",
      token_param: :max_completion_tokens,
      max_completion_tokens: 16_384,
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
  # (e.g. set solve to :local_qwen_thinking once a GPU is available).
  stages: %{
    translate: :xiaomi_mimo_2_5_pro,
    # Solve runs LOCAL Qwen on the 3090 — free, and its weaker/less-idiomatic
    # output is the rule-discovery feedstock (the original design). The remote
    # :xiaomi_mimo_2_5 path is the GPU-less dev fallback (TUNEX_SOLVE_PROVIDER).
    solve: :local_qwen_thinking
  },

  # ── Per-stage output-token floors ───────────────────────────────────
  # Translate needs room for instruction + tests + reference (32k floor). Solve
  # emits one module+tests, but V2.5 is a REASONING model (reasoning tokens count
  # against the cap), so 16k avoids truncation re-rolls on harder problems. On
  # Translate truncation the ceiling is raised up to `translate_ceiling`.
  stage_max_tokens: %{
    translate: 32_768,
    solve: 16_384
  },
  translate_ceiling: 131_072,

  # ── Claude Code (rule-gen) — Mimo via the Anthropic-compatible endpoint
  # auth_token lives in secrets.exs (see claude_code_auth_token).
  claude_code: %{
    base_url: "https://token-plan-sgp.xiaomimimo.com/anthropic",
    model: "mimo-v2.5-pro[1m]",
    # Generous — this runs 24/7 and an hour/rule is still superhuman. These are
    # backstops, not budgets: a thorough rule-write session (read files → write
    # rule + test → iterate `mix test`) needs turns, and Mimo is slow. The
    # runaway-$ ceiling still guards true runaways. `max_turns` is Claude Code's
    # own turn count (NOT the per-message "step N" in logs).
    max_turns: 80,
    # Wall-clock safety cap for one rule-gen session; a hung session is killed →
    # treated as gave_up.
    timeout_ms: 3_600_000
  },

  # ── Credence clone (path dep target + push origin) ──────────────────
  credence_clone: "/home/car/projects/credence",

  # Commit identity the app sets on the clone (Preflight). MUST use a GitHub
  # *noreply* email — a real email triggers GH007 "push would publish a private
  # email address" when the account has email-privacy protection, which silently
  # fails the (non-fatal) push and strands commits locally. Find yours at
  # GitHub → Settings → Emails (format: <id>+<login>@users.noreply.github.com).
  git_identity: %{
    name: "Kamil Skowron",
    email: "1019893+Cinderella-Man@users.noreply.github.com"
  },

  # ── Storage layout (keep-vs-wipe split, see plan #16) ───────────────
  cache_dir: "var/cache",
  run_dir: "var/run",

  # ── Budget — Mimo is the only paid dependency ───────────────────────
  # Prices are USD per token (Mimo ≤256K tier: $1/M in, $3/M out).
  # runaway_ceiling_usd is a safety abort only (catches loops, not rationing);
  # tune for a CC rule-gen session on every row. PLACEHOLDER — see plan
  # "Unresolved": confirm the real ceiling after first runs.
  budget: %{
    # ── Per-provider token prices (USD per token) ───────────────────────
    # CORRECTED to the real May-27-2026 token-plan pay-as-you-go rates. The
    # OLD flat 1/0.3/3 was ~83x too high on cache_read and wrong on in/out;
    # it inflated spend tracking and mis-sized the runaway ceiling.
    #   mimo-v2.5-pro : in $0.435/M  cache_read $0.0036/M  out $0.87/M
    #   mimo-v2.5     : in $1.00/M   cache_read $0.20/M     out $3.00/M
    #   :cc (rule-gen) = mimo-v2.5-pro[1m] → pro prices
    # NOTE: these are pay-as-you-go USD. The actual $50/mo plan meters
    # discounted "Credits", so derived $ is a RELATIVE estimate — the raw
    # token COUNTS logged to var/run/usage.jsonl are the ground truth.
    prices: %{
      xiaomi_mimo_2_5_pro: %{in: 0.435 / 1_000_000, cache_read: 0.0036 / 1_000_000, out: 0.87 / 1_000_000},
      xiaomi_mimo_2_5: %{in: 1.0 / 1_000_000, cache_read: 0.20 / 1_000_000, out: 3.0 / 1_000_000},
      cc: %{in: 0.435 / 1_000_000, cache_read: 0.0036 / 1_000_000, out: 0.87 / 1_000_000}
    },
    # Fallback price for an unknown provider (uses pro rates).
    default_price: %{in: 0.435 / 1_000_000, cache_read: 0.0036 / 1_000_000, out: 0.87 / 1_000_000},
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
