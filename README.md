## EKS
<details>
  <summary>create cluster</summary>
  
```
## default: 2 nodes, m5.large ($0.096), us-west-2

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

terraform init
terraform plan
terraform apply
```

```
git config --global credential.helper store
git clone https://xxx

```

```
## env
export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_REGION=$(aws configure get region)
export AZS=($(aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneName' --output text --region $AWS_REGION))
```

</details>

<details>
  <summary>AutoScaling App and Cluster</summary>
  
### INSTALL KUBE-OPS-VIEW
```
helm install kube-ops-view \
stable/kube-ops-view \
--set service.type=LoadBalancer \
--set rbac.create=True
```
```
helm list
```
```
kubectl get svc kube-ops-view | tail -n 1 | awk '{ print "Kube-ops-view URL = http://"$4 }'
# Kube-ops-view URL = http://<URL_PREFIX_ELB>.amazonaws.com
```
  
### Deploy the Metrics Server
  ```
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.5.0/components.yaml
```
  ```
  kubectl get apiservice v1beta1.metrics.k8s.io -o json | jq '.status'
```
### Deploy Sample App
```
kubectl create deployment php-apache --image=us.gcr.io/k8s-artifacts-prod/hpa-example
kubectl set resources deploy php-apache --requests=cpu=200m
kubectl expose deploy php-apache --port 80

kubectl get pod -l app=php-apache
```
### Create an HPA resource
```
kubectl autoscale deployment php-apache `#The target average CPU utilization` \
    --cpu-percent=50 \
    --min=1 `#The lower limit for the number of pods that can be set by the autoscaler` \
    --max=10 `#The upper limit for the number of pods that can be set by the autoscaler`
kubectl get hpa

```
### Generate load to trigger scaling
```
kubectl run -i --tty load-generator --image=busybox /bin/sh
  while true; do wget -q -O - http://php-apache; done
```
```
kubectl get hpa -w
```
### Configure the ASG
```
## just checking
aws autoscaling \
  describe-auto-scaling-groups \
  --query "AutoScalingGroups[? Tags[? (Key=='eks:cluster-name') && Value=='eksworkshop-eksctl']].[AutoScalingGroupName, MinSize, MaxSize,DesiredCapacity]" \
  --output table
```
```
# we need the ASG name
export ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[? Tags[? (Key=='eks:cluster-name') && Value=='eksworkshop-eksctl']].AutoScalingGroupName" --output text)

# increase max capacity up to 4
aws autoscaling \
    update-auto-scaling-group \
    --auto-scaling-group-name ${ASG_NAME} \
    --min-size 3 \
    --desired-capacity 3 \
    --max-size 4

# Check new values
aws autoscaling \
    describe-auto-scaling-groups \
    --query "AutoScalingGroups[? Tags[? (Key=='eks:cluster-name') && Value=='eksworkshop-eksctl']].[AutoScalingGroupName, MinSize, MaxSize,DesiredCapacity]" \
    --output table
```  
### IAM roles for service accounts
```
  ### Enabling IAM roles for service accounts on your cluster
  eksctl utils associate-iam-oidc-provider \
    --cluster eksworkshop-eksctl \
    --approve
```
### Creating an IAM policy 
```
mkdir ~/environment/cluster-autoscaler

cat <<EoF > ~/environment/cluster-autoscaler/k8s-asg-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeLaunchConfigurations",
                "autoscaling:DescribeTags",
                "autoscaling:SetDesiredCapacity",
                "autoscaling:TerminateInstanceInAutoScalingGroup",
                "ec2:DescribeLaunchTemplateVersions"
            ],
            "Resource": "*",
            "Effect": "Allow"
        }
    ]
}
EoF

aws iam create-policy   \
  --policy-name k8s-asg-policy \
  --policy-document file://~/environment/cluster-autoscaler/k8s-asg-policy.json
```  
### Create 
```
eksctl create iamserviceaccount \
    --name cluster-autoscaler \
    --namespace kube-system \
    --cluster eksworkshop-eksctl \
    --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/k8s-asg-policy" \
    --approve \
    --override-existing-serviceaccounts
```
```
kubectl -n kube-system describe sa cluster-autoscaler
```  
### Deploy the Cluster Autoscaler
```
kubectl apply -f https://www.eksworkshop.com/beginner/080_scaling/deploy_ca.files/cluster-autoscaler-autodiscover.yaml
kubectl -n kube-system \
    annotate deployment.apps/cluster-autoscaler \
    cluster-autoscaler.kubernetes.io/safe-to-evict="false"
