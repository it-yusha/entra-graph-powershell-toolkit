# Entra Graph PowerShell Toolkit

Microsoft Entra ID、Microsoft Graph、Azure Monitor Logsを使い、情シス業務の調査・レビューを支援する**読み取り専用**PowerShellツールキットです。

主力は、Log Analytics Workspaceへ保存されたサインインログを分析する3つのツールです。Microsoft Graphだけで動作する旧来のスクリプトも、Workspaceを利用できない場合の補助ツールとして収録しています。

> 実在するTenant ID、Workspace ID、Subscription ID、Group ID、App ID、UPN、ドメイン、社内アプリ名、実ログ、生成レポートをコミットしないでください。

すべてのツールが、Entra ID、条件付きアクセス、ユーザー、グループ、アプリ、Azure Monitorアラート、Workspaceを変更しません。クラウド側は読み取りだけで、ローカルにCSV、Markdown、実行ログを生成します。

## ツールを選ぶ

### 主力ツール：Log Analytics

| 目的 | スクリプト | 出力・特徴 |
|---|---|---|
| CA未適用アラート後の初動調査 | `Get-ConditionalAccessNotAppliedAnalysisFromLogAnalytics.ps1` | サマリ・詳細・除外CSV、匿名化AI相談メモ、チェックリスト |
| 管理者アカウントの休眠レビュー | `Get-AdminAccountInactivityReviewFromLogAnalytics.ps1` | 対話・非対話ログ、証拠期間、アカウント年齢を使った判定CSV |
| グループメンバーのアプリ最終利用確認 | `Get-GroupAppLastSignInFromLogAnalytics.ps1` | 長期ログからユーザー別の最新成功サインインを集計 |

Log Analytics版は、組織がEntraサインインログをWorkspaceへ保存している場合に適しています。KQLで必要な範囲だけを集計し、PowerShellで業務向けに分類・整形します。

### 補助ツール：Microsoft Graph

| 目的 | スクリプト | 位置づけ |
|---|---|---|
| グループメンバーのアプリ最終利用確認 | `Get-AppLastSignInByGroup.ps1` | Graphの標準保持期間内を取得し、ローカルCSVへ確認済み日時を累積 |

Graph版は、Workspaceがない、小規模に試したい、短期ログだけで足りる場合に使える補助・フォールバック版です。長期履歴の正確性や共有レポートを重視する場合は、Log Analytics版を推奨します。

Graph版は互換性維持のため自己完結のまま残しています。新しい共通機能は主に`SignInReview`モジュールを使うLog Analytics版へ追加します。

## 用途別の目安

| やりたいこと | 選ぶツール |
|---|---|
| CA未適用アラートの理由と次の確認点を整理したい | CA未適用アラート分析支援 |
| 管理者アカウントを休眠候補・要確認へ分類したい | 管理者アカウント休眠レビュー |
| 長期ログからグループ×アプリの最終利用を確認したい | グループ×アプリ Log Analytics版 |
| Workspaceなしで短期間の最終利用を確認したい | Microsoft Graph版 |

## 共通の前提

- PowerShell 7.2以降
- 職場または学校アカウント
- 用途に応じたMicrosoft Graphの委任権限
- Log Analytics版では、対象WorkspaceまたはテーブルへクエリできるAzure RBAC

必要なPowerShellモジュール：

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module Microsoft.Graph.Reports -Scope CurrentUser
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.OperationalInsights -Scope CurrentUser
```

権限付与や管理者同意は、このリポジトリのツールでは行いません。組織で承認された最小権限を使用してください。

## クイックスタート

### CA未適用アラート分析支援

既存のAzure Monitorログ検索アラートを置き換えず、通知後の初動確認を支援します。

```powershell
Copy-Item `
  ./config/conditional-access-not-applied-analysis.config.example.json `
  ./config/conditional-access-not-applied-analysis.config.json

./scripts/Get-ConditionalAccessNotAppliedAnalysisFromLogAnalytics.ps1
```

主な動作：

- 成功かつ`ConditionalAccessStatus=notApplied`の候補を取得
- `SigninLogs.Id`で重複イベントを除去
- 任意でGraphからユーザー作成日を補完
- 新規作成アカウント候補、複数日継続、非対話のみ、既知除外等へ分類
- IP、場所、端末、UserAgent、Correlation IDは既定で取得・出力しない
- AI相談メモでは既定で`User-001`、`App-001`のようなエイリアスを使用

詳細：[CA未適用アラート分析](docs/conditional-access-not-applied-analysis.md)

### 管理者アカウント休眠レビュー

入力CSVを対象一覧の正として、Graphの現在情報とLog Analyticsの成功サインインを照合します。

```powershell
New-Item -ItemType Directory ./input -Force | Out-Null
Copy-Item ./samples/admin-accounts.sample.csv ./input/admin-accounts.csv
Copy-Item `
  ./config/admin-account-inactivity-review.config.example.json `
  ./config/admin-account-inactivity-review.config.json

