```
wizard@wizz:~/projects/opc-sft-stage2-elixir$ jq -r 'select(.index >= 100 and .index <= 124) | .elixir_code' elixir_sft_educational_instruct.jsonl > dump.txt

wizard@wizz:~/projects/opc-sft-stage2-elixir$ jq -r 'select(.index >= 75 and .index <= 99) | .elixir_code' elixir_sft_educational_instruct.jsonl > dump.txt
```