```
```
# we need to retrieve the latest docker image available for our EKS version
export K8S_VERSION=$(kubectl version --short | grep 'Server Version:' | sed 's/[^0-9.]*\([0-9.]*\).*/\1/' | cut -d. -f1,2)
export AUTOSCALER_VERSION=$(curl -s "https://api.github.com/repos/kubernetes/autoscaler/releases" | grep '"tag_name":' | sed -s 's/.*-\([0-9][0-9\.]*\).*/\1/' | grep -m1 ${K8S_VERSION})

kubectl -n kube-system \
    set image deployment.apps/cluster-autoscaler \
    cluster-autoscaler=us.gcr.io/k8s-artifacts-prod/autoscaling/cluster-autoscaler:v${AUTOSCALER_VERSION}
```
```
kubectl -n kube-system logs -f deployment/cluster-autoscaler
```
### Deploy a Sample App
```
cat <<EoF> ~/environment/cluster-autoscaler/nginx.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-to-scaleout
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        service: nginx
        app: nginx
    spec:
      containers:
      - image: nginx
        name: nginx-to-scaleout
        resources:
          limits:
            cpu: 500m
            memory: 512Mi
          requests:
            cpu: 500m
            memory: 512Mi
EoF

kubectl apply -f ~/environment/cluster-autoscaler/nginx.yaml
kubectl get deployment/nginx-to-scaleout
```
```
kubectl scale --replicas=10 deployment/nginx-to-scaleout
kubectl get pods -l app=nginx -o wide --watch
```
```
kubectl -n kube-system logs -f deployment/cluster-autoscaler
```
```
kubectl get nodes
```

### CLEANUP SCALING
```
kubectl delete -f ~/environment/cluster-autoscaler/nginx.yaml

kubectl delete -f https://www.eksworkshop.com/beginner/080_scaling/deploy_ca.files/cluster-autoscaler-autodiscover.yaml

eksctl delete iamserviceaccount \
  --name cluster-autoscaler \
  --namespace kube-system \
  --cluster eksworkshop-eksctl \
  --wait

aws iam delete-policy \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/k8s-asg-policy

export ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[? Tags[? (Key=='eks:cluster-name') && Value=='eksworkshop-eksctl']].AutoScalingGroupName" --output text)

aws autoscaling \
  update-auto-scaling-group \
  --auto-scaling-group-name ${ASG_NAME} \
  --min-size 3 \
  --desired-capacity 3 \
  --max-size 3

kubectl delete hpa,svc php-apache

kubectl delete deployment php-apache

kubectl delete pod load-generator

cd ~/environment

rm -rf ~/environment/cluster-autoscaler

kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.4.1/components.yaml

kubectl delete ns metrics

helm uninstall kube-ops-view

unset ASG_NAME
unset AUTOSCALER_VERSION
unset K8S_VERSION

```

###############################################AutoScaling
  
</details>

<details>
  <summary>AUTOSCALING WITH KARPENTER</summary>
  
### Environment Variables
```
export KARPENTER_VERSION=v0.16.0

export CLUSTER_NAME=$(eksctl get clusters -o json | jq -r '.[0].Name')
export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_REGION=$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
```
  

###############################################KARPENTER  
</details>  
  

<details>
  <summary>RBAC</summary>

### Install Test Pod  
```
kubectl create namespace rbac-test
kubectl create deploy nginx --image=nginx -n rbac-test
kubectl get all -n rbac-test 
```
### Create User
```
aws iam create-user --user-name rbac-user
aws iam create-access-key --user-name rbac-user | tee /tmp/create_output.json
```
```
cat << EoF > rbacuser_creds.sh
export AWS_SECRET_ACCESS_KEY=$(jq -r .AccessKey.SecretAccessKey /tmp/create_output.json)
export AWS_ACCESS_KEY_ID=$(jq -r .AccessKey.AccessKeyId /tmp/create_output.json)
EoF
```  
### MAP AN IAM USER TO K8S  
```
kubectl get configmap -n kube-system aws-auth -o yaml | grep -v "creationTimestamp\|resourceVersion\|selfLink\|uid" | sed '/^  annotations:/,+2 d' > aws-auth.yaml
```
  
vi aws-auth.yaml   # add the following
(arn:aws:iam => arn:aws-us-gov:iam)
```  
data:
  mapUsers: |
    - userarn: arn:aws:iam::${ACCOUNT_ID}:user/rbac-user       
      username: rbac-user
