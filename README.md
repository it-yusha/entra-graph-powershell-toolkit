# Entra Graph PowerShell Toolkit

Microsoft Entra ID と Microsoft Graph PowerShell SDK を使い、情シス業務で再利用できる**読み取り専用**スクリプトを公開可能な形で管理するためのツールキットです。

最初のツール `Get-AppLastSignInByGroup.ps1` は、指定グループのユーザーと、指定アプリケーションのサインインログを突き合わせ、ユーザーごとの最終サインイン日時を管理 CSV に累積します。

> このリポジトリは汎用サンプルです。実在するテナント ID、グループ ID、アプリ ID、ユーザー、ドメイン、社内アプリ名、実ログをコミットしないでください。

## できること

- JSON 設定からテナント、グループ、アプリ、取得期間、出力先を読み込む
- 直接メンバー、またはネストを含む推移的メンバーからユーザーだけを取得する
- 指定したアプリ ID と期間で Microsoft Entra サインインログを取得する
- 既存 CSV とマージし、確認済みの最終日時を失わずに更新する
- 今回の取得範囲で見つかったかを `LastSeenInCurrentRun` に記録する
- 脱退メンバーを保持して `CurrentGroupMember=False` にするか、出力から除外する
- 個人情報を本文に含めない運用ログを出力する

Graph への操作は GET のみです。ローカルでは管理 CSV と実行ログを作成・更新します。

## リポジトリ構成

```text
entra-graph-powershell-toolkit/
├── .github/workflows/powershell.yml
├── config/config.example.json
├── docs/app-last-signin-by-group.md
├── samples/sample-output.csv
├── scripts/Get-AppLastSignInByGroup.ps1
├── tests/Repository.Tests.ps1
├── .gitignore
├── LICENSE
├── PSScriptAnalyzerSettings.psd1
├── README.md
└── SECURITY.md
```

## 推奨環境

- PowerShell 7.2 以降
- Microsoft Graph PowerShell SDK
- Microsoft Entra の職場または学校アカウント
- サインインログを利用できる Microsoft Entra ライセンスと管理ロール

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

## 必要な Microsoft Graph 委任権限

対話実行では次の権限を要求します。

| 権限 | 用途 |
|---|---|
| `AuditLog.Read.All` | サインインログの読み取り |
| `GroupMember.Read.All` | グループおよびメンバーシップの読み取り |
| `User.ReadBasic.All` | メンバーの表示名と UPN など基本プロファイルの読み取り |

`Directory.Read.All` は、より広い権限であり、この実装の必須権限にはしていません。組織の同意ポリシーにより管理者同意が必要です。また、委任権限だけでなく、実行ユーザーにサインインログを読める Microsoft Entra ロール（例: Reports Reader）が必要です。非表示メンバーシップのグループには、追加で `Member.Read.Hidden` と対応ロールが必要です（本スクリプトは既定では要求しません）。

## セットアップ

1. サンプル設定をローカル設定へコピーします。

   ```powershell
   Copy-Item ./config/config.example.json ./config/config.json
   ```

2. `config/config.json` のダミー値を自組織の値へ置換します。このファイルは `.gitignore` 対象です。
3. スクリプトを実行し、表示される Microsoft Graph の対話サインインを完了します。

   ```powershell
   ./scripts/Get-AppLastSignInByGroup.ps1
   ```

別の設定ファイルも指定できます。

```powershell
./scripts/Get-AppLastSignInByGroup.ps1 -ConfigPath ./config/my-app.local.json
```

## 設定

| キー | 説明 |
|---|---|
| `TenantId` | 任意。空ならサインイン時に選択されたテナントを使用 |
| `GroupId` | 対象 Microsoft Entra グループのオブジェクト ID |
| `MembershipMode` | `Transitive`（推奨）または `Direct` |
| `TargetApp.AppId` | サインインログの `appId` と照合するアプリケーション（クライアント）ID |
| `TargetApp.DisplayName` | CSV 表示用ラベル。Graph から検証せず、権限を増やさない |
| `Query.LookbackDays` | 実行時刻から遡る日数（1～366） |
| `Query.SuccessfulSignInsOnly` | `true` なら `status.errorCode == 0` のイベントだけを採用 |
| `Output.CsvPath` | 設定ファイルの場所を基準にした出力先、または絶対パス |
| `Output.RemovedMemberHandling` | `Retain`（推奨）または `Exclude` |
| `Logging.Directory` | 設定ファイルの場所を基準にしたログ先、または絶対パス |
| `Logging.Level` | `Debug`、`Information`、`Warning`、`Error` |

既定の `Transitive` は、ネストされたグループを含む実効メンバーを確認したい用途に向きます。グループ直下の割り当てだけを監査したい場合は `Direct` にします。どちらもユーザー オブジェクトだけを対象にし、デバイス、グループ、サービス プリンシパルは CSV に含めません。

