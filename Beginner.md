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
### Switching between different contexts
```
export KUBECONFIG=/tmp/kubeconfig-dev:/tmp/kubeconfig-integ:/tmp/kubeconfig-admin
curl -sSLO https://raw.githubusercontent.com/ahmetb/kubectx/master/kubectx && chmod 755 kubectx && sudo mv kubectx /usr/local/bin
kubectx

```
############################################### IAM group to manager kube  
</details>  

<details>
  <summary>IAM ROLES FOR SERVICE ACCOUNTS (IRSA)</summary>

### Prepair  
```
kubectl version --short  #>1.16
aws --version  #>1.19.122

# Retrieve OpenID Connect issuer URL    
aws eks describe-cluster --name eksworkshop-eksctl --query cluster.identity.oidc.issuer --output text    
```
### CREATE AN OIDC IDENTITY PROVIDER
```
eksctl version  # > 0.57.0
eksctl utils associate-iam-oidc-provider --cluster eksworkshop-eksctl --approve    
```    
### CREATING AN IAM ROLE FOR SERVICE ACCOUNT
```
aws iam list-policies --query 'Policies[?PolicyName==`AmazonS3ReadOnlyAccess`].Arn'
eksctl create iamserviceaccount \
    --name iam-test \
    --namespace default \
    --cluster eksworkshop-eksctl \
    --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
    --approve \
    --override-existing-serviceaccounts  
```  
### SPECIFYING AN IAM ROLE FOR SERVICE ACCOUNT
```
kubectl get sa iam-test
kubectl describe sa iam-test 
```  
### DEPLOY SAMPLE POD
- job-s3.yaml: that will output the result of the command aws s3 ls (this job should be successful).
- job-ec2.yaml: that will output the result of the command aws ec2 describe-instances --region ${AWS_REGION} (this job should failed).  
#### List S3 bucket  
```
aws s3 mb s3://eksworkshop-$ACCOUNT_ID-$AWS_REGION --region $AWS_REGION
  
mkdir ~/environment/irsa

cat <<EoF> ~/environment/irsa/job-s3.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: eks-iam-test-s3
spec:
  template:
    metadata:
      labels:
        app: eks-iam-test-s3
    spec:
      serviceAccountName: iam-test
      containers:
      - name: eks-iam-test
        image: amazon/aws-cli:latest
        args: ["s3", "ls"]
      restartPolicy: Never
EoF
  
kubectl apply -f ~/environment/irsa/job-s3.yaml
kubectl get job -l app=eks-iam-test-s3
kubectl logs -l app=eks-iam-test-s3  
```  
#### List EC2 Instances
```
cat <<EoF> ~/environment/irsa/job-ec2.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: eks-iam-test-ec2
spec:
  template:
    metadata:
      labels:
        app: eks-iam-test-ec2
    spec:
      serviceAccountName: iam-test
      containers:
      - name: eks-iam-test
        image: amazon/aws-cli:latest
        args: ["ec2", "describe-instances", "--region", "${AWS_REGION}"]
      restartPolicy: Never
  backoffLimit: 0
EoF

kubectl apply -f ~/environment/irsa/job-ec2.yaml

kubectl get job -l app=eks-iam-test-ec2
kubectl logs -l app=eks-iam-test-ec2   #sholdnot work
  
```  
#### Cleanup
```
kubectl delete -f ~/environment/irsa/job-s3.yaml
kubectl delete -f ~/environment/irsa/job-ec2.yaml

eksctl delete iamserviceaccount \
    --name iam-test \
    --namespace default \
    --cluster eksworkshop-eksctl \
    --wait

rm -rf ~/environment/irsa/  
aws s3 rb s3://eksworkshop-$ACCOUNT_ID-$AWS_REGION --region $AWS_REGION --force
```  
############################################### IRSA     
</details>
    