./scripts/Get-AdminAccountInactivityReviewFromLogAnalytics.ps1
```

主な分類：

- `Active`
- `ReviewRequired`
- `InactiveCandidate`
- `AlreadyDisabled`
- `Excluded`

`InactiveCandidate`や`DisableCandidate`はレビュー材料であり、アカウント変更の承認ではありません。

詳細：[管理者アカウント休眠レビュー](docs/admin-account-inactivity-review-loganalytics.md)

### グループ×アプリ Log Analytics版

現在のグループメンバーをGraphで取得し、Workspace内の対話・非対話サインインをユーザー別に集計します。

```powershell
Copy-Item `
  ./config/group-app-last-signin.loganalytics.config.example.json `
  ./config/group-app-last-signin.loganalytics.config.json

./scripts/Get-GroupAppLastSignInFromLogAnalytics.ps1
```

KQLから取得するのはUser IDと集計済み日時が中心です。IP、場所、端末、生ログは共有用CSVへ出力しません。

詳細：[グループ×アプリ Log Analytics版](docs/group-app-last-signin-loganalytics.md)

### Microsoft Graph版

Workspaceを使わず、GraphのサインインAPIとローカルの累積CSVを使用します。

```powershell
Copy-Item ./config/config.example.json ./config/config.json
./scripts/Get-AppLastSignInByGroup.ps1
```

必要な委任権限：

- `AuditLog.Read.All`
- `GroupMember.Read.All`
- `User.ReadBasic.All`

空欄は未使用の証明ではありません。Graphの保持期間、取得遅延、CSVの過去値を考慮して解釈してください。

詳細：[Microsoft Graph版](docs/app-last-signin-by-group.md)

## 設定と出力

- 公開リポジトリには`*.example.json`とダミーサンプルだけを置きます。
- 実設定、実除外CSV、`input/`、`output/`、`logs/`は`.gitignore`対象です。
- 設定内の相対パスは、原則として設定JSONのディレクトリ基準です。
- サンプルIDは固定ダミーGUID、サンプルUPNは`.invalid`ドメインです。
- CSVには個人情報、アプリ利用状況、管理者アカウント状態が含まれる場合があります。

`.gitignore`は補助策です。push前にステージ済み差分とGit履歴を必ず確認してください。

## リポジトリ構成

```text
entra-graph-powershell-toolkit/
├── config/                 # 公開設定例・除外CSVサンプル
├── docs/                   # ツール別の設計・運用ガイド
├── kql/                    # Log Analytics用KQLテンプレート
├── modules/SignInReview/   # 設定、Graph、KQL、分類、出力の共通処理
├── samples/                # ダミー入力・出力例
├── scripts/                # 実行スクリプト
├── tests/                  # Pester
├── README.md
└── SECURITY.md
```

## 解釈上の注意

- 日時が空欄でも「一度も使っていない」とは断定できません。
- 成功サインインは、有意な業務利用そのものを証明しません。
- 非対話サインインは、人の明示操作ではなくトークン更新等の場合があります。
- `AppId`はサインインイベントのApplication / Client IDです。
- 設定した検索期間よりWorkspaceの保持期間が短い場合、削除済みログは取得できません。
- `ConditionalAccessStatus=notApplied`だけで設定漏れとは断定できません。
- AI向けMarkdownは匿名化設定でも、共有前に内容と利用先を確認してください。

詳しい安全要件は[SECURITY.md](SECURITY.md)を参照してください。

## 開発時のチェック

```powershell
Install-Module Pester,PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed

$findings = @(
  Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
  Invoke-ScriptAnalyzer -Path ./modules -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
)
if ($findings) {
  $findings
  throw "PSScriptAnalyzer findings detected."
}
```

GitHub Actionsでも同じチェックを行います。公開CIは実テナントや実Workspaceへ接続しません。

## ドキュメント

- [CA未適用アラート分析](docs/conditional-access-not-applied-analysis.md)
- [管理者アカウント休眠レビュー](docs/admin-account-inactivity-review-loganalytics.md)
- [グループ×アプリ Log Analytics版](docs/group-app-last-signin-loganalytics.md)
- [Microsoft Graph版](docs/app-last-signin-by-group.md)
- [Security and responsible use](SECURITY.md)

## 公式資料

- [Invoke-AzOperationalInsightsQuery](https://learn.microsoft.com/powershell/module/az.operationalinsights/invoke-azoperationalinsightsquery)
- [SigninLogs table](https://learn.microsoft.com/azure/azure-monitor/reference/tables/signinlogs)
- [AADNonInteractiveUserSignInLogs table](https://learn.microsoft.com/azure/azure-monitor/reference/tables/aadnoninteractiveusersigninlogs)
- [Azure built-in roles for Monitor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference)
- [Microsoft Entra data retention](https://learn.microsoft.com/entra/identity/monitoring-health/reference-reports-data-retention)
