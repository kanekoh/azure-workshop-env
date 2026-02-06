# Azure Red Hat OpenShift (ARO) Workshop Environment

このリポジトリは、Azure Red Hat OpenShift (ARO) を使用して「MTA for Developer Lightspeed」ワークショップ用の環境を構築するためのものです。

## 概要

このプロジェクトは、AWS/ROSA用の [mta-workshop-env](https://github.com/kanekoh/mta-workshop-env) と同等の構成をAzure/AROで実現します。

### 構成

- **Terraform**: 2フェーズ構成
  - フェーズ1: ネットワーク（VNet、サブネット、NSG等）
  - フェーズ2: AROクラスター構築
- **Ansible**: クラスター構築後の設定
  - HTPasswd IDP設定、ワークショップユーザー作成
  - OpenShift GitOps (ArgoCD) のインストール・設定
  - ConfigMap/Secret設定（Azure Managed Identity対応）
- **GitOps (ArgoCD)**: App-of-AppsパターンでOperatorと環境別リソースを管理

## 前提条件

以下のツールがインストールされている必要があります：

- `terraform` (>= 1.0)
- `az` (Azure CLI)
- `oc` (OpenShift CLI)
- `ansible` (>= 2.9)
- `jq` (JSON処理用)
- `htpasswd` (HTPasswd IDP用)

### Azure認証

#### Option 1: Red Hat Demo Platform (RHDP) 変数名を使用（推奨）

RHDPから変数をコピペするだけで使用できます：

```bash
export CLIENT_ID="<client-id>"
export PASSWORD="<client-secret>"
export TENANT="<tenant-id-or-domain>"  # テナントID（GUID）またはドメイン名（例: redhat0.onmicrosoft.com）
export SUBSCRIPTION="<subscription-id>"
export RESOURCEGROUP="<resource-group-name>"
export GUID="<guid>"  # オプション: リソース名生成用
```

これらの変数は自動的に`ARM_*`変数にマッピングされ、Terraformで使用されます。**`az login`は不要です。**

#### Option 2: ARM_*変数名を使用

```bash
export ARM_SUBSCRIPTION_ID="<subscription-id>"
export ARM_TENANT_ID="<tenant-id>"
export ARM_CLIENT_ID="<client-id>"
export ARM_CLIENT_SECRET="<client-secret>"
```

#### Option 3: Azure CLI認証

Service Principalを使用しない場合は、Azure CLIで認証を行います：

```bash
az login
az account set --subscription <subscription-id>
```

### Azure リソースプロバイダーの登録

AROクラスターを作成する前に、以下のリソースプロバイダーを登録する必要があります：

```bash
az provider register -n Microsoft.RedHatOpenShift --wait
az provider register -n Microsoft.Compute --wait
az provider register -n Microsoft.Storage --wait
az provider register -n Microsoft.Authorization --wait
```

### ARO リソースプロバイダーの権限

AROのリソースプロバイダー(Service Principal)にVNetへの権限が必要です。  
このリポジトリでは`terraform/network`でVNetに`Network Contributor`を付与します。

環境によってはAzure ADの参照権限がない場合があるため、その場合は
`aro_rp_service_principal_object_id`を`terraform/network/terraform.tfvars`に指定してください。

### vCPU クォータの確認

AROクラスターには最小40 vCPUが必要です。クォータを確認します：

```bash
az vm list-usage --location japaneast --output table
```

クォータが不足している場合は、Azure Portalまたはサポートにクォータ引き上げをリクエストしてください。

## セットアップ

### 1. 環境変数の設定

`env.sh.example`をコピーして`env.sh`を作成し、必要な値を設定します：

```bash
cp env.sh.example env.sh
# env.shを編集
```

主要な環境変数：

- **Azure認証（RHDP変数名）**: `CLIENT_ID`, `PASSWORD`, `TENANT`, `SUBSCRIPTION`, `RESOURCEGROUP`, `GUID`
  - または **ARM_*変数名**: `ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`
- **リソース設定**: `AZURE_RESOURCE_GROUP` (または `RESOURCEGROUP`), `AZURE_REGION`, `AZURE_VNET_NAME`
- **クラスター設定**: `ARO_CLUSTER_NAME`, `ARO_OCP_VERSION`, `ARO_MASTER_VM_SIZE`, `ARO_WORKER_VM_SIZE`
- **GitOps設定**: `GITOPS_ENV` (例: `mta_aro`)
- **Ansible設定**: `RUN_ANSIBLE` (true/false)

### 2. Ansibleコレクションのインストール

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

## デプロイ

### 自動デプロイ

`deploy.sh`スクリプトを使用して、ネットワークとクラスターを自動的に構築します：

```bash
./deploy.sh
```

このスクリプトは以下の処理を実行します：

1. 環境変数の読み込み（RHDP変数名を`ARM_*`変数に自動マッピング）
2. Azure認証確認（Service Principalが設定されている場合は`az login`不要）
3. Phase 1: ネットワーク構築
4. Phase 2: AROクラスター構築
5. クラスターアクセス確認
6. `cluster_info.json`の生成
7. Ansible実行（`RUN_ANSIBLE=true`の場合）

### 手動デプロイ

#### Phase 1: ネットワーク構築

```bash
cd terraform/network
terraform init
terraform plan
terraform apply
```

#### Phase 2: AROクラスター構築

Phase 1の出力を`terraform/cluster/terraform.tfvars`に設定します：

```bash
cd terraform/cluster
terraform init
terraform plan
terraform apply
```

#### Ansible実行

```bash
cd ansible
ansible-playbook -i inventory/cluster_info.json site.yml
```

## 削除

### 自動削除

`destroy.sh`スクリプトを使用して、クラスターとネットワークを削除します：

```bash
./destroy.sh
```

このスクリプトは以下の順序で削除を実行します：

1. Phase 1: AROクラスター削除（20-40分かかる場合があります）
2. クラスター削除完了待機
3. Phase 2: ネットワーク削除

### 手動削除

```bash
# Phase 1: クラスター削除
cd terraform/cluster
terraform destroy

# クラスター削除完了を確認
az aro show --name <cluster-name> --resource-group <resource-group>

# Phase 2: ネットワーク削除（クラスター削除完了後）
cd ../network
terraform destroy
```

⚠️ **重要**: ネットワークリソースは、AROクラスターが完全に削除されるまで保持されます。

## クラスターへのアクセス

### 認証情報の取得

```bash
az aro list-credentials --name <cluster-name> --resource-group <resource-group>
```

### OpenShift CLIでのログイン

```bash
API_URL=$(az aro show --name <cluster-name> --resource-group <resource-group> --query apiserverProfile.url -o tsv)
ADMIN_USER=$(az aro list-credentials --name <cluster-name> --resource-group <resource-group> --query kubeadminUsername -o tsv)
ADMIN_PASSWORD=$(az aro list-credentials --name <cluster-name> --resource-group <resource-group> --query kubeadminPassword -o tsv)

oc login $API_URL -u $ADMIN_USER -p $ADMIN_PASSWORD --insecure-skip-tls-verify
```

### Webコンソールへのアクセス

```bash
CONSOLE_URL=$(az aro show --name <cluster-name> --resource-group <resource-group> --query consoleProfile.url -o tsv)
echo "Console URL: $CONSOLE_URL"
```

## GitOps (ArgoCD)

OpenShift GitOps (ArgoCD) がインストールされると、以下のApplicationSetが自動的にOperatorと環境別リソースを管理します：

- **Operators**: NFD, NVIDIA, OpenShift AI, Authorino, DevSpaces, CNPG, Keycloak, MTA
- **Environments**: `mta_aro`環境用のApplication定義

### ArgoCDコンソールへのアクセス

```bash
# ArgoCD admin passwordを取得
oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' | base64 -d

# ArgoCDコンソールURL
echo "https://openshift-gitops-server-openshift-gitops.apps.<cluster-domain>"
```

## トラブルシューティング

### AROクラスターの状態確認

```bash
az aro show --name <cluster-name> --resource-group <resource-group>
az aro list --resource-group <resource-group>
```

### Terraform状態の確認

```bash
cd terraform/cluster
terraform state list
terraform state show <resource_name>
```

### クラスター接続エラー

- クラスターが完全にプロビジョニングされるまで待機（30-60分）
- ネットワークセキュリティグループの設定を確認
- APIサーバーのURLが正しいか確認

### Ansible実行エラー

- `cluster_info.json`が正しく生成されているか確認
- OpenShift CLI (`oc`) がインストールされているか確認
- クラスターへの接続が確立されているか確認

### リソースプロバイダーエラー

```bash
# リソースプロバイダーの状態を確認
az provider show -n Microsoft.RedHatOpenShift

# 再登録
az provider register -n Microsoft.RedHatOpenShift --wait
```

### vCPUクォータエラー

```bash
# クォータを確認
az vm list-usage --location <region> --output table

# クォータ引き上げをリクエスト（Azure Portal経由）
```

## プロジェクト構成

```
.
├── README.md                     # このファイル
├── deploy.sh                     # 環境構築スクリプト（2フェーズ）
├── destroy.sh                    # 環境削除スクリプト（2フェーズ）
├── env.sh.example                # 環境変数設定例
├── terraform/                    # Terraform設定
│   ├── network/                 # ネットワークリソース（フェーズ1）
│   │   ├── versions.tf
│   │   ├── variables.tf
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── terraform.tfvars.example
│   └── cluster/                 # AROクラスター（フェーズ2）
│       ├── versions.tf
│       ├── variables.tf
│       ├── main.tf
│       ├── outputs.tf
│       └── terraform.tfvars.example
├── ansible/                      # Ansible設定
│   ├── site.yml                  # メインPlaybook
│   ├── requirements.yml          # Ansibleコレクション
│   ├── inventory/                # インベントリ（cluster_info.jsonが生成される）
│   └── roles/
│       ├── openshift_idp/        # HTPasswd IDP設定
│       ├── openshift_gitops/      # OpenShift GitOps設定
│       └── openshift_config/      # ConfigMap/Secret設定
└── gitops/                       # GitOps設定（ArgoCD用）
    ├── applicationsets/          # ApplicationSet定義
    │   ├── operators/            # Operator用ApplicationSet
    │   └── environments/         # 環境用ApplicationSet
    ├── operators/                # Operatorマニフェスト
    │   ├── nfd-operator/
    │   ├── nvidia-operator/
    │   ├── odh-operator/
    │   ├── authorino-operator/
    │   ├── devspaces-operator/
    │   ├── cnpg-operator/
    │   ├── keycloak-operator/
    │   └── mta-operator/
    └── environments/             # 環境別設定
        └── mta_aro/              # ARO環境
            ├── apps/             # Application定義
            └── resources/         # 環境別リソース
```

## AWS/ROSAとの主な違い

- **認証**: AWS CLI/ROSA CLI → Azure CLI (`az login`)
- **Terraform Provider**: AWS Provider/RHCS Provider → Azure Provider (`azurerm`)
- **ネットワーク**: VPC → VNet、AWS Subnet → Azure Subnet
- **IAM**: AWS IAM Role ARN → Azure Managed Identity/Service Principal
- **クラスター作成**: `rosa create cluster` → `azurerm_redhat_openshift_cluster`

## 参考リンク

- [Azure Red Hat OpenShift Documentation](https://learn.microsoft.com/ja-jp/azure/openshift/)
- [Terraform Azure Provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
- [Red Hat OpenShift Documentation](https://docs.redhat.com/ja/documentation/openshift_container_platform/)
- [Konveyor MTA](https://www.konveyor.io/)

## ライセンス

MIT License

## サポート

問題が発生した場合は、Issueを作成してください。
