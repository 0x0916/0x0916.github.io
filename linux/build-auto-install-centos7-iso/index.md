本文以`centos 7.6` 的`ISO`为例，构建了用于自动化安装的`ISO`。

<!--more-->

![](pic.jpg "")

### 构建基础环境

（1）下载`centos7.6`的`iso`文件

```bash
# cd ~
# wget -c http://mirrors.163.com/centos/7.6.1810/isos/x86_64/CentOS-7-x86_64-DVD-1810.iso
```
（2）挂载到`/mnt`目录下
```bash
# mount -o loop /root/CentOS-7-x86_64-DVD-1810.iso /mnt
```
（3）在`$HOME`目录下创建如下目录
```
# cd ~/BuildISO/
# tree
.
|-- all_rpms
|-- ISO
|   |-- images
|   |-- isolinux
|   |-- LiveOS
|   |-- Packages
|   `-- repodata
`-- utils
```
创建目录的命令如下：
```bash
# mkdir ~/BuildISO
# cd ~/BuildISO
# mkdir  all_rpms  ISO  utils
# cd ~/BuildISO/ISO
# mkdir  images isolinux LiveOS Packages repodata
# cd ~
```
（4）从`/mnt`挂载目录下拷贝`CentOS_buildTag EFI EULA GPL RPM-GPG-KEY-CentOS-7 RPM-GPG-KEY-CentOS-Testing-7 TRANS.TBL`文件到`~/BuildISO/ISO/`目录

```bash
# cp -r /mnt/CentOS_BuildTag /mnt/EFI /mnt/EULA /mnt/GPL /mnt/RPM-GPG-KEY-CentOS-* /mnt/TRANS.TBL ~/BuildISO/ISO/
```
（5）拷贝`/mnt/images/`目录下的所有内容到`~/BuildISO/ISO/images/`，拷贝`/mnt/isolinux/`下的所有内容到`~/BuildISO/ISO/isolinux/`目录，拷贝`/mnt/LiveOS/`目录下所有内容到`~/BuildISO/ISO/LiveOS`目录中

```bash
# cp -r /mnt/images/* ~/BuildISO/ISO/images/
# cp -r /mnt/isolinux/* ~/BuildISO/ISO/isolinux/
# cp -r /mnt/LiveOS/* ~/BuildISO/ISO/LiveOS/
```
（6）拷贝`/mnt/repodata/aced7d22b338fdf7c0a71ffcf32614e058f4422c42476d1f4b9e9364d567702f-c7-x86_64-comps.xml`到`~/BuildISO/`中，并重命名为`comps.xml`

```bash
# cp /mnt/repodata/aced7d22b338fdf7c0a71ffcf32614e058f4422c42476d1f4b9e9364d567702f-c7-x86_64-comps.xml ~/BuildISO/comps.xml
```
（7）拷`/mnt/Packages/`目录下的所有RPM包到`~/BuildISO/all_rpms`目录中
```
 cp -r /mnt/Packages/* ~/BuildISO/all_rpms/
```
（8）拷贝生产系统中`/root/anaconda-ks.cfg`到`~/BuildISO/isolinux/`目录，并重命名为`ks.cfg`，并对其内容进行修改，修改后内容如下代码所示：

```
#version=DEVEL
# System authorization information
auth --enableshadow --passalgo=sha512

# Install OS instead of upgrade
install

# Use CDROM installation media
cdrom

# Use text mode install
text

# Use graphical install
#graphical

# Run the Setup Agent on first boot
firstboot --disable

# Partition clearing information
ignoredisk --only-use=sda

# Keyboard layouts
keyboard --vckeymap=us --xlayouts='us'

# System language
lang en_US.UTF-8

# License agreement
eula --agreed

firewall --service=ssh
logging --level=info

# Reboot after installation
reboot

# Network information
network  --bootproto=dhcp --device=enp0s3 --onboot=off --ipv6=auto --no-activate
network  --hostname=localhost.localdomain

# Root password
rootpw --plaintext test
user --groups=wheel --name=test --password=test --gecos="test" --plaintext

# SELinux configuration
selinux --disabled
# System timezone
timezone America/New_York --isUtc
# X Window System configuration information
xconfig  --startxonboot
# System bootloader configuration
bootloader --append=" crashkernel=auto" --location=mbr --boot-drive=sda
# Clear the Master Boot Record
zerombr
autopart --type=lvm
# Partition clearing information
clearpart --all --initlabel --drives=sda

%packages
@core
@base
@development
@additional-devel
@debugging
@java-platform
@network-file-system-client
@performance
@perl-runtime
kexec-tools

%end

%addon com_redhat_kdump --enable --reserve-mb='auto'

%end
```

