# Entra Graph PowerShell Toolkit

Microsoft Entra ID、Microsoft Graph、Azure Monitor Logs を使い、情シス業務で再利用できる**読み取り専用**PowerShellスクリプトを公開可能な形で管理するツールキットです。

> 実在するTenant ID、Workspace ID、Subscription ID、Group ID、App ID、ユーザー、ドメイン、社内アプリ名、実ログをコミットしないでください。

## 収録ツール

| 方式 | スクリプト | 向いている用途 |
|---|---|---|
| Microsoft Graph版 | `Get-AppLastSignInByGroup.ps1` | Graphの標準保持期間内を取得し、管理CSVへ確認済み日時を累積する |
| グループ×アプリ Log Analytics版 | `Get-GroupAppLastSignInFromLogAnalytics.ps1` | Workspaceへ保存済みの長期ログをKQLで集計し、共有用の最小CSVを都度作成する |
| 管理者アカウント休眠レビュー | `Get-AdminAccountInactivityReviewFromLogAnalytics.ps1` | 入力CSVの管理者アカウントを、対話・非対話ログと照合して休眠候補へ分類する |
| CA未適用アラート分析支援 | `Get-ConditionalAccessNotAppliedAnalysisFromLogAnalytics.ps1` | 既存アラート後に成功サインインを整理し、新規アカウント候補、複数日継続、既知除外等へ分類する |

Graph版はCSV台帳を継続更新する方式です。Log Analytics版はGraph版を置き換えず、組織が既にWorkspaceへEntraサインインログを保存している場合の選択肢です。管理者休眠レビューは入力台帳を対象一覧の正とし、その時点のレビューCSVを新規生成します。CA未適用アラート分析支援は既存アラートを置き換えず、通知後の初動確認を補助します。

すべてのツールがEntra ID、グループ、アプリ、Workspaceの設定変更、ユーザーの無効化・削除、ロール・権限変更を行いません。クラウド側への操作は読み取りだけで、ローカルにCSVと実行ログを作成します。

## リポジトリ構成

```text
entra-graph-powershell-toolkit/
├── .github/workflows/powershell.yml
├── config/
│   ├── admin-account-inactivity-review.config.example.json
│   ├── conditional-access-not-applied-analysis.config.example.json
│   ├── conditional-access-exclude-apps.sample.csv
│   ├── conditional-access-exclude-users.sample.csv
│   ├── config.example.json
│   └── group-app-last-signin.loganalytics.config.example.json
├── docs/
│   ├── admin-account-inactivity-review-loganalytics.md
│   ├── app-last-signin-by-group.md
│   ├── conditional-access-not-applied-analysis.md
│   └── group-app-last-signin-loganalytics.md
├── kql/
│   ├── admin-account-last-signin.kql
│   ├── conditional-access-not-applied-analysis.kql
│   └── group-app-last-signin.kql
├── modules/SignInReview/
│   ├── ConditionalAccessAnalysis.ps1
│   ├── SignInReview.psd1
│   └── SignInReview.psm1
├── samples/
│   ├── admin-account-inactivity-review.sample.csv
│   ├── admin-accounts.sample.csv
│   ├── conditional-access-not-applied-ai-prompt.sample.md
│   ├── conditional-access-not-applied-checklist.sample.md
│   ├── conditional-access-not-applied-details.sample.csv
│   ├── conditional-access-not-applied-excluded.sample.csv
│   ├── conditional-access-not-applied-summary.sample.csv
│   ├── sample-output.csv
│   └── group-app-last-signin-loganalytics.sample.csv
├── scripts/
│   ├── Get-AdminAccountInactivityReviewFromLogAnalytics.ps1
│   ├── Get-AppLastSignInByGroup.ps1
│   ├── Get-ConditionalAccessNotAppliedAnalysisFromLogAnalytics.ps1
│   └── Get-GroupAppLastSignInFromLogAnalytics.ps1
├── tests/
│   ├── AdminAccountInactivityReview.Tests.ps1
│   ├── ConditionalAccessNotAppliedAnalysis.Tests.ps1
│   └── Repository.Tests.ps1
├── .gitignore
├── LICENSE
├── PSScriptAnalyzerSettings.psd1
├── README.md
└── SECURITY.md
```