<details>
<summary>SECURITY GROUPS FOR PODS</summary>
### Security groups for pods are supported by most Nitro-based Amazon EC2 instance families, including the m5, c5, r5, p3, m6g, c6g, and r6g instance families. The t3 instance family is not supported and so we will create a second NodeGroup using one m5.large instance.
 
```
mkdir ${HOME}/environment/sg-per-pod

cat << EoF > ${HOME}/environment/sg-per-pod/nodegroup-sec-group.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: eksworkshop-eksctl
  region: ${AWS_REGION}

managedNodeGroups:
- name: nodegroup-sec-group
  desiredCapacity: 1
  instanceType: m5.large
EoF

eksctl create nodegroup -f ${HOME}/environment/sg-per-pod/nodegroup-sec-group.yaml

 kubectl get nodes \
  --selector node.kubernetes.io/instance-type=m5.large
```
```
export VPC_ID=$(aws eks describe-cluster \
    --name eksworkshop-eksctl \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)

# create RDS security group
aws ec2 create-security-group \
    --description 'RDS SG' \
    --group-name 'RDS_SG' \
    --vpc-id ${VPC_ID}

# save the security group ID for future use
export RDS_SG=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=RDS_SG Name=vpc-id,Values=${VPC_ID} \
    --query "SecurityGroups[0].GroupId" --output text)

echo "RDS security group ID: ${RDS_SG}"
```
```
# create the POD security group
aws ec2 create-security-group \
    --description 'POD SG' \
    --group-name 'POD_SG' \
    --vpc-id ${VPC_ID}

# save the security group ID for future use
export POD_SG=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=POD_SG Name=vpc-id,Values=${VPC_ID} \
    --query "SecurityGroups[0].GroupId" --output text)

echo "POD security group ID: ${POD_SG}"
```  
```
export NODE_GROUP_SG=$(aws ec2 describe-security-groups \
    --filters Name=tag:Name,Values=eks-cluster-sg-eksworkshop-eksctl-* Name=vpc-id,Values=${VPC_ID} \
    --query "SecurityGroups[0].GroupId" \
    --output text)
echo "Node Group security group ID: ${NODE_GROUP_SG}"

# allow POD_SG to connect to NODE_GROUP_SG using TCP 53
aws ec2 authorize-security-group-ingress \
    --group-id ${NODE_GROUP_SG} \
    --protocol tcp \
    --port 53 \
    --source-group ${POD_SG}

# allow POD_SG to connect to NODE_GROUP_SG using UDP 53
aws ec2 authorize-security-group-ingress \
    --group-id ${NODE_GROUP_SG} \
    --protocol udp \
    --port 53 \
    --source-group ${POD_SG}
  
```
  
