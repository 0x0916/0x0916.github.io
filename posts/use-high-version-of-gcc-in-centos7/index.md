在`centos`上进行内核开发时，由于一些内核特性依赖于高版本的`GCC特性`（`gcc > 5.0`），而`centos`默认的GCC一般为`4.8.x`。

本文记录一种非常简单的在`centos`上使用高版本的`GCC`的方法。

<!--more-->

### 方法来源

非常感谢项目：[https://www.softwarecollections.org/en/](https://www.softwarecollections.org/en/)，其提供了RHEL系列发行版上默认的软件版本外的其他选择，其项目介绍就不翻译了，直接[copy过来](https://www.softwarecollections.org/en/about/)：

```
SoftwareCollections.org is the home for projects creating Software Collections (SCLs)
for Red Hat Enterprise Linux, Fedora, CentOS, and Scientific Linux. This is where you
create and host Software Collections, as well as connect with other developers working
on SCLs.

SoftwareCollections.org is also the central repository for users to find
third-party SCLs for their systems.
```

### 具体步骤

详细步骤来源于：https://www.softwarecollections.org/en/scls/rhscl/devtoolset-7/

```bash
# 1. Install a package with repository for your system:
# On CentOS, install package centos-release-scl available in CentOS repository:
$ sudo yum install centos-release-scl

# On RHEL, enable RHSCL repository for you system:
$ sudo yum-config-manager --enable rhel-server-rhscl-7-rpms

# 2. Install the collection:
$ sudo yum install devtoolset-7

# 3. Start using software collections:
$ scl enable devtoolset-7 bash

$ # 默认情况下，gcc的版本未 4.8.x
$ gcc --version
gcc (GCC) 4.8.5 20150623 (Red Hat 4.8.5-28)
Copyright (C) 2015 Free Software Foundation, Inc.
This is free software; see the source for copying conditions.  There is NO
warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

$ # 切换为scl后
$ scl enable devtoolset-7 bash
$ gcc --version
gcc (GCC) 7.3.1 20180303 (Red Hat 7.3.1-5)
Copyright (C) 2017 Free Software Foundation, Inc.
This is free software; see the source for copying conditions.  There is NO
warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

```

### 参考文章

- https://www.softwarecollections.org/en/
- https://www.softwarecollections.org/en/scls/rhscl/devtoolset-7/
