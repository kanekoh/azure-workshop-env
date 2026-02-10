# Data Grid リストア CR（プレースホルダ: __RESTORE_NAME__, __BACKUP_NAME__, __CLUSTER_NAME__）
apiVersion: infinispan.org/v2alpha1
kind: Restore
metadata:
  name: __RESTORE_NAME__
  namespace: __NAMESPACE__
spec:
  backup: __BACKUP_NAME__
  cluster: __CLUSTER_NAME__
