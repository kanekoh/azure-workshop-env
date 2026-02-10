# Data Grid ワークショップ用アセット

OpenShift 上で Red Hat Data Grid の Operator インストール、クラスタデプロイ、性能測定（Hyperfoil）、バックアップ・リストアおよびメトリクス収集を行うためのスクリプトとマニフェストです。

---

## 使い方

### 実行のしかた（どこからでも実行可能）

**ディレクトリを移動しなくてよい**ように、`assets` 直下の **`run.sh`** をエントリポイントとして使います。リポジトリルートや任意の場所から実行できます。

```bash
# リポジトリルートやどこからでも
./assets/run.sh operators install-all
./assets/run.sh datagrid deploy --replicas 5
./assets/run.sh hyperfoil load --records 100000 --parallelism 4
./assets/run.sh backup --cluster infinispan
./assets/run.sh restore --backup backup-20250209-120000 --cluster infinispan
./assets/run.sh metrics --output-dir ./my-metrics
```

ヘルプ: `./assets/run.sh --help`

各サブディレクトリ内のスクリプトを直接実行しても同じです（その場合は `cd assets/operators` などでディレクトリに移動してから実行）。

---

### 再実行について（何度でも実行できる）

| 操作 | 再実行 | 説明 |
|------|--------|------|
| **Operator インストール** | ✅ 可能 | Data Grid は**バージョンを変えて再実行**できる。環境変数で `DATAGRID_OPERATOR_VERSION=8.5.6` を指定して再実行すると、Subscription が更新され該当バージョンに更新される。Hyperfoil は既にインストール済みならスキップ。 |
| **DataGrid インスタンスのデプロイ** | ✅ 可能 | **同じクラスタ名・namespace で再実行すると、version や replicas が更新**される。`oc apply` で既存の Infinispan CR を上書きするため、設定変更したいときにそのまま再実行してよい。 |
| バックアップ・リストア | 都度新規 | Backup/Restore CR は 1 回ごとに別名で作成する運用。 |

例: Data Grid Operator のバージョンを 8.5.6 にしたい場合

```bash
DATAGRID_OPERATOR_VERSION=8.5.6 ./assets/run.sh operators install-datagrid
```

例: 既存の DataGrid クラスタのレプリカを 5 に変更したい場合

```bash
./assets/run.sh datagrid deploy --replicas 5
```

---

### 前提条件

- OpenShift クラスタに `oc` でログイン済みであること
- 必要に応じて `source assets/config/defaults.env` でデフォルト値を読み込む（任意）

---

### 手順 1: Operator のインストール

Data Grid Operator（バージョン指定可、デフォルト 8.5.7）と Hyperfoil Operator（最新）をインストールします。  
**Hyperfoil は Operator インストール時にコントローラー用インスタンス（Hyperfoil CR）もデプロイ**するため、そのままベンチマーク実行が可能です。  
**いずれもマニュアルインストール（InstallPlan 手動承認）**のため、勝手にアップグレードされません。

```bash
# run.sh で（どこからでも）
./assets/run.sh operators install-all
```

**Data Grid Operator のみ・バージョン指定する場合**

```bash
./assets/run.sh operators install-datagrid
# またはバージョン指定（再実行でバージョン変更可能）
DATAGRID_OPERATOR_VERSION=8.5.6 ./assets/run.sh operators install-datagrid
```

**Hyperfoil Operator のみ**（インストール時にコントローラー用インスタンスもデプロイ）

```bash
./assets/run.sh operators install-hyperfoil
```

**従来どおりサブディレクトリから実行する場合**

```bash
cd assets/operators
./install-all.sh
# または
DATAGRID_OPERATOR_VERSION=8.5.6 ./install-datagrid-operator.sh
```

インストール完了後、`oc get csv -n openshift-operators` で CSV が Succeeded になるまで待ちます。

---

### 手順 2: DataGrid インスタンスのデプロイ