```
# Cloud9 IP
export C9_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
export C9_IP=public-ip  ### this box
  
# allow Cloud9 to connect to RDS
aws ec2 authorize-security-group-ingress \
    --group-id ${RDS_SG} \
    --protocol tcp \
    --port 5432 \
    --cidr ${C9_IP}/32

# Allow POD_SG to connect to the RDS
aws ec2 authorize-security-group-ingress \
    --group-id ${RDS_SG} \
    --protocol tcp \
    --port 5432 \
    --source-group ${POD_SG}
```  
### RDS CREATION
```
export PUBLIC_SUBNETS_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=eksctl-eksworkshop-eksctl-cluster/SubnetPublic*" \
    --query 'Subnets[*].SubnetId' \
    --output json | jq -c .)

# create a db subnet group
aws rds create-db-subnet-group \
    --db-subnet-group-name rds-eksworkshop \
    --db-subnet-group-description rds-eksworkshop \
    --subnet-ids ${PUBLIC_SUBNETS_ID}
# get RDS SG ID
export RDS_SG=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=RDS_SG Name=vpc-id,Values=${VPC_ID} \
    --query "SecurityGroups[0].GroupId" --output text)

# generate a password for RDS
export RDS_PASSWORD="$(date | md5sum  |cut -f1 -d' ')"
echo ${RDS_PASSWORD}  > ~/environment/sg-per-pod/rds_password


# create RDS Postgresql instance
aws rds create-db-instance \
    --db-instance-identifier rds-eksworkshop \
    --db-name eksworkshop \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --db-subnet-group-name rds-eksworkshop \
    --vpc-security-group-ids $RDS_SG \
    --master-username eksworkshop \
    --publicly-accessible \
    --master-user-password ${RDS_PASSWORD} \
    --backup-retention-period 0 \
    --allocated-storage 20  
```  
```
## Wait for a few min make sure the DB is available  
aws rds describe-db-instances \
    --db-instance-identifier rds-eksworkshop \
    --query "DBInstances[].DBInstanceStatus" \
    --output text
```
```
# get RDS endpoint
export RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier rds-eksworkshop \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)

echo "RDS endpoint: ${RDS_ENDPOINT}"
```
### Create table  
```
cd ~/environment/sg-per-pod/sg-per-pod

cat << EoF > ~/environment/sg-per-pod/pgsql.sql
CREATE TABLE welcome (column1 TEXT);
insert into welcome values ('--------------------------');
insert into welcome values ('Welcome to the eksworkshop');
insert into welcome values ('--------------------------');
EoF

export RDS_PASSWORD=$(cat ~/environment/sg-per-pod/rds_password)

psql postgresql://eksworkshop:${RDS_PASSWORD}@${RDS_ENDPOINT}:5432/eksworkshop \
    -f ~/environment/sg-per-pod/pgsql.sql
```  
### CNI CONFIGURATION (*** ENABLE_POD_ENI=true on aws-node daemon set ***)
```
### IAM Role -> search 'eks' -> select eksctl-eksworkshop-eksctl-nodegro-NodeInstanceRole-xxx -> check tag -> find nodegroup-sec-group -> good one
export ROLE_NAME=eksctl-eksworkshop-eksctl-nodegro-NodeInstanceRole-IM1FA4ZJF4MT  
aws iam attach-role-policy \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSVPCResourceController \
    --role-name ${ROLE_NAME}
  
```  
```
kubectl -n kube-system set env daemonset aws-node ENABLE_POD_ENI=true

# let's wait for the rolling update of the daemonset
kubectl -n kube-system rollout status ds aws-node
```
```
 kubectl get nodes \
  --selector  eks.amazonaws.com/nodegroup=nodegroup-sec-group \
  --show-labels

 ## has-trunke-attached=true  
```  
### SECURITYGROUP POLICY
```
## verifiy the SecurityGroupPolicy CRD   
kubectl get crd securitygrouppolicies.vpcresources.k8s.aws  
```  
```
cat << EoF > ~/environment/sg-per-pod/sg-policy.yaml
apiVersion: vpcresources.k8s.aws/v1beta1
kind: SecurityGroupPolicy
metadata:
  name: allow-rds-access
spec:
  podSelector:
    matchLabels:
      app: green-pod
  securityGroups:
    groupIds:
      - ${POD_SG}
EoF
  
kubectl create namespace sg-per-pod
kubectl -n sg-per-pod apply -f ~/environment/sg-per-pod/sg-policy.yaml
kubectl -n sg-per-pod describe securitygrouppolicy
  
```
### PODS DEPLOYMENTS
```
export RDS_PASSWORD=$(cat ~/environment/sg-per-pod/rds_password)

export RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier rds-eksworkshop \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)

kubectl create secret generic rds\
    --namespace=sg-per-pod \
    --from-literal="password=${RDS_PASSWORD}" \
    --from-literal="host=${RDS_ENDPOINT}"

kubectl -n sg-per-pod describe  secret rds

cd ~/environment/sg-per-pod

curl -s -O https://www.eksworkshop.com/beginner/115_sg-per-pod/deployments.files/green-pod.yaml
curl -s -O https://www.eksworkshop.com/beginner/115_sg-per-pod/deployments.files/red-pod.yaml

```
### Deploy Green Pod  
```  
kubectl -n sg-per-pod apply -f ~/environment/sg-per-pod/green-pod.yaml
kubectl -n sg-per-pod rollout status deployment green-pod

export GREEN_POD_NAME=$(kubectl -n sg-per-pod get pods -l app=green-pod -o jsonpath='{.items[].metadata.name}')
kubectl -n sg-per-pod  logs -f ${GREEN_POD_NAME}  # should see 'Welcome to the eksworkshop'
```
```  
kubectl -n sg-per-pod  describe pod $GREEN_POD_NAME | head -11   
## nnotations: vpc.amazonaws.com/pod-eni: [{"eniId":"eni0cd582c35b2ea798c","ifAddress":"06:3d:84:b5:cc:3e","privateIp":"192.168.27.99","vlanId":1,"subnetCidr":"192.168.0.0/19"}]  
```  
### Deploy Red Pod
```
kubectl -n sg-per-pod apply -f ~/environment/sg-per-pod/red-pod.yaml
kubectl -n sg-per-pod rollout status deployment red-pod

export RED_POD_NAME=$(kubectl -n sg-per-pod get pods -l app=red-pod -o jsonpath='{.items[].metadata.name}')
  
## should see Database connection failed due to timeout expired    
kubectl -n sg-per-pod  logs -f ${RED_POD_NAME}

## should not see Annotation with ENI  
kubectl -n sg-per-pod  describe pod ${RED_POD_NAME} | head -11
```  
### CleanUP
```
export VPC_ID=$(aws eks describe-cluster \
    --name eksworkshop-eksctl \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)
export RDS_SG=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=RDS_SG Name=vpc-id,Values=${VPC_ID} \
    --query "SecurityGroups[0].GroupId" --output text)
export POD_SG=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=POD_SG Name=vpc-id,Values=${VPC_ID} \
    --query "SecurityGroups[0].GroupId" --output text)
export C9_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
export NODE_GROUP_SG=$(aws ec2 describe-security-groups \
    --filters Name=tag:Name,Values=eks-cluster-sg-eksworkshop-eksctl-* Name=vpc-id,Values=${VPC_ID} \
    --query "SecurityGroups[0].GroupId" \
    --output text)

# uninstall the RPM package
sudo yum remove -y $(sudo yum list installed | grep amzn2extra-postgresql12 | awk '{ print $1}')

# delete database
aws rds delete-db-instance \
    --db-instance-identifier rds-eksworkshop \
    --delete-automated-backups \
    --skip-final-snapshot

# delete kubernetes element
kubectl -n sg-per-pod delete -f ~/environment/sg-per-pod/green-pod.yaml
kubectl -n sg-per-pod delete -f ~/environment/sg-per-pod/red-pod.yaml
kubectl -n sg-per-pod delete -f ~/environment/sg-per-pod/sg-policy.yaml
kubectl -n sg-per-pod delete secret rds

# delete the namespace
kubectl delete ns sg-per-pod

# disable ENI trunking
kubectl -n kube-system set env daemonset aws-node ENABLE_POD_ENI=false
kubectl -n kube-system rollout status ds aws-node

# detach the IAM policy
aws iam detach-role-policy \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSVPCResourceController \
    --role-name ${ROLE_NAME}

# remove the security groups rules
aws ec2 revoke-security-group-ingress \
    --group-id ${RDS_SG} \
    --protocol tcp \
    --port 5432 \
    --source-group ${POD_SG}

aws ec2 revoke-security-group-ingress \
    --group-id ${RDS_SG} \
    --protocol tcp \
    --port 5432 \
    --cidr ${C9_IP}/32

aws ec2 revoke-security-group-ingress \
    --group-id ${NODE_GROUP_SG} \
    --protocol tcp \
    --port 53 \
    --source-group ${POD_SG}

aws ec2 revoke-security-group-ingress \
    --group-id ${NODE_GROUP_SG} \
    --protocol udp \
    --port 53 \
    --source-group ${POD_SG}

# delete POD security group
aws ec2 delete-security-group \
    --group-id ${POD_SG}
```
```
## wait until DB deleted
aws rds describe-db-instances \
    --db-instance-identifier rds-eksworkshop \
    --query "DBInstances[].DBInstanceStatus" \
    --output text
```
```
# delete RDS SG
aws ec2 delete-security-group \
    --group-id ${RDS_SG}

# delete DB subnet group
aws rds delete-db-subnet-group \
    --db-subnet-group-name rds-eksworkshop
```  
```
# delete the nodegroup
eksctl delete nodegroup -f ${HOME}/environment/sg-per-pod/nodegroup-sec-group.yaml --approve

# remove the trunk label
kubectl label node  --all 'vpc.amazonaws.com/has-trunk-attached'-

cd ~/environment
rm -rf sg-per-pod
```  
  
  
############################################### SECURITY GROUPS FOR PODS  
  
