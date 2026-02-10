# Hyperfoil データ投入（REST PUT）
# 形式: phase 名をキーに、constantRate と scenario をネスト
# agents: クラスタモードでは必須（K8s が Pod を起動）
name: datagrid-load
agents:
  agent-one: {}
http:
  host: __REST_BASE_URL__
  sharedConnections: __SHARED_CONNECTIONS__
  requestTimeout: 15s
  __TRUST_MANAGER_YAML__
phases:
  - load:
      constantRate:
        usersPerSec: __USERS_PER_SEC__
        maxSessions: __PARALLELISM__
        duration: __DURATION__s
        scenario:
          - put:
            - httpRequest:
                __REST_AUTH_HEADERS_YAML__
                method: PUT
                path: /rest/v2/caches/__CACHE_NAME__/key-${hyperfoil.session.id}
                body: "__PAYLOAD_PLACEHOLDER__"
                metric: put
