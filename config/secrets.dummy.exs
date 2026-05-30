import Config

# Template for config/secrets.exs (the real file is gitignored).
# Copy to config/secrets.exs and fill in real values.
config :tunex,
  # Mimo chat-completions auth (Translate + Solve-remote-override).
  secret_providers: %{
    xiaomi_mimo_2_5_pro: %{
      headers: %{
        Authorization: "Bearer tp-xxxxxxxxxxxxxxxxxx"
      }
    }
  },
  # Claude Code → Mimo Anthropic-compatible endpoint (ANTHROPIC_AUTH_TOKEN).
  claude_code_auth_token: "tp-xxxxxxxxxxxxxxxxxx"
