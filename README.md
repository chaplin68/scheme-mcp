# scheme-mcp

> Xcode プロジェクトのビルド・実行・テストを、Model Context Protocol 越しにエージェントへ渡す。

Claude Code のような生成 AI エージェントが、あなたの Xcode プロジェクトをビルドし、シミュレータや実機で動かし、テストを走らせ、失敗の理由を読めるようにします。

人間が使う画面はありません。MCP サーバーそのものです。

---

## ⚡ 3つの特徴

**待たせません。** ビルドは即座にジョブ ID を返します。数分かかる処理でも、ツール呼び出しがタイムアウトしません。

**溢れさせません。** 数千行の `xcodebuild` 出力を、エラー全文と警告の件数に絞って返します。生ログはディスクに残ります。

**バイナリ1つです。** 常駐サービスもデーモンも要りません。クライアントが子プロセスとして起動します。

---

## 📦 インストール

macOS 13 以降が必要です。

ビルドには Swift 6.0 以降のツールチェーンが要ります。`swift --version` で確認できます。

実機を扱うには `devicectl` を使うので、Xcode 15 以降も必要です。

```sh
git clone <this repo> && cd scheme-mcp
swift build -c release
cp .build/release/scheme-mcp /usr/local/bin/
```

---

## 🔌 接続する

### Claude Code

```sh
claude mcp add --scope user --transport stdio scheme-mcp \
  -- /usr/local/bin/scheme-mcp --root /path/to/your/project
```

### 設定ファイルに直接書く場合

`command` と `args` を受け取るクライアントなら、どれでも同じ形です。

```json
{
  "command": "/usr/local/bin/scheme-mcp",
  "args": ["--root", "/path/to/your/project"]
}
```

`--root` には対象プロジェクトのディレクトリを渡します。省略するとサーバーが起動されたディレクトリが対象になりますが、それはクライアント次第なので、明示するほうが確実です。

プロジェクトは `--root` から上に辿って探すので、サブディレクトリを渡しても見つかります。

---

## 🧰 ツール

| ツール | 内容 |
| --- | --- |
| `list_devices` | シミュレータと接続中の実機。`ready` フラグつき |
| `list_schemes` | スキーム一覧。最有力のものが先頭 |
| `build` / `test` / `run` | 処理を開始し、**ジョブ ID** を返す |
| `job_status` | 状態、エラー全文、警告数、生ログのパス |
| `job_log` | 生出力の末尾。`contains` で絞り込める |
| `cancel_job` | 実行中のジョブを止める |

`build` `test` `run` は `device` と `scheme` を取ります。`device` は `list_devices` が返す UDID か、セレクタです。

| セレクタ | 意味 |
| --- | --- |
| `auto`（既定） | 接続中の実機 → 起動中のシミュレータ → 最新のシミュレータ |
| `sim` `sim-iphone` `sim-ipad` `sim-watch` | シミュレータ |
| `iphone` `ipad` `watch` `device` | 接続中の実機 |
| `mac` | My Mac |

セレクタが指す種類の端末が無いときは、何も選ばずに失敗します。`sim-ipad` に iPhone を返すようなことはしません。

---

## ⚙️ 設定

すべて自動で判別するので、設定ファイルは任意です。

固定したい場合は、プロジェクトルートに `.scheme-mcp.json` を置きます。

```json
{
  "workspace": "MyApp.xcworkspace",
  "scheme": "MyApp",
  "configuration": "Debug",
  "derivedDataPath": "DerivedData",
  "testPlan": "MyAppTests"
}
```

ツール呼び出しで `scheme` を渡せば、その都度上書きできます。

`testPlan` は `test` のときだけ `xcodebuild -testPlan` に渡ります。

無加工の `xcodebuild` ログは `~/Library/Caches/scheme-mcp/logs/` に残り、そのパスを `job_status` が `log_path` で返します。リポジトリは汚しません。

---

## 🧭 設計

**ジョブは1件ずつ実行します。** 同じ DerivedData への同時ビルドや、同一デバイスへの同時インストールは壊れるためです。待たされているジョブは、自分が誰の後ろにいるかを `queued_behind` で返します。

**`run` はアプリが生きている間ずっと `running` です。** `job_log` がそのままコンソール出力のライブビューになります。

**結果は蒸留して返します。** ツールの結果にはトークン上限があるため、`job_status` が返すのはエラー全文と警告数だけです。警告は同じものが `xcodebuild` のパスごとに再出力されるので、重複を除いた件数を返します。

**外部と通信しません。** ネットワーク API を一切使わず、起動する外部プロセスは `xcodebuild` と `xcrun` だけです。stdio 以外の口を開きません。

### 構成

```
Sources/SchemeMCP/
├── Core/   プロセス実行、プロジェクト探索、デバイス一覧、ログ解析
└── MCP/    ジョブ管理、ツール定義
```

解析は純粋関数で1行ずつ処理するので、ビルドを走らせずに単体テストできます。

---

## ✅ テスト

```sh
swift test
```

検証するのは次の5つです。

- xcodebuild 出力の解析
- デバイス選択の規則
- プロジェクトと設定ファイルの探索
- スキームの順位付け
- ジョブの状態遷移とキューの見え方

実際に `xcodebuild` を起動する経路は対象外なので、そこは手で動かして確認してください。

---

## 🙏 由来

[porunga](https://github.com/chaplin68/porunga) から MCP 部分だけを取り出したものです。porunga は同じ処理を TUI と CLI からも扱えますが、エージェントに渡すだけならこちらで足ります。

---

## 📄 ライセンス

MIT。[LICENSE](LICENSE) を参照してください。