## 重要な意味づけ

- `LastSignInDateTime` は「Entra が保持するログ、かつ本ツールの運用中に確認できた範囲での最新成功サインイン」です。
- 空欄や `LastSeenInCurrentRun=False` は「一度も利用していない」という意味ではありません。
- 既存 CSV の日時と今回取得した日時の新しい方を残します。ログ保持期間を過ぎても、管理 CSV に記録済みの日時は保持されます。
- 既定では成功したサインインのみを利用実績とみなします。失敗した試行も含めたい場合だけ `SuccessfulSignInsOnly` を `false` にしてください。
- `TargetApp.AppId` はサインインログの **Application / App ID** に一致させます。Resource ID やサービス プリンシパルのオブジェクト ID とは別物です。
- サインインログには反映遅延があり得ます。実行直前の利用が直ちに現れるとは限りません。

Microsoft Entra の標準保持期間はライセンスにより異なり、一般に Free は 7 日、P1/P2 は 30 日です。より長い正式な監査要件には、CSV の累積だけに依存せず、診断設定による Azure Storage、Log Analytics、Event Hub 等へのエクスポートを検討してください。

## CSV 出力

| 列 | 意味 |
|---|---|
| `UserPrincipalName` | 現在のユーザー プリンシパル名 |
| `DisplayName` | 現在の表示名 |
| `UserId` | ユーザー オブジェクト ID。マージキー |
| `CurrentGroupMember` | 今回のグループ取得結果に含まれるか |
| `AppDisplayName` | 設定した表示用アプリ名 |
| `AppId` | 照合対象のアプリケーション ID |
| `LastSignInDateTime` | 確認できた最新日時（UTC、ISO 8601）。不明なら空欄 |
| `LastSeenInCurrentRun` | 今回の期間内に対象イベントが見つかったか |
| `LastCheckedDateTime` | 今回の確認日時（UTC、ISO 8601） |
| `Note` | 保持理由や「未利用を意味しない」旨 |

同じ CSV に異なる `AppId` が入っている場合は、誤マージ防止のため停止します。アプリごとに出力ファイルを分けてください。更新は一時ファイル経由で置換し、途中失敗で既存 CSV が半端な状態になりにくくしています。

UPN、表示名、表示用アプリ名が表計算ソフトで数式として解釈される文字（`=`, `+`, `-`, `@` など）から始まる場合は、CSV インジェクション対策として先頭にアポストロフィを付けます。

## 脱退メンバー

既定の `Retain` を推奨します。既存 CSV にいるが現在のグループにいないユーザーを残し、`CurrentGroupMember=False` とします。履歴と説明責任を保ちやすいためです。

`Exclude` は現在のメンバーだけを出力します。CSV から行が消えるため、別の正式な保管先がある場合に限って選ぶのが安全です。

## 制約

- Microsoft Graph が現在返せるサインインログだけを取得します。
- `appId` 単位の集計です。同名アプリやリソース側 ID との取り違えに注意してください。
- サンプルは対話認証専用です。無人実行は実装していません。
- 既存 CSV は列構成と値が正しい前提です。不正日時、重複 UserId、異なる AppId は安全のためエラーにします。
- 非表示グループ、各国クラウド、ゲスト、削除済みユーザーなどは組織のポリシーと Graph の挙動を別途検証してください。

## 将来の無人実行

サービス プリンシパルと証明書認証を利用できますが、アプリケーション権限、管理者同意、証明書の保管・ローテーション、実行基盤の保護、監査ログ、最小権限レビューが必要です。クライアント シークレットを JSON やリポジトリに保存する設計にはしないでください。

## 安全な利用

- CSV は個人情報・利用状況を含みます。アクセス制御された保存先に置き、共有範囲、保持期間、削除手順を定めてください。
- 実データを issue、スクリーンショット、テスト fixture、コミット履歴へ入れないでください。
- 会社向けの設定、README、運用ルール、出力先は社内管理リポジトリで別管理してください。
- AI 生成コードを業務利用する場合は会社規程に従い、人間によるコード、権限、出力内容のレビューとテストを行ってください。

## 開発時のチェック

Pester と PSScriptAnalyzer をインストールして実行できます。GitHub Actions でも同じ基本チェックを行います。

```powershell
Install-Module Pester,PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed
Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

詳細は [docs/app-last-signin-by-group.md](docs/app-last-signin-by-group.md) と [SECURITY.md](SECURITY.md) を参照してください。

## 公式資料

- [List signIns - Microsoft Graph v1.0](https://learn.microsoft.com/graph/api/signin-list?view=graph-rest-1.0)
- [List group transitive members - Microsoft Graph v1.0](https://learn.microsoft.com/graph/api/group-list-transitivemembers?view=graph-rest-1.0)
- [Microsoft Entra data retention](https://learn.microsoft.com/entra/identity/monitoring-health/reference-reports-data-retention)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference)
