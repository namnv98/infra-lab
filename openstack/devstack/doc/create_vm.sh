gcloud compute instances create "devstack" \
--project="master-scope-462801-r2" \
--zone="asia-southeast1-a" \
--machine-type="n2-standard-4" \
--image-family="debian-12" \
--image-project="debian-cloud" \
--boot-disk-size="100GB" \
--boot-disk-type="pd-balanced" \
--boot-disk-device-name="devstack" \
--metadata=enable-oslogin=false,enable-osconfig=TRUE,ssh-keys="namnv:ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKT+X+GVJ1EwWxT+nHb6CdCkChG5be/W9ZEHGbq5dQiKsDKBWiNdZlCocKMmxX6MmTeiB/eZ0GxiHI6qRuK9/6A=" \
--tags="a" \
--scopes=cloud-platform



gcloud beta compute instances delete devstack \
  --zone=asia-southeast1-a \
  --quiet \
  --no-graceful-shutdown


