# Administrator account inactivity review from Log Analytics

## 目的

管理者アカウント台帳CSVを対象一覧の正として、Microsoft Entraユーザー状態とLog Analytics上の成功サインインを照合し、次の状態へ分類します。

- 利用あり
- 要確認
- 休眠候補
- 判定対象外
- 無効化済み

`休眠候補` / `DisableCandidate` は無効化を検討するための明確な候補です。ただし、本ツールはアカウント、ロール、セッション、設定を変更しません。実際の無効化は、別の承認済み運用と別スクリプトで扱ってください。

## できること

- CSVからユーザー形式の管理者アカウントを読み込む
- UPNをMicrosoft Graphで現在のユーザーへ解決する
- `AccountEnabled`、`CreatedDateTime`、現在のUPN、表示名を取得する
- 対話・非対話の成功サインイン最終日時を別々に集計する
- アカウント別しきい値、除外、証拠期間、アカウント年齢を考慮する
- 英語コードと日本語説明を含むレビューCSVを日時付きで出力する

## できないこと

- 管理者ロールの現在の割当を検出・検証する
- アプリ登録、サービスプリンシパル、マネージドIDを評価する
- 失敗サインインをセキュリティ分析する
- Workspaceの実際の保持・収集開始日を自動的に保証する
- アカウント無効化、削除、ロール削除、セッション失効を行う
- 承認記録やチケットを管理する

管理者ロール割当は入力CSVの作成プロセス側で確認してください。本ツールは入力CSVを対象一覧の正として扱います。

## 必要環境と権限

PowerShellモジュール：

- `Microsoft.Graph.Authentication`
- `Az.Accounts`
- `Az.OperationalInsights`

Microsoft Graph委任権限：

- `User.Read.All`

Azure側：

- 対象Workspaceまたは対象テーブルでクエリを実行できるRBAC
- `Log Analytics Data Reader`、または組織で承認した同等のカスタムロール

権限付与・管理者同意はこのツールでは行いません。

## 処理フロー

1. JSON設定を認証前に検証する
2. 入力CSVのUPN、重複、真偽値、しきい値を検証する
3. AzureとMicrosoft Graphへ対話サインインする
4. 各入力UPNをGraphのユーザー1件へ解決する
5. 有効・非除外・解決済みユーザーをバッチ化する
6. `SigninLogs` をKQLで集計する
7. `AADNonInteractiveUserSignInLogs` をKQLで集計する
8. PowerShellで対話・非対話の最終日時を結合する
9. 純粋な判定関数でレビュー状態を決める
10. 休眠候補、要確認、利用あり、無効化済み、除外の順でCSV出力する

KQLから取得するのは `UserId` と `LastSignInDateTime` だけです。IPアドレス、端末、場所、UserAgent、Conditional Access、Correlation ID、生ログは取得・出力しません。

## 入力CSV

必須列：

| 列 | 説明 |
|---|---|
| `UserPrincipalName` | 管理者アカウントのUPN。大文字小文字を無視して重複禁止 |

任意列：

| 列 | 説明 |
|---|---|
| `ExcludeFromInactiveCheck` | `true`、`false`、空欄のみ。空欄は`false` |
| `InactiveThresholdDays` | アカウント固有のしきい値。空欄は設定既定値 |
| `Owner` | 管理責任者・チームなどのダミー化可能な補助情報 |
| `Purpose` | アカウント用途 |
| `AccountType` | NamedAdmin、EmergencyAccessなどの分類 |
| `Note` | 入力台帳から引き継ぐ注記 |

対応する引継ぎ列は設定の `Input.PassthroughColumns` で選択します。公開版では `Owner`、`Purpose`、`AccountType`、`Note` だけを許可します。

## 設定

| キー | 説明 |
|---|---|
| `TenantId` | 任意。空なら対話サインインで選択 |
| `SubscriptionId` | 任意。Azureコンテキストを固定する場合に指定 |
| `WorkspaceId` | Log Analytics Workspace Customer ID |
| `Input.CsvPath` | 入力CSV。設定ファイルディレクトリ基準 |
| `Input.PassthroughColumns` | 許可済み任意列 |
| `Evaluation.DefaultInactiveThresholdDays` | CSVで空欄時の既定しきい値 |
| `Evaluation.LookbackDays` | Log Analytics検索期間。最大しきい値以上が必要 |
| `Evaluation.EvidenceCoverageStartDateTime` | 組織が両テーブルを信頼できると確認した開始日時 |
| `Evaluation.BatchSize` | 1クエリに渡すUser ID数。1～1000 |
| `Evaluation.KqlTemplatePath` | KQLテンプレート |
| `Output.Directory` | 日時付きCSVの出力先 |
| `Output.FileNamePrefix` | 出力ファイル名の接頭辞 |
| `Logging.Directory` | 個人情報を本文に含めない運用ログ |

