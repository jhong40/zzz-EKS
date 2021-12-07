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
```
# cluster.yaml 
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: learnk8s
  region: eu-central-1
nodeGroups:
  - name: worker-group
    instanceType: t2.micro
    desiredCapacity: 3
    minSize: 3
    maxSize: 5
    
 eksctl create cluster -f cluster.yaml
 eksctl get cluster --name learnk8s
```
 
```
## terraform
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install terraform
terraform -help

terraform init
terraform plan
terraform apply
```
 