Infinispan CR をパラメタ付きでデプロイします。**再実行すると同じ CR が更新されます**（version や replicas を変えて再実行可能）。

```bash
# run.sh で（どこからでも）
./assets/run.sh datagrid deploy
./assets/run.sh datagrid deploy --version 8.5.4-1 --replicas 5
./assets/run.sh datagrid deploy --namespace my-datagrid --replicas 3 --cluster-name mycluster
./assets/run.sh datagrid deploy --no-auth
./assets/run.sh datagrid deploy --no-tls    # エンドポイント TLS 無効（簡易動作確認・デバッグ用のみ。**性能検証では使用しないこと**）
./assets/run.sh datagrid deploy --dry-run   # 適用せず YAML のみ表示
```

**従来どおりサブディレクトリから実行する場合**

```bash
cd assets/datagrid
./deploy-datagrid.sh --version 8.5.4-1 --replicas 5
```

クラスタが Ready になるまで待ちます。`oc get pods -n datagrid` で Pod を確認してください。

---

### 手順 3: Hyperfoil によるデータ投入・削除（性能測定）

#### 性能検証は本番と同一構成で行うこと

**性能検証は本番と同じ構成・設定で行わないと意味がありません。** Data Grid は **TLS 有効**（Operator デフォルト）のままデプロイし、Hyperfoil は **https** で Data Grid REST に接続して測定してください。

- **Data Grid**: `--no-tls` は**簡易動作確認・デバッグ用のみ**。性能検証時は付けず、TLS 有効のままにすること。
- **Hyperfoil**: クラスタ内 URL はデフォルトで **https**（本番相当）。HTTPS 接続では Data Grid の証明書を信頼する必要があるため、**Agent Pod に Data Grid の CA/証明書をマウント**し、`--trust-ca-path` でそのパスを指定してください（例: `--trust-ca-path /etc/ssl/datagrid-ca/tls.crt`）。Route 経由の場合は多くの環境で公開 CA のため `--trust-ca-path` が不要な場合があります。

#### Hyperfoil を実行する前に

**手順 1** で `operators install-hyperfoil`（または `install-all`）を実行すると、**Operator のインストールとあわせて Hyperfoil コントローラー用インスタンス（Hyperfoil CR）もデプロイ**されます（Data Grid と同様）。追加の手順は不要です。

1. **Operator ＋ インスタンスのインストール**（手順 1 で実施）
   ```bash
   ./assets/run.sh operators install-hyperfoil
   # または
   ./assets/run.sh operators install-all
   ```
2. **コントローラーと Route の準備を待つ**（数十秒程度）
   ```bash
   oc get route -n hyperfoil
   oc get hf -n hyperfoil
   ```
3. その後、`run-benchmark.sh` を実行すると **Controller の URL は自動検出**されます（`--hyperfoil-url` は通常不要）。  
   検出されない場合は `oc get route -n hyperfoil` の HOST/PORT を確認し、`--hyperfoil-url https://<その値>` を付けて実行してください。

---

レコード数・データ量（ペイロードサイズ）・並列度を指定して、データ投入（PUT）や削除（DELETE）のベンチマークを実行できます。

```bash
# run.sh で（どこからでも）
./assets/run.sh hyperfoil load --records 100000 --payload-bytes 1024 --parallelism 4
./assets/run.sh hyperfoil delete --records 100000 --parallelism 4
./assets/run.sh hyperfoil load-del --records 50000 --payload-bytes 512 --parallelism 8 --duration 60
```

**主なオプション**