`SignInReview` モジュールには、設定検証、Graphユーザー取得、KQL生成、Log Analyticsクエリ、判定、CSV・Markdown出力、実行ログなどの共通処理をまとめています。既存Graph版は互換性を守るため、現時点では自己完結のままです。

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
| `LastInteractiveSignInDateTime` | 対話サインインの最新成功日時 |
| `LastNonInteractiveSignInDateTime` | 非対話サインインの最新成功日時 |
| `SignInFoundJa` | `ログあり` または `対象期間内ログなし` |
| `QueriedSignInTypes` / `Ja` | 対話・非対話のどちらを検索したか |
| `SignInPattern` / `Ja` | 両方、対話のみ、非対話のみ、ログなし等 |
| `EvaluationWindowStartDateTime` | 検索期間の開始日時 |
| `EvaluationWindowEndDateTime` | 検索期間の終了日時 |
| `NoteJa` | 人間向けの日本語注意事項 |

既存の英語列は後方互換のため維持し、日本語の状態・パターン・注記を追加しています。非対話のみの場合は、人の明示操作とは限らない旨を明示します。

Workspace ID、テーブル名、保持期間、生ログ詳細は共有用CSVへ含めません。検索条件の誤解を避けるため、評価期間の開始・終了日時だけを含めます。UPN、表示名、アプリ表示名にはCSV数式インジェクション対策を行います。

### KQLの概要

KQLテンプレートは [kql/group-app-last-signin.kql](kql/group-app-last-signin.kql) に分離しています。PowerShellは検証済みGUIDとUTC期間、許可済みテーブル名だけをトークンへ埋め込みます。

テーブルごと、ユーザーバッチごとに次を行います。

1. `TimeGenerated`、`AppId`、成功結果、対象User IDで絞る
2. `summarize max(TimeGenerated) by UserId`
3. `UserId` と最終日時だけをPowerShellへ返す

`SigninLogs` と `AADNonInteractiveUserSignInLogs` は別クエリにしています。これによりテーブル固有のエラーを特定しやすくし、不要なcross-table unionを避けています。

詳細は [Log Analytics版ドキュメント](docs/group-app-last-signin-loganalytics.md) を参照してください。

## 管理者アカウント休眠レビュー

入力CSVを管理者アカウント対象一覧の正として、Microsoft Graphから現在のユーザー状態を補完し、Log Analyticsの成功サインインと突き合わせます。

### 判定概要

| 条件 | ReviewStatus | 日本語 | RecommendedAction |
|---|---|---|---|
| 入力で除外 | `Excluded` | 判定対象外 | `NoAction` |
| Graph上で無効 | `AlreadyDisabled` | 無効化済み | `NoAction` |
| 対話サインインがしきい値内 | `Active` | 利用あり | `NoAction` |
| 非対話サインインだけがしきい値内 | `ReviewRequired` | 要確認 | `Review` |
| 対話・非対話とも古い | `InactiveCandidate` | 休眠候補 | `DisableCandidate` |
| ログなし、証拠期間とアカウント年齢が十分 | `InactiveCandidate` | 休眠候補 | `DisableCandidate` |
| ユーザー未解決、証拠不足、新規アカウント | `ReviewRequired` | 要確認 | `Review` |

`InactiveCandidate` は明確な無効化候補ですが、実際の無効化判断・承認・変更は組織の運用手順で行います。本ツールには無効化処理も承認処理もありません。

### 必要な権限

- Microsoft Graph委任権限：`User.Read.All`
- 対象Workspaceまたはテーブルへクエリ可能なAzure RBAC

`User.Read.All` は `AccountEnabled`、作成日時、現在のUPN、表示名を取得するために使用します。管理者ロール一覧は取得せず、入力CSVを対象一覧として扱います。

### セットアップと実行

```powershell
New-Item -ItemType Directory ./input -Force | Out-Null
Copy-Item ./samples/admin-accounts.sample.csv ./input/admin-accounts.csv
Copy-Item `
  ./config/admin-account-inactivity-review.config.example.json `
  ./config/admin-account-inactivity-review.config.json

./scripts/Get-AdminAccountInactivityReviewFromLogAnalytics.ps1
```

実際の入力CSVには最低限 `UserPrincipalName` が必要です。

```csv
UserPrincipalName,ExcludeFromInactiveCheck,InactiveThresholdDays,Owner,Purpose,AccountType,Note
admin01@example.invalid,false,90,Example Operations Team,Daily administration,NamedAdmin,Dummy note
```