```

```  
cat aws-auth.yaml
kubectl apply -f aws-auth.yaml
kubectl get configmap -n kube-system aws-auth -o yaml   
```  
### TEST THE NEW USER
```
. rbacuser_creds.sh
aws sts get-caller-identity
kubectl get pods -n rbac-test  # pod forbiden  
```  
### CREATE THE ROLE AND BINDING  
```
unset AWS_SECRET_ACCESS_KEY
unset AWS_ACCESS_KEY_ID
aws sts get-caller-identity   #gliu
  
cat << EoF > rbacuser-role.yaml
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: rbac-test
  name: pod-reader
rules:
- apiGroups: [""] # "" indicates the core API group
  resources: ["pods"]
  verbs: ["list","get","watch"]
- apiGroups: ["extensions","apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
EoF

cat << EoF > rbacuser-role-binding.yaml
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: read-pods
  namespace: rbac-test
subjects:
- kind: User
  name: rbac-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EoF

kubectl apply -f rbacuser-role.yaml
kubectl apply -f rbacuser-role-binding.yaml
```  
### VERIFY THE ROLE AND BINDING
```
. rbacuser_creds.sh; aws sts get-caller-identity
kubectl get pods -n rbac-test    # 2work
kubectl get pods -n kube-system  # not work 
  
```  
### Cleanup
```
unset AWS_SECRET_ACCESS_KEY
unset AWS_ACCESS_KEY_ID
kubectl delete namespace rbac-test
rm rbacuser_creds.sh
rm rbacuser-role.yaml
rm rbacuser-role-binding.yaml
aws iam delete-access-key --user-name=rbac-user --access-key-id=$(jq -r .AccessKey.AccessKeyId /tmp/create_output.json)
aws iam delete-user --user-name rbac-user
rm /tmp/create_output.json
```  
Remove this part from aws-auth.yaml
```
  mapUsers: |
    []
```  
```
kubectl apply -f aws-auth.yaml
rm aws-auth.yaml
 
```  
  
############################################### RBAC  
</details>  
  


<details>
  <summary>USING IAM GROUPS TO MANAGE KUBERNETES CLUSTER ACCESS</summary>
  
  ### CREATE IAM ROLES (arn:aws -> arn:aws-us-gov)
```
  export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export POLICY=$(echo -n '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws-us-gov:iam::'; echo -n "$ACCOUNT_ID"; echo -n ':root"},"Action":"sts:AssumeRole","Condition":{}}]}')

echo ACCOUNT_ID=$ACCOUNT_ID
echo POLICY=$POLICY

aws iam create-role \
  --role-name k8sAdmin \
  --description "Kubernetes administrator role (for AWS IAM Authenticator for Kubernetes)." \
  --assume-role-policy-document "$POLICY" \
  --output text \
  --query 'Role.Arn'

aws iam create-role \
  --role-name k8sDev \
  --description "Kubernetes developer role (for AWS IAM Authenticator for Kubernetes)." \
  --assume-role-policy-document "$POLICY" \
  --output text \
  --query 'Role.Arn'
  
aws iam create-role \
  --role-name k8sInteg \
  --description "Kubernetes role for integration namespace in quick cluster." \
  --assume-role-policy-document "$POLICY" \
  --output text \
  --query 'Role.Arn'
```
### CREATE IAM GROUPS
```
aws iam create-group --group-name k8sAdmin
ADMIN_GROUP_POLICY=$(echo -n '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAssumeOrganizationAccountRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws-us-gov:iam::'; echo -n "$ACCOUNT_ID"; echo -n ':role/k8sAdmin"
    }
  ]
}')
echo ADMIN_GROUP_POLICY=$ADMIN_GROUP_POLICY

aws iam put-group-policy \
--group-name k8sAdmin \
--policy-name k8sAdmin-policy \
--policy-document "$ADMIN_GROUP_POLICY"
  
  
aws iam create-group --group-name k8sDev
DEV_GROUP_POLICY=$(echo -n '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAssumeOrganizationAccountRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws-us-gov:iam::'; echo -n "$ACCOUNT_ID"; echo -n ':role/k8sDev"
    }
  ]
}')
echo DEV_GROUP_POLICY=$DEV_GROUP_POLICY