### 确定需要安装的软件包

通过运行`~/BuildISO/utils/gather_packages.pl`脚本来拷贝所有软件包:

```bash
# ~/BuildISO/utils/gather_packages.pl ~/BuildISO/comps.xml ~/BuildISO/all_rpms ~/BuildISO/ISO/Packages x86_64 development additional-devel debugging java-platform network-file-system-client performance perl-runtime
```

### 解决RPM依赖问题

现在已经将所有需要的组的`RPM`包拷贝到了`~/BuildISO/ISO/Packages`目录中，接下来就要检查此目录中的`RPM`包是否还缺少依赖的`RPM`包。我们可以通过脚本`~/BuildISO/utils/resove_deps.pl`来完成检查拷贝工作。

```bash
# ~/BuildISO/utils/resolve_deps.pl ~/BuildISO/all_rpms  ~/BuildISO/ISO/Packages  x86_64
```

现在我们已经得到了所需要的`RPM`包，现在需要测试一下`RPM`包的依赖关系


```
cd ~/BuildISO/ISO/Packages
mkdir /tmp/testdb
rpm --initdb --dbpath /tmp/testdb
rpm --test --dbpath /tmp/testdb -Uvh *.rpm
```
命令执行完，输出如下：
```
# rpm --test --dbpath /tmp/testdb -Uvh *.rpm
warning: abattis-cantarell-fonts-0.0.25-1.el7.noarch.rpm: Header V3 RSA/SHA256 Signature, key ID f4a80eb5: NOKEY
error: Failed dependencies:
	/usr/sbin/cgrulesengd is needed by cgdcbxd-1.0.2-7.el7.x86_64
	/usr/bin/fipscheck is needed by fipscheck-lib-1.4.1-6.el7.x86_64
	/usr/bin/db_stat is needed by rpm-4.11.3-35.el7.x86_64
	/usr/bin/fusermount is needed by xdg-desktop-portal-1.0.2-1.el7.x86_64
```
说明还缺少一些依赖，可以通过命令`yum provides cgrulesengd`来查找所需的`RPM`包:
```
yum provides cgrulesengd 
yum provides fipscheck 
yum provides db_stat 
yum provides fusermount

```
需要手动从`~/BuildISO/all_rpms`拷贝相应的包到目录`~/BuildISO/ISO/Packages`中，然后再次运行`rpm --test --dbpath /tmp/testdb -Uvh *.rpm`直到输出如下信息为止：

```bash
# rpm --test --dbpath /tmp/testdb -Uvh *.rpm
warning: abattis-cantarell-fonts-0.0.25-1.el7.noarch.rpm: Header V3 RSA/SHA256 Signature, key ID f4a80eb5: NOKEY
Preparing...                          ################################# [100%]
```

此外，还需拷贝如下两个软件包

```bash
# cp ~/BuildISO/all_rpms/newt-python-0.52.15-4.el7.x86_64.rpm  ~/BuildISO/ISO/Packages/
# cp ~/BuildISO/all_rpms/authconfig-6.2.8-30.el7.x86_64.rpm  ~/BuildISO/ISO/Packages/
```

### 生成RPM repository

```bash
# cd ~/BuildISO/ISO/
# createrepo -g ~/BuildISO/comps.xml .
```

### 生成ISO镜像

修改`~/BuildISO/ISO/isolinux/isolinux.cfg`如下

```
label linux
  menu label ^Install CentOS 7
  kernel vmlinuz
  #去掉quiet，增加inst.ks=cdrom:/dev/cdrom:/isolinux/ks.cfg内容
  #append initrd=initrd.img inst.stage2=hd:LABEL=CentOS\x207\x20x86_64 quiet
 append initrd=initrd.img inst.stage2=hd:LABEL=CentOS\x207\x20x86_64  inst.ks=cdrom:/dev/cdrom:/isolinux/ks.cfg
```

制作`ISO`镜像