| オプション | 説明 | 例 |
|-----------|------|-----|
| `--records N` | レコード数（負荷の目安） | `--records 100000` |
| `--payload-bytes N` | 1 レコードあたりのバイト数 | `--payload-bytes 1024` |
| `--parallelism N` | 並列度（同時セッション数） | `--parallelism 8` |
| `--duration N` | フェーズ実行時間（秒） | `--duration 60` |
| `--cache-name NAME` | キャッシュ名 | `--cache-name benchmark` |
| `--rest-url URL` | Data Grid REST のベース URL | 未指定時は Route があればそれを使用、なければクラスタ内 Service URL（Route は必須ではない） |
| `--output-dir DIR` | 生成ベンチマーク YAML の保存先 | `--output-dir ./out` |
| `--hyperfoil-url URL` | Hyperfoil Controller API | 未指定時は namespace hyperfoil の Route から自動検出（インスタンス未デプロイなら YAML のみ生成） |
| `--rest-user USER` / `--rest-password PW` | Data Grid REST 認証 | 未指定時は Infinispan CR の `status.security.endpointSecretName` または `${CLUSTER_NAME}-generated-secret` から自動取得。認証ありで「invalid response」になる場合はここで指定するか `DATAGRID_REST_USER` / `DATAGRID_REST_PASSWORD` を設定。 |
| `--keep-agents` | Agent ログ確認用 | 指定すると Run 終了後も Agent Pod を停止しない。`oc get pods -n hyperfoil` で Pod を確認し `oc logs <pod名> -n hyperfoil` でログを確認できる。 |
| `--trust-ca-path PATH` | HTTPS 用 CA/証明書パス（**本番相当の性能検証で必須**） | Agent **内**のファイルパス。Data Grid の証明書または Service CA を Agent にマウントしたパスを指定する（例: `/etc/ssl/datagrid-ca/tls.crt`）。未指定だと HTTPS 接続で証明書検証に失敗する場合がある。 |
| `--check` | 診断のみ（原因追求用） | アップロード・Run 開始は行わず、REST URL・認証の有無・生成 YAML の要約・ログ確認用コマンドを表示する。 |

**Run の確認**: `hyperfoil load` / `delete` / `load-del` はベンチマークを Controller に登録し、Run を**開始**した時点でスクリプトは終了します（完了を待ちません）。登録ベンチマーク一覧と Run の状態・統計を確認するには `./assets/run.sh hyperfoil status` を実行してください。特定の Run の詳細は `--run-id 0000` で指定できます。Run が完了すると `status` で統計（リクエスト数・レイテンシ等）が表示されます。

#### レポートの確認方法（Hyperfoil）

1. **Run 一覧と統計を表示する**
   ```bash
   ./assets/run.sh hyperfoil status
   ```
   - 登録ベンチマーク一覧、Run 一覧（id / benchmark / started / terminated / status）、先頭 Run の詳細が表示されます。
   - Run が **TERMINATED** のときは、その Run の **統計**（リクエスト数・2xx 数・errors・平均レイテンシ・p50/p99）が続けて表示されます。

2. **特定の Run のレポートだけ見る**
   ```bash
   ./assets/run.sh hyperfoil status --run-id 0000
   ```
   - Run ID は `hyperfoil load` 実行時に表示されます（例: `Run ID: 0000`）。別ターミナルで `status` を実行したときの一覧でも確認できます。

3. **表示しているメトリクス**: 各 phase/metric ごとに `requests`（送信数）、`2xx`/`3xx`/`4xx`/`5xx`、`errors`、`timeouts`、`blockedTime`（接続待ち時間 ms）を表示します。`responseCounts` に 2xx/4xx/5xx 以外のキーがあればそのまま表示します。

4. **requests はあるが 2xx/4xx/5xx/errors がすべて 0 のとき**: リクエストは送られたが、**完了したレスポンスが 1 件も記録されていない**状態です（接続が返ってこない・タイムアウト・サーバーが接続を閉じる等）。このとき status は「レスポンス未カウント」の注釈を出します。**全メトリクス（生 JSON）**は `curl -s -k <Controller_URL>/run/<RunID>/stats/total | jq .` で確認できます。

5. **Controller UI で見る（ブラウザ）**
   - Route の URL を開く: `oc get route hyperfoil -n hyperfoil -o jsonpath='{.status.ingress[0].host}'` で得たホストに `https://<そのホスト>` でアクセスします。
   - Run を選ぶと統計やグラフが表示されます。

