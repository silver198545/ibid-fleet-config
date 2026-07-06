# 監視・アラート(rancher-monitoring)の運用手順

各環境に rancher-monitoring(Prometheus + Alertmanager + Grafana)をFleetバンドルとして
導入し、アラートをSlackに通知する。ここではGitOpsで自動化できない手動手順と、
運用上の注意点をまとめる。

## 構成(バンドルと依存関係)

`envs/<env>/infra/` 配下の5バンドル:

| バンドル | 内容 | 依存 |
|---|---|---|
| `monitoring-crd` | rancher-monitoring-crd(ServiceMonitor等のCRD) | なし |
| `monitoring-secrets` | Slack Webhook URLのSealedSecret | なし(意図的。下記注意参照) |
| `monitoring-blackbox` | blackbox-exporter(HTTP死活監視の実行体) | なし |
| `monitoring` | rancher-monitoring本体(Prometheus/Alertmanager/Grafana) | monitoring-crd |
| `monitoring-config` | ServiceMonitor(Longhorn)+ PrometheusRule(独自アラート) | monitoring-crd |

- `monitoring-secrets` に `dependsOn` を付けてはならない。Alertmanager Podは
  Webhook Secretをマウントするため、Secretがmonitoring本体より後になると
  相互待ちのデッドロックになる。
- チャートversionは全バンドルでLonghornと同じRancherマイナー系列
  (現在は109.x = Rancher 2.14)に合わせる。

## 初期導入(環境ごと)

1. **Slack側**: 通知先チャンネルにIncoming Webhookを作成し、URLを控える
   (Slackアプリ > Incoming Webhooks。チャンネルはWebhook作成時に固定される)。
2. **封印**: `scripts/seal-monitoring-secret.sh <env>` を実行。
   URLは `SLACK_WEBHOOK_URL` 環境変数か非表示プロンプトで渡す(コマンド引数は不可)。
   `envs/<env>/infra/monitoring-secrets/alertmanager-slack-webhook.yaml` が生成される。
   封印は環境ごとの鍵で行われるため**他環境へのファイルコピーは不可**。
3. PRを作成しマージ → Fleetが5バンドルを適用する
   (`monitoring-crd` のCRD適用Jobに数分かかることがある)。

## 運用上の注意(重要)

- **Alertmanager設定はGit管理のみ。** `alertmanager.secret.recreateIfExists: true` を
  設定しているため、Rancher UI(Monitoring > Alerting > Routes and Receivers)での
  編集は次回のHelm適用で**黙って上書きされる**。ルーティングやreceiverの変更は必ず
  `envs/<env>/infra/monitoring/fleet.yaml` の `alertmanager.config` を編集してPRで行う。
- **Rancher UIの Cluster Tools から Monitoring をインストールしないこと。**
  UI側はFleet管理のリリースを認識せず「未インストール」に見えるが、
  クリックすると同名リリースが競合して壊れる。
- `alertmanager.config` 配下のリスト(`inhibit_rules` 等)はチャート既定と
  マージされず**丸ごと置換**される。fleet.yamlに再掲してある既定の4本を
  誤って消さないこと。
- アラートルールの追加は `envs/<env>/infra/monitoring-config/prometheusrule-ibid.yaml`
  に追記する(汎用的なノード・Pod系アラートはkube-prometheus-stack既定ルールが
  既に有効)。

## ダッシュボード・UIへのアクセス

Rancher UI → 対象クラスタ → Monitoring から Grafana / Prometheus / Alertmanager に
プロキシ経由でアクセスできる(LoadBalancer/Ingressは作らない)。
kubectlの場合: `kubectl -n cattle-monitoring-system port-forward svc/rancher-monitoring-prometheus 9090:9090` 等。

## 監視対象とアラート一覧(独自分)

- **WordPress死活**: Prometheusの `additionalScrapeConfigs`(job
  `blackbox-wordpress-http`)が `wordpress-*` namespaceのServiceを動的発見し、
  blackbox-exporter経由でHTTP probeする。**サイト追加時の監視設定変更は不要。**
  - `WordPressSiteDown`(critical): 5分間HTTP応答なし
  - `WordPressSiteSlow`(warning): 応答5秒超が15分継続
  - 制約: probeはクラスタ内(ClusterIP)経由のため、**Harvester LB IP経路の障害や
    IPPool枯渇は検知できない**(Ingress化・DNS導入時に外形監視を再検討。roadmap 1-2)。
- **Longhorn容量**(roadmap 3の容量アラート):
  - `LonghornNodeStorageUsageWarning/Critical`: ノード使用率 75% / 90% 超
- **Longhornバックアップ**:
  - `LonghornBackupError`(critical): `longhorn_backup_state == 4`(Error)。
    enum値はdev1実機で 3=Completed を確認済み(0=New, 1=Pending, 2=InProgress,
    3=Completed, 4=Error, 5=Unknown)。
  - `LonghornDailyBackupStale`(warning): CronJob `backup-daily` の最終成功から26時間超。

## アラートのテスト発報

1. **Webhook経路のみ**(Slack着信の確認):
   ```bash
   kubectl -n cattle-monitoring-system port-forward svc/rancher-monitoring-alertmanager 9093:9093 &
   curl -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d \
     '[{"labels":{"alertname":"SlackTest","severity":"critical","namespace":"test"},"annotations":{"summary":"Slack通知テスト"}}]'
   ```
   数十秒以内にSlackに届けばOK(このアラートは自動でresolveされ、resolve通知も届く)。
2. **パイプライン全体**(ルール評価→通知): `prometheusrule-ibid.yaml` に一時ルール
   `expr: vector(1)` のテストアラートを追加したPRをマージ → Slack着信を確認 → revert。
   もしくはdevで対象サイトのDeploymentを一時停止して `WordPressSiteDown` の実発報を待つ
   (Fleetのドリフト補正で戻ることがあるため方法1を推奨)。

## Webhook URLのローテーション

1. Slack側で新しいWebhookを作成(旧URLの無効化は切替後に)。
2. `scripts/seal-monitoring-secret.sh <env>` を再実行しPR→マージ。
3. テスト発報(上記1.)で疎通確認後、旧Webhookを無効化。

## 環境展開時の差分(dev → staging → production)

promoteワークフローは `sites/` しかコピーしないため、monitoring系バンドルは
手動PRで各環境に展開する。環境間で意図的に異なる箇所:

- `dependsOn` のバンドル名(`ibid-<env>-envs-<env>-infra-monitoring-crd`)
- `prometheus.prometheusSpec.externalLabels.cluster`(dev / staging / production)
- SealedSecret(環境ごとに封印し直す。コピー不可)
- productionはPVC/retention増を検討(例: 30Gi / 15d)

## トラブルシューティング

- **AlertmanagerがPending/起動しない**: Webhook Secretのマウント待ちの可能性。
  `kubectl -n cattle-monitoring-system get sealedsecret,secret alertmanager-slack-webhook`
  で復号状態を確認(SealedSecretがあるのにSecretが無ければ封印環境違いを疑う)。
- **Alertmanager設定が反映されない**: Secret
  `alertmanager-rancher-monitoring-alertmanager` の `alertmanager.yaml` を
  base64デコードしてGitのvaluesと比較する。
- **Longhornメトリクスが無い**: ServiceMonitor `longhorn` と
  `longhorn-backend` Service(port `manager`)のラベル `app: longhorn-manager` を確認。
