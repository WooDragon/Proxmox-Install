#!/bin/bash

set -e
set -o pipefail

DEBIAN_ISO="$1"
OUTPUT_ISO="$2"

if [[ -z "$DEBIAN_ISO" || -z "$OUTPUT_ISO" ]]; then
  echo "Usage: $0 <debian-iso> <output-iso>"
  exit 1
fi

WORKDIR=$(mktemp -d)
mkdir -p "$WORKDIR/iso" "$WORKDIR/temp" "$WORKDIR/pve"

# -----------------------------
# Step 1: Mount and extract the ISO
# -----------------------------
mount -o loop "$DEBIAN_ISO" "$WORKDIR/temp"
cp -a "$WORKDIR/temp/." "$WORKDIR/iso"
umount "$WORKDIR/temp"

# -----------------------------
# Step 2: Add Proxmox repo (temporary) and download packages
# -----------------------------
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
  > /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg

# 安装 apt-rdepends 工具（如果尚未安装）
apt-get update
apt-get install -y apt-rdepends

# -----------------------------
# (A) 函数: resolve_virtual_pkg
#    用来把“虚拟包”映射成“真实包名”
# -----------------------------
resolve_virtual_pkg() {
  local pkg="$1"

  # apt-cache show 能否找到真实的 "Package: $pkg"
  if apt-cache show "$pkg" 2>/dev/null | grep -q "^Package: $pkg"; then
    # 说明它是一个真实存在的包，可直接返回
    echo "$pkg"
  else
    # 尝试解析 "Reverse Provides"
    # apt-cache showpkg $pkg 的格式中:
    #   Reverse Provides:
    #    perl  perlapi-5.36.0
    # 意味着 perl 提供 perlapi-5.36.0
    local providers
    # 使用 awk 拿到 Reverse Provides 部分并提取第1列包名
    providers=$(apt-cache showpkg "$pkg" 2>/dev/null \
      | awk '/Reverse Provides:/{flag=1; next} /^$/{flag=0} flag {print $1}' \
      | cut -d' ' -f1 \
      | sort -u)

    # 如果找到提供者，就输出，否则只能返回原包名(大概率下载会失败)
    if [[ -n "$providers" ]]; then
      echo "$providers"
    else
      echo "$pkg"
    fi
  fi
}

# (2.1) 下载几个必需的包（不包含 proxmox-ve） 
#       包括 postfix, open-iscsi, chrony
apt-get install --download-only -y postfix open-iscsi chrony

# (2.2) 下载 “standard” 任务及附加包所需的 .deb
#       先获取 standard 任务下的所有包名:
STANDARD_PACKAGES=$(tasksel --task-packages standard)

# (2.3) 针对 curl 做同样处理（先拿到依赖，再 reinstall）
echo "==== Listing dependencies for curl using apt-rdepends ===="
# 使用 apt-rdepends 递归列出所有依赖
CURL_DEPS=$(apt-rdepends curl \
  | grep -vE '^ ' \
  | grep -vE '^(Reading|Build\-Depends|Suggests|Recommends|Conflicts|Breaks|PreDepends)' \
  | sort -u)
echo "curl deps: $CURL_DEPS"

if [[ -n "$CURL_DEPS" ]]; then
  apt-get install --download-only --reinstall -y $CURL_DEPS curl
else
  apt-get install --download-only --reinstall -y curl
fi

# (2.4) 并行化处理 proxmox-default-kernel, proxmox-ve, openssh-server, gnupg, tasksel
echo "=== Recursively listing proxmox-ve dependencies via apt-rdepends in parallel ==="
PACKAGES="proxmox-default-kernel proxmox-ve openssh-server gnupg tasksel"

# 创建临时目录存储每个包的依赖输出
TEMP_DEPS_DIR=$(mktemp -d)
echo "Temporary dependencies directory: $TEMP_DEPS_DIR"

# 并行运行 apt-rdepends 并将输出保存到临时文件
for pkg in $PACKAGES; do
  {
    echo "Processing package: $pkg"
    apt-rdepends "$pkg" \
      | grep -vE '^(Reading|Build-Depends|Suggests|Recommends|Conflicts|Breaks|PreDepends|Enhances|Replaces|Provides)' \
      | grep -v '^ ' \
      >> "$TEMP_DEPS_DIR/deps.txt"
  } &