</details>  
  
<details>
  <summary>SECURING YOUR CLUSTER WITH NETWORK POLICIES</summary>

### Install Calico
```
kubectl apply -f https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/release-1.6/config/v1.6/calico.yaml
kubectl get daemonset calico-node --namespace=kube-system
```
### Create Resource
```
mkdir ~/environment/calico_resources
cd ~/environment/calico_resources
cd ~/environment/calico_resources
wget https://eksworkshop.com/beginner/120_network-policies/calico/stars_policy_demo/create_resources.files/namespace.yaml
kubectl apply -f namespace.yaml  # create ns stars
```
```
cd ~/environment/calico_resources
wget https://eksworkshop.com/beginner/120_network-policies/calico/stars_policy_demo/create_resources.files/management-ui.yaml
wget https://eksworkshop.com/beginner/120_network-policies/calico/stars_policy_demo/create_resources.files/backend.yaml
wget https://eksworkshop.com/beginner/120_network-policies/calico/stars_policy_demo/create_resources.files/frontend.yaml
wget https://eksworkshop.com/beginner/120_network-policies/calico/stars_policy_demo/create_resources.files/client.yaml
```
```  
kubectl apply -f management-ui.yaml
kubectl apply -f backend.yaml
kubectl apply -f frontend.yaml
kubectl apply -f client.yaml
kubectl get pods --all-namespaces
```  
### DEFAULT POD-TO-POD COMMUNICATION
```
kubectl get svc -o wide -n management-ui
## http://lbaddress
```  
### APPLY NETWORK POLICIES
```
cd ~/environment/calico_resources
wget https://eksworkshop.com/beginner/120_network-policies/calico/stars_policy_demo/apply_network_policies.files/default-deny.yaml

kubectl apply -n stars -f default-deny.yaml
kubectl apply -n client -f default-deny.yaml 
```  
```
cd ~/environment/calico_resources
wget https://eksworkshop.com/beginner/120_network-policies/calico/stars_policy_demo/apply_network_policies.files/allow-ui.yaml
wget https://eksworkshop.com/beginner/120_network-policies/calico/stars_policy_demo/apply_network_policies.files/allow-ui-client.yaml
```  
```  
cat allow-ui.yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  namespace: stars
  name: allow-ui
spec:
  podSelector:
    matchLabels: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              role: management-ui
  
cat allow-ui-client.yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  namespace: client
  name: allow-ui
spec:
  podSelector:
    matchLabels: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              role: management-ui  
```
```
kubectl apply -f allow-ui.yaml
kubectl apply -f allow-ui-client.yaml

### See mngm UI - only see B, F, C  
```
### ALLOW Directional Traffic  
```
cat <<EOF | kubectl apply -f -
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  namespace: stars
  name: backend-policy
spec:
  podSelector:
    matchLabels:
      role: backend
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: frontend
      ports:
        - protocol: TCP
          port: 6379
---
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  namespace: stars
  name: frontend-policy
spec:
  podSelector:
    matchLabels:
      role: frontend
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              role: client
      ports:
        - protocol: TCP
          port: 80  
EOF
```  
### CLEANUP
```
kubectl delete namespace client stars management-ui
```  
</details>  
  
  
<details>
  <summary>Exposing a service</summary>
  
