# GitHub Copilot instructions

このリポジトリの作業指針(アーキテクチャ・禁止事項・変更の進め方)はリポジトリ直下の
`AGENTS.md` にツール共通でまとめてある。作業前に必ず `AGENTS.md` を読み、それに従うこと。
特に重要な点:

- これはRancher FleetのGitOps設定リポジトリ(dev → production の2環境)。変更は `envs/dev/` または
  `charts/`・`images/` から入れ、productionへは `promote` ワークフローのPRでのみ昇格する。
  `envs/production/**` を直接編集しない。`envs/production/` に触れるPRを自動マージしない。
- パスワード等の秘密情報をfleet.yaml/Gitに書かない(SealedSecret・`existingSecret`・`valuesFrom` を使う)。
- サイト・インフラのバンドルには `keepResources: true` が必須。サイトの値は `wordpress:` 配下にネストする。
- バンドルは環境非依存に保つ(環境差分は `targetCustomizations` / `overlays/production/`)。
- `charts/ibid-wordpress/` の値を変えたら `Chart.yaml` のversionを必ず上げる。
- 手作業が必要な変更は `docs/` に記載し `README.md` からリンクする。

## Git Commit Guidelines
**CRITICAL: All git commit messages MUST be written in Japanese.**
- Use Japanese for commit title, body, and all descriptions
- Format: `種類: 日本語での変更内容の説明`
- Types (種類): `feat` (機能追加), `fix` (修正), `perf` (パフォーマンス), `refactor` (リファクタリング), `docs` (ドキュメント), `style` (スタイル), `test` (テスト), `chore` (雑務)
- Example: `feat: ケージ移動システムに体重測定機能を追加`
- Example: `fix: カメラステータス更新時の競合状態を解決`
