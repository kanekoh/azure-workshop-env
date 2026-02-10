# 投入 → 削除の連続ベンチマーク（load で投入した key-0,1,... を delete で削除）
name: datagrid-load-and-delete
agents:
  agent-one: {}
http:
  host: __REST_BASE_URL__
  sharedConnections: __SHARED_CONNECTIONS__
  requestTimeout: 30s
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
      startAfter: load
