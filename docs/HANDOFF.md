# 作業引き継ぎ情報 — GCP FinOps Rebase

## 1. 元の依頼内容

OpenCostベースのリポジトリをGCP FinOpsスタック（dbt FOCUS課金モデル + Metabase on e2-medium VM）にリベースする。
GCP BigQuery FOCUS課金エクスポートからクレジット/EDP/CUD/割引の詳細内訳を保持することが主目的。OpenCostはこの粒度を集計で捨ててしまっていた。

## 2. 作業状況

### 完了したタスク（Tasks 1–9 + レビュー修正）

| タスク | 内容 |
|---|---|
| Task 1 | OpenCostのGoソース、ui-finops、upstream communityファイル、obsolete infraファイルを全削除（904ファイル） |
| Task 2 | `infra/` コアTFファイルをVMベーススタック向けに書き直し（variables, locals, apis, iam, secret_manager, outputs） |
| Task 3 | `infra/compute.tf` 追加（e2-medium VM、静的IP、IAP SSH+HTTPSファイアウォール） |
| Task 4 | `infra/scripts/` 書き直し（deploy.sh: sync/restart/nginx-setup/profiles、vm-startup.sh、env.sh） |
| Task 5 | `dbt/` プロジェクトscaffold + staging model（stg_focus_billing.sql） |
| Task 6 | dbt中間モデル（int_charges.sql、int_credits.sql） |
| Task 7 | dbt martモデル（fct_spend_waterfall、fct_credit_breakdown、fct_commitment_discounts、fct_monthly_showback） |
| Task 8 | Docker Compose（Metabase + PostgreSQL）+ nginx TLS設定 |
| Task 9 | AGENTS.md更新、Metabase BigQuery接続ガイド作成 |
| レビュー修正 | commitment_discount_category欠落修正、profiles.yml VMデプロイ追加、ファイアウォールデフォルト修正（`[]`）、nginx有効化ステップ追加、cloudtrace.agent role追加 |

### 未完了（次セッションの優先タスク）

**Task 10: 実際のGCP FOCUS BQスキーマ検証 + dbtモデル書き直し**

Opus 5コードレビューで判明した重大な問題：
- dbtモデルはsnake_case列名（`charge_type`、`sub_account_id`等）を想定しているが、GCPの実際のFOCUS BQエクスポートはPascalCase（`ChargeCategory`、`SubAccountId`等）
- `charge_type`列は存在しない → 正しくは`ChargeCategory`
- クレジット情報はフラット列ではなく、繰り返しレコード`x_Credits{Type, Name, Amount}`にある（UNNESTが必要）
- クレジットtype文字列も人間可読な文字列（`'Enterprise Discount Program'`）ではなくGCPトークン（`COMMITTED_USAGE_DISCOUNT`等）
- → `dbt run`は最初のstagingモデルで"Unrecognized name"エラーで失敗する

**Task 11: 課金ソースenv varのVM配線 + データセット名二重化修正**

同じくOpus 5レビューで判明：
- `sources.yml`は`DBT_BILLING_PROJECT_ID`、`DBT_BILLING_DATASET`、`DBT_FOCUS_TABLE`env varでBQテーブルを解決するが、`deploy.sh`も`vm-startup.sh`もこれらを設定しない → cronジョブは`YOUR_PROJECT_ID.YOUR_BILLING_DATASET.gcp_billing_export_focus_v1_XXXXXX`でBQに接続しようとして失敗
- dbtのデフォルト`generate_schema_name`マクロが`target.schema` + `custom_schema`を連結するため、martが`finops_dbt`でなく`dbt_staging_finops_dbt`に作成される → Metabaseが参照するデータセットが空になる

## 3. 重要なファイル

| ファイル | 内容 |
|---|---|
| `docs/superpowers/plans/2026-07-25-gcp-finops-rebase.md` | **実装計画（Task 10/11の詳細手順を含む）** — 必ず先読みすること |
| `docs/superpowers/specs/2026-07-25-gcp-finops-rebase-design.md` | アーキテクチャ設計書 |
| `dbt/models/staging/stg_focus_billing.sql` | 要修正：列名がGCP実際スキーマと不一致 |
| `dbt/models/intermediate/int_charges.sql` | 要修正：`charge_type`列が存在しない |
| `dbt/models/intermediate/int_credits.sql` | 要修正：x_Credits UNNESTが必要 |
| `dbt/models/marts/fct_monthly_showback.sql` | 要修正：クレジットtype文字列がGCPトークンと不一致 |
| `dbt/models/staging/sources.yml` | BQソーステーブルのenv var参照 |
| `infra/scripts/env.sh` | Task 11でDBT_BILLING_DATASET等を追加する |
| `infra/scripts/deploy.sh` | Task 11でcmd_profilesに.env生成を追加する |
| `infra/scripts/vm-startup.sh` | Task 11でcronに.envソースを追加する |
| `AGENTS.md` | 新スタックの概要（dbt + Metabase on VM）が記載済み |