done

# 等待所有后台进程完成
wait

# 收集所有依赖
ALL_PVE_DEPS=$(cat "$TEMP_DEPS_DIR/deps.txt" | sort -u)

# 添加原始包名以确保它们被包含
ALL_PVE_DEPS+=" $PACKAGES"

# 删除临时依赖目录
rm -rf "$TEMP_DEPS_DIR"

# (2.5) 下载所有依赖(含可能的虚拟包)前，先做“虚拟包 -> 真实包”转换
RESOLVED_DEPS=""
for pkg in $ALL_PVE_DEPS; do
  # 解析可能的虚拟包
  realpkgs=$(resolve_virtual_pkg "$pkg")
  RESOLVED_DEPS+=" $realpkgs"
done

# (2.6) 批量下载
ORIGINAL_DIR=$(pwd)
CACHE_DIR="/var/cache/apt/archives"
chown -R _apt:root "$CACHE_DIR"
chmod -R 755 "$CACHE_DIR"
cd "$CACHE_DIR"

echo "=== Downloading all dependencies in batch (ignoring errors) ==="
echo "Resolved packages: $RESOLVED_DEPS"
for rp in $RESOLVED_DEPS; do
  apt-get download "$rp" || echo "Failed to download $rp"
done

cd "$ORIGINAL_DIR"
echo "=== All dependencies downloaded to $CACHE_DIR ==="

# (2.7) 将下载好的 .deb 拷贝到离线仓库目录 $WORKDIR/pve
echo "==== Copying downloaded packages to $WORKDIR/pve ===="
cp /var/cache/apt/archives/*.deb "$WORKDIR/pve/" || true

# 生成离线仓库
cd "$WORKDIR/pve"
dpkg-scanpackages . > Packages
gzip -9c Packages > Packages.gz
cd -

# -----------------------------
# Step 3: Copy preseed + local repo to ISO
# -----------------------------
cp preseed.cfg "$WORKDIR/iso/"
cp -r "$WORKDIR/pve" "$WORKDIR/iso/"

# -----------------------------
# Step 4: Modify bootloader
# BIOS: isolinux/txt.cfg & UEFI: grub.cfg
# -----------------------------
# 4.1 BIOS isolinux
sed -i '/timeout/s/.*/timeout 100/' "$WORKDIR/iso/isolinux/isolinux.cfg"
sed -i '/default/s/.*/default auto/' "$WORKDIR/iso/isolinux/txt.cfg"

cat <<EOF >> "$WORKDIR/iso/isolinux/txt.cfg"

label auto
  menu label ^Automated Installation
  kernel /install.amd/vmlinuz
  append initrd=/install.amd/initrd.gz auto=true priority=high locale=zh_CN.UTF-8 keymap=us file=/cdrom/preseed.cfg --
EOF

# 4.2 UEFI grub.cfg
sed -i '/set timeout=/s/.*/set timeout=10/' "$WORKDIR/iso/boot/grub/grub.cfg"

cat <<EOF >> "$WORKDIR/iso/boot/grub/grub.cfg"

menuentry "Automated Installation" {
    set gfxpayload=keep
    linux /install.amd/vmlinuz auto=true priority=high locale=zh_CN.UTF-8 keymap=us file=/cdrom/preseed.cfg --
    initrd /install.amd/initrd.gz
}
EOF

# -----------------------------
# Step 5: Build custom ISO
# -----------------------------
xorriso \
  -outdev "$OUTPUT_ISO" \
  -volid "Proxmox_Custom" \
  -padding 0 \
  -compliance no_emul_toc \
  -map "$WORKDIR/iso" / \
  -chmod 0755 / -- \
  -boot_image isolinux dir=/isolinux \
  -boot_image any next \
  -boot_image any efi_path=boot/grub/efi.img \
  -boot_image isolinux partition_entry=gpt_basdat

isohybrid --uefi "$OUTPUT_ISO"

rm -rf "$WORKDIR"

echo "Custom ISO created: $OUTPUT_ISO"