```
cat <<EoF > ~/environment/run-my-nginx.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-nginx
  namespace: my-nginx
spec:
  selector:
    matchLabels:
      run: my-nginx
  replicas: 2
  template:
    metadata:
      labels:
        run: my-nginx
    spec:
      containers:
      - name: my-nginx
        image: nginx
        ports:
        - containerPort: 80
EoF
# create the namespace
kubectl create ns my-nginx
# create the nginx deployment with 2 replicas
kubectl -n my-nginx apply -f ~/environment/run-my-nginx.yaml

kubectl -n my-nginx get pods -o wide 
```
### Create a Service
```
kubectl -n my-nginx expose deployment/my-nginx
kubectl -n my-nginx get svc my-nginx

# Create a variable set with the my-nginx service IP
export MyClusterIP=$(kubectl -n my-nginx get svc my-nginx -ojsonpath='{.spec.clusterIP}')
# Create a new deployment and allocate a TTY for the container in the pod
kubectl -n my-nginx run -i --tty load-generator --env="MyClusterIP=${MyClusterIP}" --image=busybox /bin/sh
  wget -q -O - ${MyClusterIP} | grep '<title>'
  exit
```  
### Access Service
- Environment variables
- DNS
```
kubectl -n my-nginx get pods -l run=my-nginx -o wide
export mypod=$(kubectl -n my-nginx get pods -l run=my-nginx -o jsonpath='{.items[0].metadata.name}')
kubectl -n my-nginx exec ${mypod} -- printenv | grep SERVICE
## will not see the service
  
kubectl -n my-nginx rollout restart deployment my-nginx
kubectl -n my-nginx get pods -l run=my-nginx -o wide

export mypod=$(kubectl -n my-nginx get pods -l run=my-nginx -o jsonpath='{.items[0].metadata.name}')
kubectl -n my-nginx exec ${mypod} -- printenv | grep SERVICE

### KUBERNETES_SERVICE_HOST=10.100.0.1
### KUBERNETES_SERVICE_PORT=443
### KUBERNETES_SERVICE_PORT_HTTPS=443
### MY_NGINX_SERVICE_HOST=10.100.225.196
### MY_NGINX_SERVICE_PORT=80  
```
```
kubectl get service -n kube-system -l k8s-app=kube-dns
kubectl -n my-nginx run curl --image=radial/busyboxplus:curl -i --tty
  nslookup my-nginx
  exit
```
### EXPOSING THE SERVICE
```
kubectl -n my-nginx get svc my-nginx
kubectl -n my-nginx patch svc my-nginx -p '{"spec": {"type": "LoadBalancer"}}'  # -> classic LB
kubectl -n my-nginx get svc my-nginx
```
```
export loadbalancer=$(kubectl -n my-nginx get svc my-nginx -o jsonpath='{.status.loadBalancer.ingress[*].hostname}')
curl -k -s http://${loadbalancer} | grep title
kubectl -n my-nginx describe service my-nginx | grep Ingress 
```
  