`EvidenceCoverageStartDateTime` はWorkspaceから自動検出しません。診断設定開始、テーブル収集、保持期間、欠損の有無を組織側で確認して設定してください。

## 判定優先順位

| 優先 | 条件 | ReviewStatus | ReviewStatusJa | RecommendedAction |
|---|---|---|---|---|
| 1 | 除外フラグあり | `Excluded` | 判定対象外 | `NoAction` |
| 2 | Graphで1件に解決できない | `ReviewRequired` | 要確認 | `Review` |
| 3 | `AccountEnabled`不明 | `ReviewRequired` | 要確認 | `Review` |
| 4 | `AccountEnabled=false` | `AlreadyDisabled` | 無効化済み | `NoAction` |
| 5 | 対話サインインがしきい値内 | `Active` | 利用あり | `NoAction` |
| 6 | 非対話のみしきい値内 | `ReviewRequired` | 要確認 | `Review` |
| 7 | 証拠期間不足 | `ReviewRequired` | 要確認 | `Review` |
| 8 | 作成日時不明・アカウントが新しい | `ReviewRequired` | 要確認 | `Review` |
| 9 | 対話・非対話とも古い | `InactiveCandidate` | 休眠候補 | `DisableCandidate` |
| 10 | ログなし、証拠期間・年齢十分 | `InactiveCandidate` | 休眠候補 | `DisableCandidate` |

直近判定はレポート生成UTC日時からアカウント別 `InactiveThresholdDays` を引いた日時との比較です。経過日数は24時間単位で切り捨て、未来時刻は0日として扱います。

## SignInPattern

| SignInPattern | SignInPatternJa |
|---|---|
| `BothRecent` | 対話・非対話とも直近利用あり |
| `InteractiveRecentOnly` | 対話サインインが直近利用あり |
| `NonInteractiveRecentOnly` | 非対話サインインのみ直近利用あり |
| `NoRecentSignIn` | 直近利用なし |
| `NoSignInRecord` | 対象期間内ログなし |
| `Unresolved` | ユーザー未解決 |
| `AlreadyDisabled` | 無効化済み |
| `Excluded` | 判定対象外 |

`InteractiveRecentOnly` は「非対話ログが一度もない」とは限らず、非対話ログがないか、しきい値より古いことを表します。

## 非対話のみ利用あり

非対話サインインには、ユーザーがその場で認証操作をしないトークン更新などが含まれます。そのため、最近の非対話ログだけをもって管理者本人が継続利用しているとは判断しません。

`NonInteractiveRecentOnly` は必ず `ReviewRequired` とし、アカウント用途、ジョブ、資格情報、依存システムを確認するための材料にします。

## 失敗ログ

失敗サインインは休眠判定の利用実績に含めません。休眠アカウントに対する攻撃や期限切れ資格情報の試行を「利用あり」と誤認するのを防ぐためです。

失敗ログ、リスク、IP、場所、Conditional Accessなどは、別のセキュリティレビューとして設計してください。

## 出力CSV

列は次のグループで構成されます。

- 入力・現在のユーザー情報
- Owner、Purpose、AccountType、InputNote
- 対話・非対話・任意サインインの最終日時と経過日数
- しきい値、除外、証拠期間
- Graph解決状態
- SignInPatternと日本語
- ReviewStatus、理由コード、英語・日本語理由
- RecommendedAction
- ReportGeneratedDateTime

出力ファイル名：

```text
admin-account-inactivity-review-YYYYMMDD-HHmmss.csv
```

承認列は含みません。レビュー後の承認・判断は、アクセス制御されたチケット、台帳、ワークフローなどで別管理してください。生成CSVへ承認情報を追記して再入力する運用は想定していません。

## 安全上の注意

- `InactiveCandidate` を機械的に無効化しない
- 緊急アクセスアカウントは入力台帳で明示的に除外し、別の統制で管理する
- 入力・出力CSVは管理者アカウント情報を含むため公開リポジトリへ置かない
- 実行ログ、設定、Workspace情報を不要な共有先へ渡さない
- 実際の無効化ツールを作る場合は、別リポジトリまたは社内限定スクリプトとして独立レビューする

## テスト

公開テストでは、少なくとも次を検証します。

- 入力正規化、重複、不正しきい値
- KQLに生ログ詳細列がないこと
- 除外
- 無効化済み
- 対話利用あり
- 非対話のみ
- 古いログ
- ログなし
- 証拠期間不足
- 新規アカウント
- Graph未解決
- 承認列が出力にないこと

実テナント・実Workspace接続は公開CIでは行いません。