- `ExcludeFromInactiveCheck`：空欄または`false`が通常判定、`true`が対象外
- `InactiveThresholdDays`：空欄なら設定ファイルの既定値
- `Owner`、`Purpose`、`AccountType`、`Note`：任意の引継ぎ列
- UPN重複、不正な真偽値、検索期間より長いしきい値はエラー

### 証拠期間

`EvidenceCoverageStartDateTime` には、組織が対話・非対話ログを信頼できると確認した開始日時を設定します。実際の評価開始日は次の遅い方です。

- 実行日時から `LookbackDays` を遡った日時
- `EvidenceCoverageStartDateTime`

この期間がアカウント固有のしきい値より短い場合、ログがなくても休眠候補にはせず `ReviewRequired` にします。アカウント作成からしきい値の日数が経っていない場合も同様です。

### 対話・非対話と失敗ログ

`SigninLogs` と `AADNonInteractiveUserSignInLogs` を別々に集計します。非対話のみ最近ある場合は人の利用と断定せず、`ReviewRequired` とします。

休眠判定に使用するのは成功ログだけです。失敗ログを活動実績に含めると、攻撃や期限切れ資格情報による試行で休眠候補を見逃す可能性があるためです。

出力は `admin-account-inactivity-review-YYYYMMDD-HHmmss.csv` の形式で毎回新規作成します。承認用の `ApprovedToDisable`、`ReviewedBy` などの列は初版に含めません。

詳細な列、理由コード、運用チェックは [管理者休眠レビューのドキュメント](docs/admin-account-inactivity-review-loganalytics.md) を参照してください。

## 条件付きアクセス未適用アラート分析支援

既存のAzure Monitorログ検索アラートが発生したあとに、同等の条件で`SigninLogs`を読み、初動確認用レポートを生成します。既存アラート、CAポリシー、ユーザー、グループ、アプリ、Workspaceは変更しません。

### 主な処理

- 成功かつ`ConditionalAccessStatus=notApplied`の候補をKQLで取得
- 重なるアラート評価期間に含まれた同じイベントを`SigninLogs.Id`で重複除去
- 任意でGraphの`createdDateTime`を取得
- ユーザー×アプリ単位で新規作成アカウント候補、複数日継続、非対話のみ等へ分類
- 既知の除外対象を別CSVへ分離
- 既定で匿名化したAI相談メモと初動確認チェックリストを生成

Graph補完を使う場合の委任権限は`User.Read.All`です。Azure側には対象Workspaceまたはテーブルへのクエリ権限が必要です。

### セットアップと実行

```powershell
Copy-Item `
  ./config/conditional-access-not-applied-analysis.config.example.json `
  ./config/conditional-access-not-applied-analysis.config.json

./scripts/Get-ConditionalAccessNotAppliedAnalysisFromLogAnalytics.ps1
```

実際のUPN条件、Workspace ID、除外値は実設定と実除外CSVへ置き、スクリプトや公開KQLへ直接書かないでください。

既定ではIP、場所、端末、UserAgent、Correlation IDを取得・出力しません。AI相談メモは`User-001`、`App-001`のようなエイリアスを使用します。それでも組織のデータ取扱い規程に従って、共有前に内容を確認してください。

このツールは`notApplied`の根本原因を断定しません。分類は、猶予期限後の再確認やCA対象条件の手動確認を支援するためのものです。

設定、分類、出力列、除外一覧、AIメモの詳細は [CA未適用アラート分析ドキュメント](docs/conditional-access-not-applied-analysis.md) を参照してください。

## 共通の重要事項

- 日時が空欄でも「一度も使っていない」と断定できません。
- `AppId` はサインインイベントのApplication / Client IDです。Resource IDやService Principal object IDとは異なります。
- 設定期間よりWorkspaceの保持期間が短い場合、削除済みログは取得できません。
- Workspaceに対象テーブルが収集されていない場合、Log Analytics版はエラーになります。
- CSVは個人情報・アプリ利用状況・管理者アカウント状態を含みます。アクセス制御された場所へ保存してください。
- Workspaceや長期ログの存在・詳細を、レポート共有先へ不要に開示しないでください。
- CA分析のAI相談メモは既定で匿名化されますが、共有前に個人情報・内部アプリ情報がないか確認してください。
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
- [Microsoft Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference)
- [List group transitive members](https://learn.microsoft.com/graph/api/group-list-transitivemembers)
- [List signIns](https://learn.microsoft.com/graph/api/signin-list)
- [Microsoft Entra data retention](https://learn.microsoft.com/entra/identity/monitoring-health/reference-reports-data-retention)
