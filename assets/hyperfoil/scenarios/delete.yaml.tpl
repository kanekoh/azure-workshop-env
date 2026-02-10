# Hyperfoil データ削除（REST DELETE）
# 削除対象: key-0, key-1, ... key-(session.id)。load で投入したキーを消す。存在しないキーは 404（invalid にしない）
name: datagrid-delete
agents:
  agent-one: {}
http:
  host: __REST_BASE_URL__
  sharedConnections: __SHARED_CONNECTIONS__
  requestTimeout: 30s
  __TRUST_MANAGER_YAML__
phases:
  - delete:
      constantRate:
        usersPerSec: __USERS_PER_SEC__
        maxSessions: __PARALLELISM__
        duration: __DURATION__s
        scenario:
          - delete:
            - httpRequest:
                __REST_AUTH_HEADERS_YAML__
                method: DELETE
                path: /rest/v2/caches/__CACHE_NAME__/key-${hyperfoil.session.id}
                metric: delete
                timeout: 30s
                # 存在しないキーの DELETE は 404 が返るため、4xx を invalid にしない
                handler:
                  autoRangeCheck: false