### INGRESS CONTROLLER
Unlike other types of controllers which run as part of the kube-controller-manager binary, Ingress controllers are not started automatically with a cluster.  
AWS Load Balancer Controller  ( <- AWS ALB controller)
- It satisfies Kubernetes Ingress resources by provisioning Application Load Balancers.
- It satisfies Kubernetes Service resources by provisioning Network Load Balancers.                                   
  
```
# export LBC_VERSION="v2.4.1"
# export LBC_CHART_VERSION="1.4.1"
                                   
if [ ! -x ${LBC_VERSION} ]
  then
    tput setaf 2; echo '${LBC_VERSION} has been set.'
  else
    tput setaf 1;echo '${LBC_VERSION} has NOT been set.'
fi
```
```                                   
helm version --short
                                   
eksctl utils associate-iam-oidc-provider \
    --region ${AWS_REGION} \
    --cluster eksworkshop-eksctl \
    --approve
                           
                                   
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json
## aws->aws-us-gov  
sed -i 's/:aws:/:aws-us-gov:/' iam_policy.json   
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
                                
## :aws:->:aws-us-gov                                   
eksctl create iamserviceaccount \
  --cluster eksworkshop-eksctl \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws-us-gov:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve

## TargetGroupBinding CRD                                   
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
kubectl get crd  
```  
```
helm repo add eks https://aws.github.io/eks-charts

helm upgrade -i aws-load-balancer-controller \
    eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=eksworkshop-eksctl \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set image.tag="${LBC_VERSION}" \
    --version="${LBC_CHART_VERSION}"

## https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html
## us-gov-west-1	013241004608.dkr.ecr.us-gov-west-1.amazonaws.com  
## kubectl -n kube-system edit deployment aws-load-balancer-controller   # image replace
  
kubectl -n kube-system rollout status deployment aws-load-balancer-controller
```                                   