#### Data Grid のデータ格納状況の確認

ベンチマークで投入したデータがキャッシュに格納されているかは、Data Grid の REST API で確認できます。認証が必要な場合は `-u user:password` を付けてください。

**手早く確認する**: 次のコマンドで、キャッシュのエントリ数と Hyperfoil が使うキー（key-0, key-1, ...）の有無を一括表示できます（REST URL と認証はベンチマークと同様に自動解決します）。

```bash
./assets/run.sh datagrid cache-status
./assets/run.sh datagrid cache-status --cache-name benchmark
```

- **Route について**: `datagrid cache-status` は**手元のマシン**から Data Grid に curl するため、Route が無いとクラスタ内 URL に届かず失敗します。その場合は Data Grid の Route を作成するか、port-forward して `--rest-url https://localhost:11222` を指定してください。**hyperfoil load/delete** は Agent がクラスタ内で実行するため、**Route は不要**です（未指定時はクラスタ内 URL が使われ、Agent から届きます）。
- **認証・証明書**: 未指定時は Data Grid の **Secret** から取得します。認証は `infinispan-generated-secret` 等（run-benchmark.sh と同じ）、証明書は **OpenShift serving certificate** を格納した Secret（`<cluster>-cert-secret` または Infinispan CR の `spec.security.endpointEncryption.certSecretName`）の `tls.crt` を使用し、HTTPS で接続する際に curl の `--cacert` で検証します。port-forward で localhost に接続する場合は証明書の CN が一致しないため `-k` で接続します。
- **port-forward で接続できない場合**: (1) 別ターミナルで `oc port-forward svc/<クラスタ名> -n <namespace> 11222:11222` を実行しているか確認（クラスタ名は Infinispan CR の名前、デフォルトは `infinispan`）。(2) `oc get svc -n datagrid` で 11222 を公開している Service を確認。(3) 接続失敗時はスクリプトが curl のエラーを表示するので、「Connection refused」なら port-forward 未実行またはポート違い、「SSL」なら証明書の話を確認。

**Hyperfoil が扱うキー**: load は **PUT** `/rest/v2/caches/<キャッシュ名>/key-${hyperfoil.session.id}` で投入します（key-0, key-1, key-2, ...）。delete は **DELETE** で同じパスを削除します。したがって「load のみ」を実行するとキャッシュに key-0, key-1, ... が残り、「delete のみ」を実行するとそれらのキーが無いため 404 になります。「load-del」は投入後に同じキーを削除する流れです。データが残っているか・何を消しているかは `datagrid cache-status` で確認できます。

**データを確実に全件クリアしたい場合**: Hyperfoil の delete は key-0, key-1, … を個別に DELETE するため、セッション上限や 404 の扱いの影響を受けます。**キャッシュ内のデータを確実に全件削除**するには、Data Grid の REST API の clear を使います。1 回の API 呼び出しで完了します。
```bash
./assets/run.sh datagrid clear-cache
./assets/run.sh datagrid clear-cache --cache-name benchmark
```
（認証・URL は cache-status と同様に Secret から取得。Route が無い場合は --rest-url で port-forward 先を指定。）

**delete でデータは消えているか**: はい。削除対象は **key-0 ～ key-(並列セッション数-1)** です。各キーに対する **1 回目の DELETE で 2xx（削除成功）**、同じキーへの 2 回目以降は **404（もともと無い＝削除済み**）になります。404 はシナリオで「invalid」にしていないため、セッションは止まらずベンチマークは継続します。**タイムアウト**が出る場合は Data Grid の負荷で応答が遅れている可能性があります。DELETE 用シナリオでは requestTimeout/ timeout を 30s にしているため、それでもタイムアウトする場合は `--duration` を短くして負荷を下げるか、Data Grid 側の負荷・ネットワークを確認してください。`hyperfoil status` の **timeouts** が 0 ならタイムアウトは発生していません。

