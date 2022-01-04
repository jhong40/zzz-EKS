https://kubernetes.github.io/ingress-nginx/deploy/#aws

k run util --image=praqma/network-multitool
 
curl -H "Host: example.com" http://localhost

#################################

sudo apt update; sudo apt install -y unzip

### install asw cli
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version


### install kubectl
curl -o kubectl https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/kubectl
chmod 755 kubectl
sudo mv kubectl /usr/local/bin
kubectl version

### install eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
eksctl version

### install terraform
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install terraform
terraform -help

### aws configure


### install ansible with python3
sudo apt update
sudo apt -y install python3-pip
pip3 --version
sudo pip3 install ansible
ansible --version

 