### Deploy Sample Application
```
export EKS_CLUSTER_VERSION=$(aws eks describe-cluster --name eksworkshop-eksctl --query cluster.version --output text)

if [ "`echo "${EKS_CLUSTER_VERSION} < 1.19" | bc`" -eq 1 ]; then     
    curl -s https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.3.1/docs/examples/2048/2048_full.yaml \
    | sed 's=alb.ingress.kubernetes.io/target-type: ip=alb.ingress.kubernetes.io/target-type: instance=g' \
    | kubectl apply -f -
fi

if [ "`echo "${EKS_CLUSTER_VERSION} >= 1.19" | bc`" -eq 1 ]; then     
    curl -s https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.3.1/docs/examples/2048/2048_full_latest.yaml \
    | sed 's=alb.ingress.kubernetes.io/target-type: ip=alb.ingress.kubernetes.io/target-type: instance=g' \
    | kubectl apply -f -
fi

kubectl get ingress/ingress-2048 -n game-2048
export GAME_INGRESS_NAME=$(kubectl -n game-2048 get targetgroupbindings -o jsonpath='{.items[].metadata.name}')
kubectl -n game-2048 get targetgroupbindings ${GAME_INGRESS_NAME} -o yaml 
```  
```
### Access the app  
export GAME_2048=$(kubectl get ingress/ingress-2048 -n game-2048 -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo http://${GAME_2048}
```        
### CleanUP
```
kubectl delete -f ~/environment/run-my-nginx.yaml
kubectl delete ns my-nginx
rm ~/environment/run-my-nginx.yaml

export EKS_CLUSTER_VERSION=$(aws eks describe-cluster --name eksworkshop-eksctl --query cluster.version --output text)

if [ "`echo "${EKS_CLUSTER_VERSION} < 1.19" | bc`" -eq 1 ]; then     
    curl -s https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.3.1/docs/examples/2048/2048_full.yaml \
    | sed 's=alb.ingress.kubernetes.io/target-type: ip=alb.ingress.kubernetes.io/target-type: instance=g' \
    | kubectl delete -f -
fi

if [ "`echo "${EKS_CLUSTER_VERSION} >= 1.19" | bc`" -eq 1 ]; then     
    curl -s https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.3.1/docs/examples/2048/2048_full_latest.yaml \
    | sed 's=alb.ingress.kubernetes.io/target-type: ip=alb.ingress.kubernetes.io/target-type: instance=g' \
    | kubectl delete -f -
fi

unset EKS_CLUSTER_VERSION

helm uninstall aws-load-balancer-controller \
    -n kube-system

kubectl delete -k github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master

eksctl delete iamserviceaccount \
    --cluster eksworkshop-eksctl \
    --name aws-load-balancer-controller \
    --namespace kube-system \
    --wait

### aws->aws-us-gov  
aws iam delete-policy \
    --policy-arn arn:aws-us-gov:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy
```  
  
  
  