1. **キャッシュ一覧**
   ```bash
   # Route 経由（クラスタ外から）
   curl -s -k -u "USER:PASSWORD" "https://$(oc get route -n datagrid -o jsonpath='{.items[0].status.ingress[0].host}')/rest/v2/caches"
   # クラスタ内で実行する場合（Pod から）
   oc run curl --rm -it --restart=Never --image=curlimages/curl -- \
     curl -s -k -u "USER:PASSWORD" "https://infinispan.datagrid.svc.cluster.local:11222/rest/v2/caches"
   ```

2. **特定キャッシュのエントリ数・統計**
   ```bash
   # キャッシュ "benchmark" の統計（number_of_entries 等）
   curl -s -k -u "USER:PASSWORD" "https://<REST_URL>/rest/v2/caches/benchmark?action=stats"
   ```
   - `<REST_URL>` は Route のホストまたは `infinispan.datagrid.svc.cluster.local:11222`（クラスタ内のみ）。
   - 認証情報は `oc get secret infinispan-generated-secret -n datagrid -o jsonpath='{.data.username}' | base64 -d` 等で取得するか、`--rest-user` / `--rest-password` で使っている値を指定します。

3. **キーの存在確認（サンプル）**
   ```bash
   curl -s -k -u "USER:PASSWORD" "https://<REST_URL>/rest/v2/caches/benchmark/key-1"
   ```
   - 存在すれば値が返り、なければ 404 です。

**注意**: ベンチマークで使うキャッシュは、事前に Data Grid で作成しておいてください。クラスタ内 URL を使う場合、Data Grid Operator は REST を**ポート 11222**で **TLS 有効**で公開します。デフォルトでクラスタ内 URL は **https**（本番相当）です。Hyperfoil などベンチマーク実行元は**クラスタ内**にあり、**本番相当の性能検証では `--trust-ca-path` で Data Grid 証明書を Agent にマウントしたパスを指定**してください。Data Grid で**エンドポイント認証が有効**な場合、REST には Basic 認証が必要です。スクリプトは未指定時に Operator が作成した Secret から認証情報を自動取得し、ベンチマークに `Authorization: Basic ...` を付与します。自動取得できない場合は `--rest-user` / `--rest-password` または環境変数で指定してください。

**「invalid response」で size=0・接続が即 CLOSED になる場合**: REST が **https** で待ち受けており、クライアントが証明書を信頼していないと発生します。

**Agent ログで「received invalid status 401」になる場合**: Data Grid の**認証エラー**です。認証情報がベンチマークに含まれていません。スクリプト実行時に「Using Data Grid REST credentials」と出ていなければ、Secret から取得できていません。`--rest-user` / `--rest-password` を明示指定するか、`oc get secret <cluster>-generated-secret -n <namespace> -o yaml` で Secret の存在と `username`/`password`（または `identities`）を確認してください。生成 YAML に Authorization ヘッダが入っているかは `--output-dir` で保存して確認できます。

- **本番相当の性能検証**: Data Grid は TLS 有効のままにし、**Hyperfoil Agent に Data Grid の CA/証明書（Secret の `tls.crt` や Service CA）をボリュームマウント**して、`--trust-ca-path <Agent 内パス>` を指定してください。これで HTTPS で接続でき、本番と同じ構成で測定できます。
- **簡易動作確認・デバッグのみ**: Data Grid を **`--no-tls` 付きでデプロイ**すると平文 HTTP で待ち受けるため、証明書不要で繋げます。**性能検証には使用しないでください。**

**ベンチマークが動かない場合の原因追求**

1. **診断モード**で設定と生成 YAML を確認する（アップロード・Run 開始は行わない）:
   ```bash
   ./assets/run.sh hyperfoil load --check
   ```
   - Data Grid REST URL・認証の有無・trust-ca-path・生成 YAML の `http` とリクエスト部分が表示される。
   - 認証が「未取得」なら 401 の原因。`from Secret ... (key: ...)` と出ていればどのキーから取得したか分かる。
