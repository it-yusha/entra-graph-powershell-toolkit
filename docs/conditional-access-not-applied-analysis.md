# Conditional Access not-applied alert analysis

## 目的

既存のAzure Monitorログ検索アラートが条件付きアクセス未適用の可能性を検知したあとに、担当者が初動確認を行うための読み取り専用ツールです。

このツールは既存アラートを作成、変更、削除、無効化しません。条件付きアクセスポリシー、ユーザー、グループ、アプリ、Log Analytics Workspaceにも変更を加えません。

ツールが行うことは次のとおりです。

1. Log Analyticsから既存アラート相当の成功サインインを取得する
2. イベントIDで重複を除去する
3. 任意でMicrosoft Graphからユーザー作成日時を補完する
4. 既知の除外対象を分離する
5. ユーザーとアプリの組み合わせごとに集計・分類する
6. CSV、AI相談メモ、初動確認チェックリストを出力する

## できないこと

- 条件付きアクセスが適用されなかった根本原因を自動的に断定する
- CAポリシーの現在の対象・除外設定を検証する
- グループ、属性、ライセンスの設定完了状態を自動的に保証する
- 新規作成アカウントを「新入社員」と断定する
- アラートの発報履歴そのものを取得する
- ユーザー無効化、削除、ロール変更、セッション失効を行う
- CAポリシー、Azure Monitorアラート、Workspaceを変更する

分類結果は初動確認の優先順位付けであり、変更の承認ではありません。

## 前提

- PowerShell 7.2以降
- `Az.Accounts`
- `Az.OperationalInsights`
- `Microsoft.Graph.Authentication`
- 対象WorkspaceへクエリできるAzure RBAC
- Graph補完を使用する場合はMicrosoft Graphの`User.Read.All`

Azure側では、対象Workspaceまたは対象テーブルに対するクエリ権限が必要です。組織で承認された最小権限のロールを使用してください。このツールはRBACやGraph同意を付与しません。

## セットアップ

設定例を実設定へコピーします。

```powershell
Copy-Item `
  ./config/conditional-access-not-applied-analysis.config.example.json `
  ./config/conditional-access-not-applied-analysis.config.json
```

除外一覧を使用する場合は、サンプルを実ファイル名へコピーします。

```powershell
Copy-Item `
  ./config/conditional-access-exclude-users.sample.csv `
  ./config/conditional-access-exclude-users.csv

Copy-Item `
  ./config/conditional-access-exclude-apps.sample.csv `
  ./config/conditional-access-exclude-apps.csv
```

実設定と実除外一覧は`.gitignore`対象です。実テナント値、UPN、アプリ名、除外理由を公開リポジトリへコミットしないでください。

## 実行

設定の`Query.LookbackDays`を使う場合:

```powershell
./scripts/Get-ConditionalAccessNotAppliedAnalysisFromLogAnalytics.ps1
```

アラートメールなどから対象期間が分かる場合:

```powershell
./scripts/Get-ConditionalAccessNotAppliedAnalysisFromLogAnalytics.ps1 `
  -StartDateTime '2026-06-21T00:00:00Z' `
  -EndDateTime '2026-06-28T00:00:00Z'
```

別設定:

```powershell
./scripts/Get-ConditionalAccessNotAppliedAnalysisFromLogAnalytics.ps1 `
  -ConfigPath ./config/my-ca-analysis.local.json