</details>
  
  
<details>
  <summary>Assigned Pod to Node</summary>
  
```
kubectl get nodes
kubectl get nodes --selector disktype=ssd  
```
```
# export the first node name as a variable
export FIRST_NODE_NAME=$(kubectl get nodes -o json | jq -r '.items[0].metadata.name')

# add the label to the node
kubectl label nodes ${FIRST_NODE_NAME} disktype=ssd
kubectl get nodes --selector disktype=ssd  
``` 
```
cat <<EoF > ~/environment/pod-nginx.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels:
    env: test
spec:
  containers:
  - name: nginx
    image: nginx
    imagePullPolicy: IfNotPresent
  nodeSelector:
    disktype: ssd
EoF
kubectl apply -f ~/environment/pod-nginx.yaml
kubectl get pods -o wide
```  
## AFFINITY AND ANTI-AFFINITY
```
# export the first node name as a variable
export FIRST_NODE_NAME=$(kubectl get nodes -o json | jq -r '.items[0].metadata.name')

kubectl label nodes ${FIRST_NODE_NAME} azname=az1

cat <<EoF > ~/environment/pod-with-node-affinity.yaml
apiVersion: v1
kind: Pod
metadata:
  name: with-node-affinity
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: azname
            operator: In
            values:
            - az1
            - az2
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 1
        preference:
          matchExpressions:
          - key: another-node-label-key
            operator: In
            values:
            - another-node-label-value
  containers:
  - name: with-node-affinity
    image: us.gcr.io/k8s-artifacts-prod/pause:2.0
EoF
kubectl apply -f ~/environment/pod-with-node-affinity.yaml
kubectl get pods -o wide  
```  
  
```
kubectl delete -f ~/environment/pod-with-node-affinity.yaml

kubectl label nodes ${FIRST_NODE_NAME} azname-
```  
### Second Node  
```
export SECOND_NODE_NAME=$(kubectl get nodes -o json | jq -r '.items[1].metadata.name')

kubectl label nodes ${SECOND_NODE_NAME} azname=az1
kubectl apply -f ~/environment/pod-with-node-affinity.yaml
  
kubectl get pods -o wide  
```
```
kubectl delete -f ~/environment/pod-nginx.yaml
kubectl delete -f ~/environment/pod-with-node-affinity.yaml
```  
### Always co-located in the same node
```
cat <<EoF > ~/environment/redis-with-node-affinity.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-cache
spec:
  selector:
    matchLabels:
      app: store
  replicas: 3
  template:
    metadata:
      labels:
        app: store
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - store
            topologyKey: "kubernetes.io/hostname"
      containers:
      - name: redis-server
        image: redis:3.2-alpine
EoF

```
```
cat <<EoF > ~/environment/web-with-node-affinity.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-server
spec:
  selector:
    matchLabels:
      app: web-store
  replicas: 3
  template:
    metadata:
      labels:
        app: web-store
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - web-store
            topologyKey: "kubernetes.io/hostname"
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - store
            topologyKey: "kubernetes.io/hostname"
      containers:
      - name: web-app
        image: nginx:1.12-alpine
EoF
  
```
```
kubectl apply -f ~/environment/redis-with-node-affinity.yaml
kubectl apply -f ~/environment/web-with-node-affinity.yaml
# We will use --sort-by to filter by nodes name
 kubectl get pods -o wide --sort-by='.spec.nodeName'  
```  
### Cleanup
```
kubectl delete -f ~/environment/redis-with-node-affinity.yaml
kubectl delete -f ~/environment/web-with-node-affinity.yaml
kubectl label nodes --all azname-
kubectl label nodes --all disktype-
```  
  
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
