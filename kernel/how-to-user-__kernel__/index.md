

`__KERNEL__`宏的作用是什么呢？该如何使用呢？本文将详细介绍。

<!--more-->

### `__KERNEL__`宏的作用是什么呢?

这个宏在内核和应用程序代码中均能看到。它仅起到判断作用。例如：在代码中一般有
```
#ifdef __KERNEL__
some code
some code
#endif 
```
或者
```
#ifndef __KERNEL__
some code
some code
#endif
```
其目的非常简单，就是如果定义了宏`__KERNEL__`，或者没有定义`__KERNEL__`时，就包含`some code`这些代码片段。

那么在哪里来定义宏`__KERNEL__`呢？先看一段代码，我们编译内核或者内核模块是，gcc完整命令类似如下：

```
  if objdump -h /root/dive-in-kernel/h045_test_xarray/test_xarray.o | grep -q __ksymtab;
 then gcc -E -D__GENKSYMS__ -Wp,-MD,/root/dive-in-kernel/h045_test_xarray/.test_xarray.o.d
  -nostdinc -isystem /usr/lib/gcc/x86_64-redhat-linux/4.8.5/include -I./arch/x86/include
 -I./arch/x86/include/generated  -I./include -I./arch/x86/include/uapi -I./arch/x86/include
/generated/uapi -I./include/uapi -I./include/generated/uapi -include ./include/linux/kconfig.h
 -include ./include/linux/compiler_types.h -D__KERNEL__ -Wall -Wundef -Werror=strict-prototypes
 -Wno-trigraphs -fno-strict-aliasing -fno-common -fshort-wchar -fno-PIE
 -Werror=implicit-function-declaration -Werror=implicit-int -Wno-format-security -std=gnu89 
-mno-sse -mno-mmx -mno-sse2 -mno-3dnow -mno-avx -m64 -falign-jumps=1 -falign-loops=1 
-mno-80387 -mno-fp-ret-in-387 -mpreferred-stack-boundary=3 -mtune=generic -mno-red-zone 
-mcmodel=kernel -DCONFIG_AS_CFI=1 -DCONFIG_AS_CFI_SIGNAL_FRAME=1 -DCONFIG_AS_CFI_SECTIONS=1 
-DCONFIG_AS_SSSE3=1 -DCONFIG_AS_AVX=1 -DCONFIG_AS_AVX2=1 -DCONFIG_AS_AVX512=1 
-DCONFIG_AS_SHA1_NI=1 -DCONFIG_AS_SHA256_NI=1 -Wno-sign-compare -fno-asynchronous-unwind-tables
 -mindirect-branch=thunk-extern -mindirect-branch-register -fno-jump-tables 
-fno-delete-null-pointer-checks -O2 -Wno-maybe-uninitialized --param=allow-store-data-races=0
 -Wframe-larger-than=2048 -fstack-protector-strong -Wno-unused-but-set-variable 
-fno-omit-frame-pointer -fno-optimize-sibling-calls -fno-var-tracking-assignments -g -pg 
-mfentry -DCC_USING_FENTRY -fno-inline-functions-called-once -Wdeclaration-after-statement 
-Wvla -Wno-pointer-sign -fno-strict-overflow -fno-merge-all-constants -fmerge-constants 
-fno-stack-check -fconserve-stack  -DMODULE  -DKBUILD_BASENAME='"test_xarray"' 
-DKBUILD_MODNAME='"test_xarray"' /root/dive-in-kernel/h045_test_xarray/test_xarray.c | 
scripts/genksyms/genksyms    -r /dev/null > /root/dive-in-kernel/h045_test_xarray/.tmp_test_xarray.ver;
...
...
```

可以看到`gcc -D__KERNEL__`  ，其实几乎所有内核编译参数都包括它，对于

```
#ifdef __KERNEL__
some code
some code
#endif 
```

如果定义了`__KERNEL__` 则会多编译一段代码。而多编译的这一段代码是只有像内核才会用到的。一般用户态的程序编译参数是不会有`gcc -D__KERNEL__`的。


### 什么样的场景中会使用`__KERNEL__ `宏呢？

这样考虑一下：我为某个设备写了一个设备驱动，毫无疑问编译的时候肯定会加上`__KERNEL__`，然后这个驱动往往还要提供一个库文件，为应用程序提供访问某些变量或函数的接口。最后我们要写一个应用程序来操纵设备。那么在编写这个应用程序的时候假如库文件提供的东西还不够，比如库文件没有定义上述的`#define CLONE_DETACHED 0x00400000`，而库文件的API函数包含返回`CLONE_DETACHED` 的可能，那么就无法用`if(CLONE_DETACHED==fun(arg)) `来做判断了（当然你可以去扒内核代码去比较`0x004000000`）。

那么应用程序代码中肯定要包含这内核头文件了（现在不推荐这样做了），那么就出现了一个问题，让应用程序引用内核头文件会暴露很多内核的细节和增加目标文件的大小，因为很多内核结构或变量，应用程序几乎用不着。那么就要设置一个边界，设定哪些是只有给内核代码可见的，哪些是开放给所有代码可见的。 这个边界就是`__KERNEL__` 宏。其实实际的做法是所有该引用的内核头文件，变量或结构都要库的头文件中包含，这些属于内核的东东往往要重新定义在库的头文件中，然后再提供给应用程序去引用。

### 参考文章

* https://lp007819.wordpress.com/2011/07/24/__kernel__-%e5%ae%8f%e4%bd%9c%e7%94%a8%e6%98%af%e4%bb%80%e4%b9%88%ef%bc%9f/
