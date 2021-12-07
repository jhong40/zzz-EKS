## EKS
```
## default: 2 nodes, m5.large, us-west-2

eksctl create cluster \
  --name my-cluster \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 2 \
  --region us-east-1
  
  eksctl get cluster --name learnk8s-cluster --region eu-central-1
  eksctl delete cluster --name learnk8s-cluster --region eu-central-1
  
  
  ```