```
mkisofs -U -r -v -T -J -joliet-long \
    -V "CentOS 7 x86_64" \
    -volset "CentOS 7 x86_64" \
    -A "CentOS 7 x86_64" \
    -input-charset utf-8 \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat -no-emul-boot \
    -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e images/efiboot.img \
    -no-emul-boot -o /root/CENTOS7.6-AUTO-INSTALL-ISO.iso \
    ~/BuildISO/ISO/
```

### 测试ISO镜像

将制作好的`ISO`镜像用`VirtualBox`安装测试，确认制作的`ISO`能够正常运行。


### 定制自己的功能并制作ISO

在上面已经创建出了能够正常运行的`ISO`镜像，下面就是在上述`ISO`中添加自己的功能。

为添加自己定制的功能，我们需要使用`postinstall script`，即在`ks.cfg`中增加`%post`区域。

在`ks.cfg`配置文件中，`%post`域的命令在`anaconda`安装完成后开始执行。默认情况下，`%post`区域的命令运行在一个`chroot`环境下，此时`/mnt/sysimage`作为`/`目录，这样允许用户像访问正常目录一样进行访问，例如：如果要使用`/etc`目录，则应该使用`/etc`而不是`/mnt/sysimage/etc`。在`chroot`环境下最主要的缺点是无法访问安装介质。

为了解决这个问题，这里将`postinstall script`分两个阶段来处理：

#### 第一阶段

告诉`anaconda`不要去`chroot`，将需要的文件从安装介质（`ISO`）中拷贝到磁盘中：

```
%post --nochroot

#!/bin/bash

set -x -v
exec 1> /mnt/sysimage/root/kickstart-stage1.log 2>&1

echo "==> copying files from media to install drive..."

cp -r /run/install/repo/postinstall /mnt/sysimage/root

%end
```

此次`ISO`镜像中定制安装文件放到了`~/BuildISO/ISO/`目录下的`postinstall`目录中。制作`ISO`镜像时的`~/BuildISO/ISO/`对应于安装介质的根目录，同时安装介质挂载在`/run/install/repo`目录下。所以`~/BuildISO/ISO/postinstall`可以通过`/run/install/repo/postinstall`获取。我们从安装介质上拷贝`postinstall`目录到新系统硬盘的`/root/postinstall`目录


#### 第二阶段

安装定制的功能

```
%post
#!/bin/bash

set -x -v

exec 1>/root/kickstart-stage2.log 2>&1

ls -l /root/postinstall

echo "===> install test..."
%end
```

#### 具体操作流程

（1）在`~/BuildISO/ISO`中创建`postinstall`目录，并在其下创建相关目录：
```
mkdir -p ~/BuildISO/ISO/postinstall/app/test
```
（2）将`test`相关`RPM`包上传到`test`目录中
（3）修改`ks.cfg`，通过两个`%post`来实现`RPM`包拷贝和`RPM`包的安装，具体如下：
```
%post --nochroot

#!/bin/bash

set -x -v
exec 1> /mnt/sysimage/root/kickstart-stage1.log 2>&1

echo "==> copying files from media to install drive..."

cp -r /run/install/repo/postinstall /mnt/sysimage/root

%end

%post
#!/bin/bash

set -x -v

exec 1>/root/kickstart-stage2.log 2>&1

ls -l /root/postinstall

echo "===> install test..."
yum install /root/postinstall/test/test.rpm    

%end
```

（4）制作`ISO`镜像

```
mkisofs -U -r -v -T -J -joliet-long \
    -V "CentOS 7 x86_64" \
    -volset "CentOS 7 x86_64" \
    -A "CentOS 7 x86_64" \
    -input-charset utf-8 \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat -no-emul-boot \
    -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e images/efiboot.img \
    -no-emul-boot -o /root/ISO-CM.iso \
    ~/BuildISO/ISO/
```
### 测试ISO镜像

安装测试`ISO`，并测试定制安装的功能是否能正常工作。

### 代码

* [resolve_deps.pl](./resolve_deps.pl)
* [gather_packages.pl](./gather_packages.pl)

### 参考文章

* http://ry0117.com/2016/12/13/%E8%87%AA%E5%8A%A8%E5%8C%96%E5%AE%89%E8%A3%85ISO%E5%88%B6%E4%BD%9C%E6%B5%81%E7%A8%8B/
* http://www.smorgasbork.com/2014/07/16/building-a-custom-centos-7-kickstart-disc-part-1/
