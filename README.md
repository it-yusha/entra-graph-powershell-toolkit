# Entra Graph PowerShell Toolkit

Microsoft Entra ID、Microsoft Graph、Azure Monitor Logs を使い、情シス業務で再利用できる**読み取り専用**PowerShellスクリプトを公開可能な形で管理するツールキットです。

> 実在するTenant ID、Workspace ID、Subscription ID、Group ID、App ID、ユーザー、ドメイン、社内アプリ名、実ログをコミットしないでください。

## 収録ツール

| 方式 | スクリプト | 向いている用途 |
|---|---|---|
| Microsoft Graph版 | `Get-AppLastSignInByGroup.ps1` | Graphの標準保持期間内を取得し、管理CSVへ確認済み日時を累積する |
| Log Analytics版 | `Get-GroupAppLastSignInFromLogAnalytics.ps1` | Workspaceへ保存済みの長期ログをKQLで集計し、共有用の最小CSVを都度作成する |

Graph版はCSV台帳を継続更新する方式です。Log Analytics版はGraph版を置き換えず、組織が既にWorkspaceへEntraサインインログを保存している場合の選択肢です。

どちらもEntra ID、グループ、アプリ、Workspaceの設定変更、ユーザーの無効化・削除、権限変更を行いません。クラウド側への操作は読み取りだけで、ローカルにCSVと実行ログを作成します。

## リポジトリ構成

```text
entra-graph-powershell-toolkit/
├── .github/workflows/powershell.yml
├── config/
│   ├── config.example.json
│   └── group-app-last-signin.loganalytics.config.example.json
├── docs/
│   ├── app-last-signin-by-group.md
│   └── group-app-last-signin-loganalytics.md
├── kql/group-app-last-signin.kql
├── modules/SignInReview/
│   ├── SignInReview.psd1
│   └── SignInReview.psm1
├── samples/
│   ├── sample-output.csv
│   └── group-app-last-signin-loganalytics.sample.csv
├── scripts/
│   ├── Get-AppLastSignInByGroup.ps1
│   └── Get-GroupAppLastSignInFromLogAnalytics.ps1
├── tests/Repository.Tests.ps1
├── .gitignore
├── LICENSE
├── PSScriptAnalyzerSettings.psd1
├── README.md
└── SECURITY.md
```

`SignInReview` モジュールには、設定検証、Graphメンバー取得、KQL生成、Log Analyticsクエリ、CSV出力、実行ログなど、今後の休眠アカウントレビューにも流用しやすい処理をまとめています。既存Graph版は互換性を守るため、現時点では自己完結のままです。

## 推奨環境

- PowerShell 7.2以降
- 職場または学校アカウント
- 対象グループを読めるMicrosoft Graph権限
- Log Analytics版では対象WorkspaceへクエリできるAzure RBAC

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module Microsoft.Graph.Reports -Scope CurrentUser
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.OperationalInsights -Scope CurrentUser
```

## Graph版

必要な委任権限：

| 権限 | 用途 |
|---|---|
| `AuditLog.Read.All` | サインインログの読み取り |
| `GroupMember.Read.All` | グループメンバーシップの読み取り |
| `User.ReadBasic.All` | メンバーの表示名・UPNなど基本プロファイルの読み取り |

```powershell
Copy-Item ./config/config.example.json ./config/config.json
./scripts/Get-AppLastSignInByGroup.ps1
```

詳しい累積ルール、保持期間、脱退メンバーの扱いは [Graph版ドキュメント](docs/app-last-signin-by-group.md) を参照してください。

## Log Analytics版

### できること

- Graphから現在の直接または推移的グループメンバーを取得
- `SigninLogs` を対象に成功サインインを検索
- 設定により `AADNonInteractiveUserSignInLogs` も検索
- ユーザーIDをバッチ化し、Workspace側でユーザーごとの最大日時だけを集計
- グループメンバー全員を、ログ有無にかかわらず最小列のCSVへ出力
- IP、場所、端末、UserAgent、Conditional Access、Correlation ID、生ログをCSVへ出力しない

### 必要な権限

Microsoft Graphの委任権限：

| 権限 | 用途 |
|---|---|
| `GroupMember.Read.All` | グループメンバーシップの読み取り |
| `User.ReadBasic.All` | 表示名・UPNなど基本プロファイルの読み取り |

Azure側では、対象Workspaceまたは必要なテーブルに対してクエリを実行できるRBACが必要です。組織の設計に合わせ、現在の組み込みロール `Log Analytics Data Reader`、または `Microsoft.OperationalInsights/workspaces/query/read` を含む承認済みカスタムロールなど、必要最小限を割り当ててください。

権限の付与自体はこのツールでは行いません。非表示メンバーシップのグループは、追加で `Member.Read.Hidden` と対応ロールが必要です。

### セットアップと実行

```powershell
Copy-Item `
  ./config/group-app-last-signin.loganalytics.config.example.json `
  ./config/group-app-last-signin.loganalytics.config.json

./scripts/Get-GroupAppLastSignInFromLogAnalytics.ps1
```

別の設定ファイル：

```powershell
./scripts/Get-GroupAppLastSignInFromLogAnalytics.ps1 `
  -ConfigPath ./config/my-app.loganalytics.local.json
```