```

AzureとGraphは対話サインインです。要件を満たす既存コンテキストがある場合は再利用します。

## 既存アラートとの関係

公開KQLテンプレートは、次の一般化した検知条件を再現します。

- `SigninLogs`
- `ConditionalAccessStatus == "notApplied"`
- `ResultType == "0"`、つまり成功
- 設定したUPNサフィックスまたは正規表現に一致
- 設定したUPN、サフィックス、TokenIssuerTypeを除外
- `ConditionalAccessPolicies`が空ではない
- 個別ポリシー結果に`notApplied`が含まれる

実際のアラートと分析ツールの条件がずれると件数も一致しません。会社固有のアラート条件が変更された場合は、設定とKQLテンプレートを内部レビューしてください。

Azure Monitorのアラート窓は重なることがあります。さらにステートレスアラートは、同じイベントを含む条件を繰り返し評価できます。このツールは通知回数を活動回数として扱わず、`SigninLogs.Id`でイベントを重複除去します。

## KQLとPowerShellの役割

KQL:

- UTC期間、CA状態、成功結果、ユーザー範囲による絞り込み
- `ConditionalAccessPolicies`の展開
- イベント単位のポリシー結果集約
- レポート作成に必要な列だけを返す

PowerShell:

- 設定と除外一覧の検証
- イベントIDによる重複除去
- Graphユーザー情報の補完
- ユーザーIDとアプリID単位の集約
- 新規作成アカウント、複数日継続、非対話のみ等の分類
- CSV式インジェクション対策
- CSVとMarkdownの生成

設定値は検証・エスケープしてKQLトークンへ挿入します。設定ファイルに自由なKQL断片や資格情報を置く設計ではありません。

## 設定

### 接続

| キー | 説明 |
|---|---|
| `TenantId` | 任意。空なら対話サインインで選択 |
| `SubscriptionId` | 任意。Azureコンテキストを固定する場合に指定 |
| `WorkspaceId` | Workspace Customer ID |

### Query

| キー | 説明 |
|---|---|
| `LookbackDays` | 開始・終了日時を指定しない場合の検索日数 |
| `KqlTemplatePath` | KQLテンプレート |
| `IncludeSensitiveDetails` | IP、場所、端末、UserAgent等を取得・詳細CSVへ出すか。既定`false` |

相対パスは設定JSONのディレクトリ基準です。

### AlertScope

| キー | 説明 |
|---|---|
| `IncludedUpnSuffixes` | 対象UPNサフィックス |
| `IncludedUpnRegexPatterns` | 対象UPNの正規表現 |
| `ExcludedUpnSuffixes` | アラート条件として検索対象外にするサフィックス |
| `ExcludedUserPrincipalNames` | アラート条件として検索対象外にするUPN |
| `ExcludedTokenIssuerTypes` | 検索対象外にするTokenIssuerType |

`IncludedUpnSuffixes`または`IncludedUpnRegexPatterns`の少なくとも一方が必要です。

`AlertScope`の除外は、既存アラートの母集団そのものを再現するためのものです。ここで除外されたイベントは取得されないため、`excluded.csv`には入りません。

### GraphEnrichment

| Mode | 動作 |
|---|---|
| `Disabled` | Graphへ接続しない |
| `Optional` | 補完に失敗してもレポートを継続する。公開設定の既定 |
| `Required` | Graph補完できなければ停止する |

`NewAccountGracePeriodDays`は、最新検知時点でユーザー作成から何日以内なら「新規作成アカウントの設定途中の可能性」とするかを指定します。

ユーザー作成日だけで新入社員とは断定しません。

### RepeatedMatchingSignIn

複数日にわたる条件一致は、次の両方を満たした場合に分類します。

- `MinimumDistinctDays`: 条件一致イベントが存在した異なるUTC日数
- `MinimumEventCount`: 異なるイベントIDの最小件数

同じ日に多数発生した一連のイベントだけで「複数日継続」としないため、両方を使用します。

### Exclusions

`Exclusions.UsersPath`と`Exclusions.AppsPath`は、分析担当者が管理する既知除外です。これらはKQLの母集団から消さず、取得後に`excluded.csv`へ分離します。

`AllowMissingFiles=true`なら、実除外ファイルがない状態でも空の除外一覧として実行できます。

ユーザー除外列:

| 列 | 説明 |
|---|---|
| `UserId` | 推奨する安定キー。空欄の場合はUPNが必要 |
| `UserPrincipalName` | 補助キー。User IDと併記可能 |
| `Reason` | 必須の除外理由 |
| `ExpiresOn` | 任意。`YYYY-MM-DD`。期限切れ行は無視 |

アプリ除外列:

| 列 | 説明 |
|---|---|
| `AppId` | 必須のApplication / Client ID |
| `Reason` | 必須の除外理由 |
| `ExpiresOn` | 任意。期限切れ行は無視 |

表示名だけでは照合しません。UPNや表示名は変更されるため、可能な限りUser IDとApp IDを使用してください。

### Output

| キー | 説明 |
|---|---|
| `Directory` | 実行単位ディレクトリを作る出力先 |
| `GenerateDetailsCsv` | イベント単位CSVを生成 |
| `GenerateAiPromptMarkdown` | AI相談メモを生成 |
| `GenerateChecklistMarkdown` | 初動確認チェックリストを生成 |
| `AiIdentityMode` | `Alias`、`Masked`、`Raw`。既定`Alias` |
| `AiMaximumTopItems` | AIメモの上位項目数 |

`Raw`はUPNとアプリ表示名をAIメモへ出します。組織の承認なしに使用しないでください。

## 分類

優先順位は次のとおりです。

| 優先 | Category | 日本語 | 主な条件 |
|---|---|---|---|
| 1 | 除外 | 既知除外 | 除外CSVに一致。メインサマリから分離 |
| 2 | `Unknown` | 要確認 | User IDまたはApp ID不足 |
| 3 | `LikelyRecentAccountProvisioning` | 新規作成アカウントの設定途中の可能性 | 作成日時から猶予日数以内 |
| 4 | `RepeatedMatchingSignIn` | 条件一致サインインの複数日継続 | 異なる日とイベントの両基準を満たす |
| 5 | `NonInteractiveOnly` | 非対話サインインのみ | 取得したイベントがすべて非対話 |
| 6 | `PolicyScopeReviewRequired` | CA対象条件の確認が必要 | 上記に該当しない |

`LikelyRecentAccountProvisioning`は、新入社員であることや設定途中であることを証明しません。猶予期限後も新しい条件一致イベントが続く場合は、本格調査してください。

## 出力

```text
output/
  conditional-access-not-applied-analysis-YYYYMMDD-HHmmssZ/
    summary.csv
    details.csv
    excluded.csv
    ai-prompt.md
    checklist.md