aws iam put-group-policy \
--group-name k8sDev \
--policy-name k8sDev-policy \
--policy-document "$DEV_GROUP_POLICY"
  
  
aws iam create-group --group-name k8sInteg
INTEG_GROUP_POLICY=$(echo -n '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAssumeOrganizationAccountRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws-us-gov:iam::'; echo -n "$ACCOUNT_ID"; echo -n ':role/k8sInteg"
    }
  ]
}')
echo INTEG_GROUP_POLICY=$INTEG_GROUP_POLICY

aws iam put-group-policy \
--group-name k8sInteg \
--policy-name k8sInteg-policy \
--policy-document "$INTEG_GROUP_POLICY"
  
```
```
aws iam list-groups
```  
### CREATE IAM USERS
```
aws iam create-user --user-name PaulAdmin
aws iam create-user --user-name JeanDev
aws iam create-user --user-name PierreInteg

aws iam add-user-to-group --group-name k8sAdmin --user-name PaulAdmin
aws iam add-user-to-group --group-name k8sDev --user-name JeanDev
aws iam add-user-to-group --group-name k8sInteg --user-name PierreInteg

aws iam get-group --group-name k8sAdmin
aws iam get-group --group-name k8sDev
aws iam get-group --group-name k8sInteg 
```
```
aws iam create-access-key --user-name PaulAdmin | tee /tmp/PaulAdmin.json
aws iam create-access-key --user-name JeanDev | tee /tmp/JeanDev.json
aws iam create-access-key --user-name PierreInteg | tee /tmp/PierreInteg.json
```

### CONFIGURE KUBERNETES RBAC
```
kubectl create namespace integration
kubectl create namespace development 
```  
```
cat << EOF | kubectl apply -f - -n development
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: dev-role
rules:
  - apiGroups:
      - ""
      - "apps"
      - "batch"
      - "extensions"
    resources:
      - "configmaps"
      - "cronjobs"
      - "deployments"
      - "events"
      - "ingresses"
      - "jobs"
      - "pods"
      - "pods/attach"
      - "pods/exec"
      - "pods/log"
      - "pods/portforward"
      - "secrets"
      - "services"
    verbs:
      - "create"
      - "delete"
      - "describe"
      - "get"
      - "list"
      - "patch"
      - "update"
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: dev-role-binding
subjects:
- kind: User
  name: dev-user
roleRef:
  kind: Role
  name: dev-role
  apiGroup: rbac.authorization.k8s.io
EOF
```  
```
cat << EOF | kubectl apply -f - -n integration
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: integ-role
rules:
  - apiGroups:
      - ""
      - "apps"
      - "batch"
      - "extensions"
    resources:
      - "configmaps"
      - "cronjobs"
      - "deployments"
      - "events"
      - "ingresses"
      - "jobs"
      - "pods"
      - "pods/attach"
      - "pods/exec"
      - "pods/log"
      - "pods/portforward"
      - "secrets"
      - "services"
    verbs:
      - "create"
      - "delete"
      - "describe"
      - "get"
      - "list"
      - "patch"
      - "update"
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: integ-role-binding
subjects:
- kind: User
  name: integ-user
roleRef:
  kind: Role
  name: integ-role
  apiGroup: rbac.authorization.k8s.io
EOF
```
### CONFIGURE KUBERNETES ROLE ACCESS
```
eksctl create iamidentitymapping \
  --cluster eksworkshop-eksctl \
  --arn arn:aws:iam::${ACCOUNT_ID}:role/k8sDev \
  --username dev-user

eksctl create iamidentitymapping \
  --cluster eksworkshop-eksctl \
  --arn arn:aws:iam::${ACCOUNT_ID}:role/k8sInteg \
  --username integ-user

eksctl create iamidentitymapping \
  --cluster eksworkshop-eksctl \
  --arn arn:aws:iam::${ACCOUNT_ID}:role/k8sAdmin \
  --username admin \
  --group system:masters

kubectl get cm -n kube-system aws-auth -o yaml
eksctl get iamidentitymapping --cluster eksworkshop-eksctl
```
### TEST EKS ACCESS
```
mkdir -p ~/.aws

cat << EoF >> ~/.aws/config
[profile admin]
role_arn=arn:aws-us-gov:iam::${ACCOUNT_ID}:role/k8sAdmin
source_profile=eksAdmin

[profile dev]
role_arn=arn:aws-us-gov:iam::${ACCOUNT_ID}:role/k8sDev
source_profile=eksDev

[profile integ]
role_arn=arn:aws-us-gov:iam::${ACCOUNT_ID}:role/k8sInteg
source_profile=eksInteg

EoF

cat << EoF >> ~/.aws/credentials

