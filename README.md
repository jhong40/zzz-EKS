## EKS
```
eksctl create cluster \
  --name my-cluster \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 2 \
  --region us-east-1
  
  ```