AzureとMicrosoft Graphは、それぞれ対話サインインを使用します。既存コンテキストが要件を満たす場合は再利用します。

### 主な設定

| キー | 説明 |
|---|---|
| `TenantId` | 任意。空なら対話サインインで選択したテナント |
| `SubscriptionId` | 任意。Workspaceを参照するAzureサブスクリプション |
| `WorkspaceId` | Log Analytics WorkspaceのCustomer ID |
| `GroupId` | 対象EntraグループのオブジェクトID |
| `MembershipMode` | `Transitive`（既定・推奨）または `Direct` |
| `TargetApp.AppId` | サインインテーブルの `AppId` と照合するクライアントアプリID |
| `TargetApp.DisplayName` | CSV表示専用。Graphやログから検証しない |
| `Query.LookbackDays` | 検索日数。Workspaceに実在する保持期間を延長する設定ではない |
| `Query.IncludeNonInteractiveSignIns` | `true` なら非対話ユーザーサインインも検索 |
| `Query.BatchSize` | 1クエリに渡すユーザーID数。既定500、最大1000 |
| `Query.KqlTemplatePath` | KQLテンプレートへのパス |
| `Output.CsvPath` | 共有用CSVのローカル出力先 |
| `Logging.Directory` | 個人情報を本文に含めない運用ログ出力先 |

相対パスは設定ファイルのディレクトリ基準です。

### 対話・非対話サインイン

既定では両方を確認します。非対話サインインには、ユーザーが画面で操作しないトークン更新なども含まれるため、「アプリがユーザーの代理でアクセスした最終時刻」を拾いやすくなります。一方、明示的な人の操作だけを見たい業務では `IncludeNonInteractiveSignIns=false` にしてください。

どちらも成功イベントだけを対象にします。ただし、成功サインインは有意な業務利用そのものを証明しません。

### CSV列

| 列 | 意味 |
|---|---|
| `UserPrincipalName` | 現在のUPN |
| `DisplayName` | 現在の表示名 |
| `UserId` | ユーザーオブジェクトID。照合キー |
| `AppDisplayName` | 設定した表示用アプリ名 |
| `AppId` | 照合対象アプリID |
| `LastSignInDateTime` | 指定期間で確認できた最新成功日時（UTC） |
| `SignInFound` | 指定条件の集計行が見つかったか |
| `CheckedDateTime` | レポート作成日時（UTC） |
| `Note` | 空欄日時を「未使用」と断定しないための説明 |

Workspace ID、検索期間、テーブル名、保持期間、生ログ詳細は共有用CSVへ含めません。UPN、表示名、アプリ表示名にはCSV数式インジェクション対策を行います。

### KQLの概要

KQLテンプレートは [kql/group-app-last-signin.kql](kql/group-app-last-signin.kql) に分離しています。PowerShellは検証済みGUIDとUTC期間、許可済みテーブル名だけをトークンへ埋め込みます。

テーブルごと、ユーザーバッチごとに次を行います。

1. `TimeGenerated`、`AppId`、成功結果、対象User IDで絞る
2. `summarize max(TimeGenerated) by UserId`
3. `UserId` と最終日時だけをPowerShellへ返す

`SigninLogs` と `AADNonInteractiveUserSignInLogs` は別クエリにしています。これによりテーブル固有のエラーを特定しやすくし、不要なcross-table unionを避けています。

詳細は [Log Analytics版ドキュメント](docs/group-app-last-signin-loganalytics.md) を参照してください。

## 共通の重要事項

- 日時が空欄でも「一度も使っていない」と断定できません。
- `AppId` はサインインイベントのApplication / Client IDです。Resource IDやService Principal object IDとは異なります。
- 設定期間よりWorkspaceの保持期間が短い場合、削除済みログは取得できません。
- Workspaceに対象テーブルが収集されていない場合、Log Analytics版はエラーになります。
- CSVは個人情報・アプリ利用状況を含みます。アクセス制御された場所へ保存してください。
- Workspaceや長期ログの存在・詳細を、レポート共有先へ不要に開示しないでください。
- AI生成コードを業務利用する場合は、会社規程に従って人間がレビュー・テストしてください。

## 開発時のチェック

```powershell
Install-Module Pester,PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed

$findings = @(
  Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
  Invoke-ScriptAnalyzer -Path ./modules -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
)
if ($findings) { $findings; throw "PSScriptAnalyzer findings detected." }
```

GitHub Actionsでも同じ静的チェックを行います。実テナント・実Workspace接続は公開CIで行いません。

## 公式資料

- [Invoke-AzOperationalInsightsQuery](https://learn.microsoft.com/powershell/module/az.operationalinsights/invoke-azoperationalinsightsquery)
- [SigninLogs table](https://learn.microsoft.com/azure/azure-monitor/reference/tables/signinlogs)
- [AADNonInteractiveUserSignInLogs table](https://learn.microsoft.com/azure/azure-monitor/reference/tables/aadnoninteractiveusersigninlogs)
- [Azure built-in roles for Monitor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor)
- [List group transitive members](https://learn.microsoft.com/graph/api/group-list-transitivemembers)
- [List signIns](https://learn.microsoft.com/graph/api/signin-list)
- [Microsoft Entra data retention](https://learn.microsoft.com/entra/identity/monitoring-health/reference-reports-data-retention)