[eksAdmin]
aws_access_key_id=$(jq -r .AccessKey.AccessKeyId /tmp/PaulAdmin.json)
aws_secret_access_key=$(jq -r .AccessKey.SecretAccessKey /tmp/PaulAdmin.json)

[eksDev]
aws_access_key_id=$(jq -r .AccessKey.AccessKeyId /tmp/JeanDev.json)
aws_secret_access_key=$(jq -r .AccessKey.SecretAccessKey /tmp/JeanDev.json)

[eksInteg]
aws_access_key_id=$(jq -r .AccessKey.AccessKeyId /tmp/PierreInteg.json)
aws_secret_access_key=$(jq -r .AccessKey.SecretAccessKey /tmp/PierreInteg.json)

EoF
```
```
aws sts get-caller-identity --profile dev
aws sts get-caller-identity --profile admin
```
### With dev profile
```
export KUBECONFIG=/tmp/kubeconfig-dev && eksctl utils write-kubeconfig --cluster eksworkshop-eksctl
cat $KUBECONFIG | yq e '.users.[].user.exec.args += ["--profile", "dev"]' - -- | sed 's/eksworkshop-eksctl./eksworkshop-eksctl-dev./g' | sponge $KUBECONFIG

kubectl run nginx-dev --image=nginx -n development
kubectl get pods -n integration  # pods is forbidden: User "dev-user" cannot list resource
```
### Test with integ profile
```
export KUBECONFIG=/tmp/kubeconfig-integ && eksctl utils write-kubeconfig --cluster=eksworkshop-eksctl
cat $KUBECONFIG | yq e '.users.[].user.exec.args += ["--profile", "integ"]' - -- | sed 's/eksworkshop-eksctl./eksworkshop-eksctl-integ./g' | sponge $KUBECONFIG

kubectl run nginx-integ --image=nginx -n integration  #work
kubectl get pods -n development  # should not working
 
```  
### Test with admin profile
```
export KUBECONFIG=/tmp/kubeconfig-admin && eksctl utils write-kubeconfig --cluster=eksworkshop-eksctl
cat $KUBECONFIG | yq e '.users.[].user.exec.args += ["--profile", "admin"]' - -- | sed 's/eksworkshop-eksctl./eksworkshop-eksctl-admin./g' | sponge $KUBECONFIG
kubectl run nginx-admin --image=nginx  #work
kubectl get pods -A  #work
  
```  
############################################### IAM group to manager kube  
</details>  



<details>
  <summary>EFS</summary>
  
```
## EFS
CLUSTER_NAME=eksworkshop-eksctl
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text)
CIDR_BLOCK=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query "Vpcs[].CidrBlock" --output text)
MOUNT_TARGET_GROUP_NAME="eks-efs-group"
MOUNT_TARGET_GROUP_DESC="NFS access to EFS from EKS worker nodes"
MOUNT_TARGET_GROUP_ID=$(aws ec2 create-security-group --group-name $MOUNT_TARGET_GROUP_NAME --description "$MOUNT_TARGET_GROUP_DESC" --vpc-id $VPC_ID --output json | jq --raw-output '.GroupId')
aws ec2 authorize-security-group-ingress --group-id $MOUNT_TARGET_GROUP_ID --protocol tcp --port 2049 --cidr $CIDR_BLOCK

FILE_SYSTEM_ID=$(aws efs create-file-system --output json | jq --raw-output '.FileSystemId')

TAG1=tag:alpha.eksctl.io/cluster-name
TAG2=tag:kubernetes.io/role/elb
subnets=($(aws ec2 describe-subnets --filters "Name=$TAG1,Values=$CLUSTER_NAME" "Name=$TAG2,Values=1" --out json| jq --raw-output '.Subnets[].SubnetId'))
for subnet in ${subnets[@]}
do
    echo "creating mount target in " $subnet
    aws efs create-mount-target --file-system-id $FILE_SYSTEM_ID --subnet-id $subnet --security-groups $MOUNT_TARGET_GROUP_ID
done

aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID --output json | jq --raw-output '.MountTargets[].LifeCycleState'

```
</details>
  
<details>
  <summary>Load Balancer</summary>  
  
```
## AWS Load balancer controller"

helm upgrade -i aws-load-balancer-controller \
    eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=eksworkshop-eksctl \
     --set serviceAccount.create=false \
     --set serviceAccount.name=aws-load-balancer-controller \
     --set image.repository=013241004608.dkr.ecr.us-gov-west-1.amazonaws.com/amazon/aws-load-balancer-controller
```
</details>