## 4. 重要な設計決定事項

| 決定 | 理由 |
|---|---|
| OpenCost → dbt + Metabase | OpenCostはcredits[]配列を集計して捨てる。BQを直接クエリして粒度を保持 |
| Cloud Run → e2-medium VM | MetabaseはJVMアプリでCloud Run cold startが15-30秒。VMは常時起動でコストも安い（~$42/月） |
| GCP FOCUS export（標準/詳細でなく） | FOCUS 1.0はChargeType=Creditが一級市民。クレジット分類が構造的に組み込まれている |
| VM IAP SSH only | セキュリティ原則D準拠。ポート22は公開しない |
| allowed_ingress_cidrs default=[] | deny-by-defaultセキュリティ姿勢。デプロイ時に明示的にCIDRを指定必要 |
| dbt views（materialisedでない） | BQはview再評価。データが変わればMetabaseクエリに自動反映 |

## 5. 発生した問題と対処

| 問題 | 対処 |
|---|---|
| Cloud Run cold start問題 | e2-medium VMに切り替え（コストも$110→$42/月） |
| cmd_restart heredocのシェル変数スコープバグ | `'REMOTE'`（シングルクォート）→ローカル変数経由の展開パターンに修正 |
| commitment_discount_category int_chargesから欠落 | `fct_commitment_discounts`がint_chargesを参照するため追加 |
| profiles.yml VMに未デプロイ | `cmd_profiles`関数をdeploy.shに追加、VMでprofiles.yml生成 |
| cloudtrace.agent roleとAPI欠落 | iam.tf + apis.tfに追加（AGENTS.md B3準拠） |
| **dbtスキーマがGCP実際FOCUS列と不一致（未解決）** | Task 10で対処予定：実テーブルスキーマを`bq show`で確認後、SQL全面書き直し |
| **dbt billing source env varが未設定（未解決）** | Task 11で対処予定：env.sh + deploy.sh + vm-startup.shを更新 |
| **dbtデータセット名二重化（未解決）** | Task 11で対処予定：`generate_schema_name`マクロ追加 |

## 6. 次のセッションへの依頼

### 優先タスク（順番通りに実施）

1. **Task 10（最優先）: 実際のGCP FOCUS BQスキーマを確認してdbtモデルを書き直す**
   - 計画ファイルの「Task 10」セクションに詳細な手順あり
   - まず`bq show --schema`で実テーブルのスキーマを取得
   - 次にクレジットtypeトークンを実データからSQLで列挙
   - 全dbtモデルを実スキーマに合わせて修正
   - 実テーブルで`dbt run`→`dbt test`を実行して検証

2. **Task 11（Task 10と並行または直後）: env varとデータセット名を修正**
   - 計画ファイルの「Task 11」セクションに詳細な手順あり
   - `infra/scripts/env.sh`にDBT_BILLING_DATASET等を追加
   - `deploy.sh cmd_profiles`で`.env`ファイルもVM上に生成するよう修正
   - `vm-startup.sh`のcronに`.env`ソースを追加
   - `dbt/macros/generate_schema_name.sql`を作成（schema名二重化防止）

3. **Task 10検証後: `tofu apply`でインフラをプロビジョニング**
   - `cd infra && tofu init && tofu plan`
   - `deploy.sh all`でVM上にファイルをデプロイ
   - B9スモークテストチェックリストを実行（AGENTS.md参照）

### 参照すべきファイル（重要度順）

1. `docs/superpowers/plans/2026-07-25-gcp-finops-rebase.md` — Task 10/11の詳細手順
2. `AGENTS.md` — 新スタック全体像とデプロイフロー
3. `infra/scripts/env.sh` — プロジェクト/リージョン等のデフォルト値
4. `infra/examples/metabase-bigquery-setup.md` — Metabase接続手順

### 注意事項

- **`dbt run`はTask 11（env var設定）なしでは失敗する** — Task 10の検証前に必ずTask 11を実施
- GCP FOCUS exportテーブル: `demogcp-terra2021.export_billing_demogcp_detailed.gcp_billing_export_focus_v1_01E5F4_66804E_8286B7`
- アクティブプロジェクト: `demogcp-terra2021`（`infra/scripts/env.sh`のデフォルト値）
- Tofu stateバケット: `gs://demogcp-terra2021-tofu-state`（prefix: `tofu/finops`）
- VMデプロイ後のSSH: `gcloud compute ssh finops-vm --zone=us-central1-a --tunnel-through-iap --project=demogcp-terra2021`
- 現在ブランチ: `develop`（main branch）

## 7. Git状態

```
Branch: develop
Last commit: b582f4a3 fix: address final review findings
Status: clean (Tasks 1-9完了、計画・handoffファイルは未コミット)
```

12コミットが今セッションで追加された（Task 1–9 + レビュー修正）。
