import Config

config :tunex,
  llm_url: "http://127.0.0.1:8020/v1/chat/completions",
  llm_model: "qwen3.6-27b-autoround",
  max_retries: 5,
  max_refine_retries: 5,
  max_tokens: 12_288,
  dataset_base:
    "https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2/resolve/refs%2Fconvert%2Fparquet"
