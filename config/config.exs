import Config

config :tunex,
  llm_url: "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
  llm_model: "mimo-v2.5-pro",
  max_retries: 5,
  max_refine_retries: 5,
  dataset_base:
    "https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2/resolve/refs%2Fconvert%2Fparquet"

config :logger,
  level: :debug

import_config "secrets.exs"
