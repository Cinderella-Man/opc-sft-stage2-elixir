import Config

config :tunex,
  active_provider: :local_qwen_thinking,
  max_retries: 5,
  max_refine_retries: 5,
  providers: %{
    xiaomi: %{
      url: "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions",
      model: "mimo-v2.5-pro",
      stream: false
    },
    local_qwen_non_thinking: %{
      url: "http://localhost:8000/v1/chat/completions",
      model: "Qwen/Qwen3.6-27B",
      temperature: 0.7,
      top_p: 0.8,
      top_k: 20,
      presence_penalty: 1.5,
      max_tokens: 8192,
      chat_template_kwargs: %{
        enable_thinking: false
      },
      stream: false
    },
    local_qwen_thinking: %{
      url: "http://localhost:8000/v1/chat/completions",
      model: "Qwen/Qwen3.6-27B",
      temperature: 0.7,
      top_p: 0.8,
      top_k: 20,
      presence_penalty: 1.5,
      max_tokens: 8192,
      stream: false
    }
  },
  dataset_base:
    "https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2/resolve/refs%2Fconvert%2Fparquet"

config :logger,
  level: :debug

if File.exists?("config/secrets.exs") do
  import_config "secrets.exs"
end