2. **Agent ログ**で実際のエラーを確認する（401 / 証明書エラー / 接続拒否など）:
   ```bash
   oc logs -n hyperfoil -l app.kubernetes.io/name=hyperfoil-agent -c agent --tail=100
   ```
3. **Controller ログ**で Agent 登録や Run の状態を確認する（例: "agent-one is not starting", "Not a member of the cluster"）:
   ```bash
   oc logs -n hyperfoil -l app=hyperfoil -c controller --tail=100
   ```
4. **Secret のキー一覧**で認証が取れない理由を確認する（`username` / `identities.yaml` / `identities-batch` など）:
   ```bash
   oc get secret infinispan-generated-secret -n datagrid -o jsonpath='{.data}' | jq -r 'keys[]'
   ```

#### キャッシュの準備と性能測定時の考慮点

ベンチマーク結果の再現性と解釈のために、キャッシュには次の点を考慮してください。

| 項目 | 考慮点・性能への影響 |
|------|----------------------|
| **キャッシュモード** | **distributed**（分散）はスケールしやすく PUT/GET がノード間で分散される。**replicated**（レプリカ）は全ノードに同じデータを持つため読み取りは速いが、書き込み時は全ノードへ伝搬し負荷が増える。性能測定の目的に合わせて選択する。 |
| **owners（コピー数）** | 分散キャッシュの `owners`（numOwners）を大きくすると可用性は上がるが、書き込み時に複数ノードへ伝搬するためスループットは下がりやすい。ベンチマークでは `2` 程度がよく使われる。 |
| **segments** | 分散キャッシュのセグメント数。デフォルトのままでよいことが多い。キー偏りが強い場合はセグメント数やキー設計を見直すとホットスポットを防げる。 |
| **エビクション・有効期限** | 測定中にエントリがエビクトや期限切れで消えると、DELETE 数や GET のヒット率が想定とずれる。**純粋なスループット測定**ではエビクション・有効期限を**無効**にしたキャッシュを使うと結果が分かりやすい。 |
| **永続化（cache store）** | 永続化を有効にするとディスク I/O が効いてくる。**メモリのみ**のキャッシュと**永続化あり**では性能が大きく変わるため、測定目的に応じて使い分ける。 |
| **統計** | `statistics: true` にすると Data Grid 側のヒット数・ミス数・レイテンシ・**エントリ数**を取得できる。**無効（デフォルトや未設定）だと REST の stats で `current_number_of_entries` が -1 になり、エントリ数が「不明」になる。** ベンチマーク用キャッシュでは `datagrid/cache-benchmark.yaml` のように `statistics: "true"` を入れておくと、`datagrid cache-status` でエントリ数を確認できる。メトリクス収集と合わせて分析する場合も有効にしておく。 |
| **メモリ・ヒープ** | 投入するデータ量（レコード数 × ペイロードサイズ）がクラスタのメモリを超えるとエビクションや OOM の原因になる。事前に必要な容量を見積もる。 |

ベンチマーク用のサンプル Cache CR（分散・同期・owners=2・エビクションなし）は `datagrid/cache-benchmark.yaml` を参照し、`oc apply -f` で作成できます。キャッシュ名は `run-benchmark.sh` の `--cache-name`（デフォルト `benchmark`）と合わせてください。

---

### 手順 4: バックアップ・リストア

#### バックアップの実行

```bash
./assets/run.sh backup
./assets/run.sh backup --cluster infinispan --namespace datagrid --storage 2Gi
./assets/run.sh backup --name my-backup --storage-class standard
```

**オプション**: `--cluster`, `--namespace`, `--name`, `--storage`, `--storage-class`

#### リストアの実行

```bash
./assets/run.sh restore --backup <Backup CR の名前> --cluster <Infinispan CR 名>
# 例
./assets/run.sh restore --backup backup-20250209-120000 --cluster infinispan --namespace datagrid
```

**オプション**: `--backup`（必須）, `--cluster`, `--namespace`, `--name`

バックアップ・リストア実行前には、クライアント接続を切っておくことが推奨されます。

