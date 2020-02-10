
本文介绍了如何使用内核的`dynamic debug (dyndbg) `特性。

<!--more-->
![](pic.jpg "")

### 介绍

`Dynamic debug` 允许内核开发者动态地使能或者关闭内核输出。

当打开了内核配置选项`CONFIG_DYNAMIC_DEBUG`， 内核中的`pr_debug()/dev_dbg()`和`print_hex_dump_debug()/print_hex_dump_bytes()`就使用了`Dynamic debug`特性。

当未打开了内核配置选项`CONFIG_DYNAMIC_DEBUG`:

* `printk`就退化成`printk(KERN_DEBUG)`
* `print_hex_dump_debug()` 就退化成`print_hex_dump(KERN_DEBUG)`
* `dev_dbg`就退化为空。

`Dynamic debug`在`debugfs`中有个控制文件节点：`/sys/kernel/debug/dynamic_debug/control`。它记录了所有使用`Dynamic debug`技术的文件路径、行号、模块名称、函数名称和要打印的语句。

### 查看dynamic debug的行为

我们可以通过向读文件`/sys/kernel/debug/dynamic_debug/control`来查看目前系统上`Dynamic debug`的配置。
如下所示：

```
# cat /sys/kernel/debug/dynamic_debug/control | head
# filename:lineno [module]function flags format
init/main.c:765 [main]do_one_initcall_debug =p "initcall %pF returned %d after %lld usecs\012"
init/main.c:758 [main]do_one_initcall_debug =p "calling  %pF @ %i\012"
init/main.c:729 [main]initcall_blacklisted =p "initcall %s blacklisted\012"
init/main.c:705 [main]initcall_blacklist =p "blacklisting initcall %s\012"
arch/x86/events/intel/core.c:4235 [core]fixup_ht_bug =_ "failed to disable PMU erratum BJ122, BV98, HSD29 workaround\012"
arch/x86/events/intel/pt.c:726 [pt]pt_topa_dump =_ "# entry @%p (%lx sz %u %c%c%c) raw=%16llx\012"
arch/x86/events/intel/pt.c:717 [pt]pt_topa_dump =_ "# table @%p (%016Lx), off %llx size %zx\012"
arch/x86/kernel/tboot.c:103 [tboot]tboot_probe =_ "tboot_size: 0x%x\012"
arch/x86/kernel/tboot.c:102 [tboot]tboot_probe =_ "tboot_base: 0x%08x\012"
```

### 控制dynamic debug的行为

我们可以通过向文件`/sys/kernel/debug/dynamic_debug/control`中写入一定的指令，来使能或者关闭输出。 例如：使能文件`svcsock.c`中`1603`行的输出。
```
# echo 'file svcsock.c line 1603 +p' >
                              /sys/kernel/debug/dynamic_debug/control
```

控制打印时，还可以使用flags更来定义更详细的输出信息，目前支持的flags如下：

```
p    enables the pr_debug() callsite.
f    Include the function name in the printed message
l    Include line number in the printed message
m    Include module name in the printed message
t    Include thread ID in messages not generated from interrupt context
_    No flags are set. (Or'd with others on input)
```

### Examples

```
// 打开svcsock.c中第1603行的动态输出
# echo -n 'file svcsock.c line 1603 +p' > /sys/kernel/debug/dynamic_debug/control

// 打开svcsock.c文件中所有的动态输出
# echo -n 'file svcsock.c +p' > /sys/kernel/debug/dynamic_debug/control

// 打开NFS服务模块中所有的动态输出
# echo -n 'module nfsd +p' > /sys/kernel/debug/dynamic_debug/control

// 打开函数svc_process中所有的动态输出
# echo -n 'func svc_process +p' > /sys/kernel/debug/dynamic_debug/control

// 关闭函数svc_process中所有的动态输出
# echo -n 'func svc_process -p' > /sys/kernel/debug/dynamic_debug/control

// 打开文件路径中包含usb的文件里的所有的动态输出
# echo -n '*usb* +p' > /sys/kernel/debug/dynamic_debug/control

// 打开所有的动态输出
# echo -n '+p' > /sys/kernel/debug/dynamic_debug/control

// 为所有使能的动态输出信息中添加模块和函数名信息
# echo -n '+mf' > /sys/kernel/debug/dynamic_debug/control
```

### 实验

#### 编写内核模块

`dynamic_printk.c`文件内容：

```c
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kthread.h>
#include <linux/delay.h>

static struct task_struct *mythread;
static int exit = 0;
static int my_function(void *unused)
{
	while(!exit) {
		pr_debug("just print this message\n");
		msleep(2000);
	}

	return 0;
}
static int __init dynamic_printk_init(void)
{
	printk(KERN_ALERT "[Hello] dynamic_printk \n");

	// Create the kernel thread with name "MyThread"
	mythread = kthread_create(my_function, NULL, "MyThread");
	if (mythread) {
		printk(KERN_ALERT "Thread created successfully\n");
		wake_up_process(mythread);
	} else {
		printk(KERN_ALERT "Thread creation failed\n");
	}

	return 0;
}

static void __exit dynamic_printk_exit(void)
{
	exit = 1;
	msleep(3000);
	printk(KERN_ALERT "[Goodbye] dynamic_printk\n");
}

module_init(dynamic_printk_init);
module_exit(dynamic_printk_exit);
MODULE_LICENSE("GPL");
```

`Makefile`内容：

```
ifneq ($(KERNELRELEASE), )
obj-m := dynamic_printk.o
else
KERNELDIR ?=/lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)
all:
        $(MAKE) -C $(KERNELDIR) M=$(PWD) modules
clean:
        $(MAKE) -C $(KERNELDIR) M=$(PWD) clean 
```

#### 编译模块，并加载到内核中

```
root@localhost # make
root@localhost # insmod dynamic_printk.ko
```

#### 实验开始

默认情况下，模块中的`pr_debug`并不会输出任何内容，我们可以在`/sys/kernel/debug/dynamic_debug/control `文件中看到其信息：

```bash
/root/dive-in-kernel/h035_dynamic_printk/dynamic_printk.c:17 [dynamic_printk]my_function =_ "just print this message\012"
```

打开该动态输出

```bash
root@localhost # echo -n "file /root/dive-in-kernel/h035_dynamic_printk/dynamic_printk.c +pflm" > /sys/kernel/debug/dynamic_debug/control
```

`dmesg`中输出如下信息：
```
[268243.607925] dynamic_printk:my_function:17: just print this message
[268245.617781] dynamic_printk:my_function:17: just print this message
[268247.622379] dynamic_printk:my_function:17: just print this message
[268249.628472] dynamic_printk:my_function:17: just print this message
[268251.645144] dynamic_printk:my_function:17: just print this message
```

关闭输出模块信息：

```bash
root@localhost # echo -n "file /root/dive-in-kernel/h035_dynamic_printk/dynamic_printk.c -m" > /sys/kernel/debug/dynamic_debug/control
```

`dmesg`中输出如下信息：

```
[268302.145178] my_function:17: just print this message
[268304.177223] my_function:17: just print this message
[268306.177942] my_function:17: just print this message
[268308.198624] my_function:17: just print this message
[268310.201056] my_function:17: just print this message
```

关闭输出信息：
```bash
root@localhost #  echo -n "file /root/dive-in-kernel/h035_dynamic_printk/dynamic_printk.c -p" > /sys/kernel/debug/dynamic_debug/control  
```

###  参考文档

* https://www.kernel.org/doc/html/latest/admin-guide/dynamic-debug-howto.html
