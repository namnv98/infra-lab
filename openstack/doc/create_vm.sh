gcloud compute firewall-rules create allow-custom-ports \
  --project="reflected-disk-477514-v5" \
  --network="default" \
  --priority=1000 \
  --direction=INGRESS \
  --action=ALLOW \
  --rules="tcp:80,tcp:6080,tcp:2379,tcp:2380,tcp:2222" \
  --source-ranges="0.0.0.0/0" \
  --target-tags="my-rule" \
  --enable-logging


gcloud compute instances create "devstack" \
  --project="reflected-disk-477514-v5" \
  --zone="asia-southeast1-a" \
  --machine-type="n2-standard-8" \
  --image-family="ubuntu-2204-lts" \
  --image-project="ubuntu-os-cloud" \
  --boot-disk-size="120GB" \
  --boot-disk-type="pd-ssd" \
  --boot-disk-device-name="devstack" \
  --metadata=enable-oslogin=false,enable-osconfig=TRUE,ssh-keys="namnv:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIADjjf10H0L49MtlAuFwmyAS3nAk5/dd3nIpRFsOuMwd" \
  --tags="my-rule" \
  --scopes=cloud-platform


gcloud beta compute instances delete devstack \
  --zone=asia-southeast1-a \
  --quiet \
  --no-graceful-shutdown


