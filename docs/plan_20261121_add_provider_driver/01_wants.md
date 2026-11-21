# 今回の追加要求

LLM プロバイダの追加
モデルリストの改善

## LLM プロバイダの追加

- OpenAI API
- Google AI Studio API (gemini)
- nous portal 
- OpenAI コンパチビリティ API (Local MML 用、strata とか LlamaCPP とかを想定)

## モデルリストの改善

- デフォルト時 /api/tags 等からリスト取得、起動時に1回取得＆キョッシュ
- .agent_os/models.json で表示するモデルのリストを制御、以下のパラメータを持つ
  - プロバイダごとに使う使わないの enable フラグ、APIKEY 環境変数が設定されていないときは false 扱い
  - 自動リスト取得のフラグ、false 時はこのファイルに書かれているリストのモデルのみ表示されて使える
  - モデルリストのマニュアル記載、OpenRouter とかモデルが多すぎるので使うものだけ書いておく