```

### summary.csv

1行は原則として`UserId + AppId`です。

主要列:

- ユーザー・アプリの実値とAI用エイリアス
- Graph作成日時と最新検知時点のアカウント年齢
- 条件一致イベント数と異なる検知日数
- 対話・非対話件数
- 初回・最終日時
- カテゴリ、理由コード、推定理由、推奨対応、優先度
- 再確認日時
- Graph補完状態
- 評価期間

### details.csv

イベントID単位です。既定では、IP、場所、端末、UserAgent、Correlation IDを含みません。

`IncludeSensitiveDetails=true`の場合だけこれらをKQLで取得し、詳細CSVへ追加します。サマリとAIメモには追加しません。

### excluded.csv

分析用除外CSVに一致したユーザー・アプリを、件数、期間、理由、有効期限とともに出力します。除外対象を黙って捨てません。

### ai-prompt.md

既定の`Alias`では、ユーザーを`User-001`、アプリを`App-001`のように表し、UPN、表示名、ID、生ログを含めません。

生成ファイルが匿名化されていても、利用するAIサービス、共有先、保存先について組織の規程を確認してください。

### checklist.md

新規作成アカウント、複数日継続、CAスコープ、除外、情報取扱いの確認項目を、実行時のしきい値と期間付きで生成します。

## 失敗時の動作

次の場合は最終出力前に停止します。

- 設定JSON不正
- シークレットらしい設定項目
- Workspace ID不正
- 不正な正規表現
- 不正な除外CSV、GUID、日付、重複キー
- KQLトークン置換不正
- Azure認証、権限、Workspaceクエリエラー

Graphが`Optional`で利用できない場合は停止せず、`GraphEnrichmentStatus=Unavailable`として、新規作成アカウント分類を行わずに継続します。

## 安全上の注意

- `notApplied`だけで設定漏れと断定しない
- 分類から直接アカウントやCAポリシーを変更しない
- 実設定、除外一覧、CSV、Markdown、ログをコミットしない
- 詳細CSVを必要以上に生成・共有しない
- ログ由来文字列をチケットやAIへ転記する前に確認する
- AI出力は参考情報とし、人間が元ログとCA設定を確認する
