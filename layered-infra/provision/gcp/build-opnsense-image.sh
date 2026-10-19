#!/bin/bash
# Startup script của VM tạm "lab-imgbuild" (chạy trên GCP, mạng nhanh): tải bản nano chính thức của OPNsense,
# kiểm tra SHA256, ghi nguyên vẹn lên đĩa "out" rồi tắt máy. Không sửa gì trong image (golden image = bản gốc của hãng).
set -euo pipefail
V=$(curl -s -H 'Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/instance/attributes/opn-version)
BASE="https://pkg.opnsense.org/releases/$V"
IMG="OPNsense-$V-nano-amd64.img.bz2"
log() { echo "IMGBUILD: $*" > /dev/ttyS0; echo "IMGBUILD: $*"; }
cd /tmp
log "tải $BASE/$IMG"
curl -fsSLO "$BASE/$IMG"
curl -fsSLO "$BASE/OPNsense-$V-checksums-amd64.sha256"
grep "($IMG)" "OPNsense-$V-checksums-amd64.sha256" | awk '{print $NF"  '"$IMG"'"}' | sha256sum -c - \
  || { log "FAIL checksum"; exit 1; }
log "checksum OK, ghi lên đĩa"
python3 -c "import bz2,shutil,sys; shutil.copyfileobj(bz2.open(sys.argv[1]), sys.stdout.buffer, 4<<20)" "$IMG" | dd of=/dev/disk/by-id/google-out bs=4M conv=fsync status=none
sync
log "DONE"
poweroff
