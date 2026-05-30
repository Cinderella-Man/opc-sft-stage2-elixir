import Config

config :tunex,
  secret_providers: %{
    xiaomi: %{
      headers: %{
        Authorization: "Bearer tp-xxxxxxxxxxxxxxxxxx"
      }
    }
  }