---

### 手順 5: メトリクス収集（バックアップ/リストアの分析用）

```bash
./assets/run.sh metrics --output-dir ./metrics-$(date +%Y%m%d-%H%M%S)
./assets/run.sh metrics --output-dir ./metrics-run --interval 30 --iterations 10
```

**オプション**: `--output-dir`, `--namespace`, `--cluster`, `--interval`, `--iterations`

収集結果は `backup-restore-crs*.json`、`pod-metrics*.txt`、`summary*.txt` などに保存されます。

---

## 設定のカスタマイズ

`config/defaults.env` にデフォルト値が定義されています。環境変数で上書きするか、ファイルを編集してから `source` してください。

```bash
source assets/config/defaults.env

# 例: 上書き
export DATAGRID_OPERATOR_VERSION=8.5.6
export DATAGRID_CLUSTER_VERSION=8.5.4-1
export DATAGRID_REPLICAS=5
export DATAGRID_NAMESPACE=my-datagrid
```

---

## トラブルシューティング

### Hyperfoil Agent: "Failed to register: NO_HANDLERS" / "TIMEOUT"

Agent が Controller に登録できず `NO_HANDLERS` や `TIMEOUT` を繰り返す場合、**Controller 側に「いま実行中の Run」が存在しない**状態です。

- **NO_HANDLERS**: Controller に、この Agent を受け付ける Run 用ハンドラがない（Run が未開始・終了済み・Controller 再起動で消失など）。
- **TIMEOUT**: 上記のまま登録を繰り返し、やがてタイムアウト。

**対処（Controller の再起動は不要）**

1. その Agent Pod は**過去の Run 用で残っているだけ**なので削除してよい。
   ```bash
   # 該当 Agent Pod を削除（例: agent-0008-agent-one など Run 用 Pod）
   oc delete pod -n hyperfoil -l app.kubernetes.io/name=hyperfoil-agent
   # または特定 Pod のみ
   oc delete pod agent-0008-agent-one-xxxxx -n hyperfoil
   ```
2. **あらためてベンチマークを開始**する。Run 開始と同時に Operator が新しい Agent を立て、その Run 用ハンドラに登録される。
   ```bash
   ./assets/run.sh hyperfoil load --records 10000
   ```

Run 開始前に Agent が先に立ち上がって「Run がない」状態で NO_HANDLERS になることもあります。その場合は Run 開始後しばらく待つか、上記のとおり Agent を消してから再度 `hyperfoil load` を実行してください。

---

## ディレクトリ構成

```
assets/
├── README.md                 # 本ファイル（使い方）
├── run.sh                    # 統一エントリポイント（どこからでも実行可）
├── config/
│   └── defaults.env         # デフォルト値（上書き可能）
├── operators/                # 1. Operator インストール（再実行でバージョン変更可）
│   ├── install-datagrid-operator.sh
│   ├── install-hyperfoil-operator.sh
│   └── install-all.sh
├── datagrid/                 # 2. DataGrid インスタンスデプロイ（再実行で設定更新可）
│   ├── infinispan-base.yaml
│   ├── cache-benchmark.yaml  # ベンチマーク用キャッシュのサンプル Cache CR
│   └── deploy-datagrid.sh
├── hyperfoil/                # 3. Hyperfoil によるデータ投入・削除
│   ├── hyperfoil-instance.yaml  # コントローラー用 Hyperfoil CR（要デプロイ）
│   ├── scenarios/
│   │   ├── load.yaml.tpl
│   │   ├── delete.yaml.tpl
│   │   └── load-and-delete.yaml.tpl
│   └── run-benchmark.sh
├── backup-restore/           # 4. バックアップ・リストア
│   ├── backup.yaml.tpl
│   ├── restore.yaml.tpl
│   ├── run-backup.sh
│   └── run-restore.sh
└── metrics/                  # メトリクス収集（バックアップ/リストア分析用）
    └── collect-metrics.sh
```
