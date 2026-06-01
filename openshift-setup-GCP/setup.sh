gcloud auth  list



export gcp_project=lwprojectocp


gcloud projects create ${gcp_project}

gcloud projects list

gcloud config set project ${gcp_project}

gcloud config list

gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a


gcloud alpha billing accounts list

gcloud alpha billing projects link ${gcp_project} --billing-account $(gcloud alpha billing accounts list | head -1  | awk '{print $2 }')




gcloud services enable compute.googleapis.com --project ${gcp_project}
gcloud services enable cloudapis.googleapis.com --project ${gcp_project}
gcloud services enable cloudresourcemanager.googleapis.com --project ${gcp_project}
gcloud services enable dns.googleapis.com --project ${gcp_project}
gcloud services enable iamcredentials.googleapis.com --project ${gcp_project}
gcloud services enable iam.googleapis.com --project ${gcp_project}
gcloud services enable servicemanagement.googleapis.com --project ${gcp_project}
gcloud services enable serviceusage.googleapis.com --project ${gcp_project}
gcloud services enable storage-api.googleapis.com --project ${gcp_project}
gcloud services enable storage-component.googleapis.com --project ${gcp_project}
gcloud services enable deploymentmanager.googleapis.com --project ${gcp_project}
gcloud services enable file.googleapis.com  --project ${gcp_project}

export gcp_domain=summerinternship.in

gcloud dns managed-zones create my-dns-lw --dns-name ${gcp_domain}. --description "DNS for test OCP"
gcloud dns managed-zones describe my-dns-lw


dig @8.8.8.8 ${gcp_domain} NS +short
nslookup -q=ns ${gcp_domain}


export gcp_sa=my-lw-ocp-sa
gcloud iam service-accounts create ${gcp_sa}

gcloud projects add-iam-policy-binding ${gcp_project} --member "serviceAccount:${gcp_sa}@${gcp_project}.iam.gserviceaccount.com" --role "roles/owner"


mkdir -p ~/.gcp

gcloud iam service-accounts keys create ${HOME}/.gcp/osServiceAccount.json --iam-account ${gcp_sa}@${gcp_project}.iam.gserviceaccount.com


wget  https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-install-linux.tar.gz

tar -xvzf openshift-install-linux.tar.gz 


mkdir myinstall
./openshift-install create install-config --dir ./myinstall

https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/installing_on_gcp/installation-config-parameters-gcp


compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: 
    gcp:
      type: n2-standard-4
      osDisk:
        diskType: pd-ssd
        diskSizeGB: 50
  replicas: 1
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: 
    gcp:
      type: n2-standard-4
      osDisk:
        diskType: pd-ssd
        diskSizeGB: 100
  replicas: 1



./openshift-install create cluster  --log-level debug --dir=./myinstall/



export KUBECONFIG=/home/preeti13101311/.gcp/myinstall/auth/kubeconfig
