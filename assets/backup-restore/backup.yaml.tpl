# Data Grid バックアップ CR（プレースホルダ: __BACKUP_NAME__, __CLUSTER_NAME__, __STORAGE_SIZE__, __STORAGE_CLASS__）
apiVersion: infinispan.org/v2alpha1
kind: Backup
metadata:
  name: __BACKUP_NAME__
  namespace: __NAMESPACE__
spec:
  cluster: __CLUSTER_NAME__
  volume:
    storage: __STORAGE_SIZE__
    storageClassName: __STORAGE_CLASS__
