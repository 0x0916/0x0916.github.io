
本文介绍了`linux`内核中经常出现的`current`宏，并分析其通用的实现方法，以及其在`x86-64`下的实现方法。

### current的作用

在内核中，访问任务通常需要获得指向其的`struct task_struct`指针。实际上，内核中大部分处理进程的代码都是通过`struct task_struct`进行的。因此，通过`current`宏查找当前正在运行进程的进程描述符就显得尤为重要。硬件体系不同，该宏的实现方式也就不同。有的硬件体系结构可以专门拿出一个寄存器存放指向当前进程的`struct task_struct`指针，用于加快访问速度。而有些像`x86`这样的体系结构（其寄存器并不富余），就只能在内核栈的底端创建`struct thread_info`结构，通过计算偏移间接地查找`struct task_struct`结构。

### current的通用实现方法

所以通过`esp`寄存器的值和内核栈大小，就可以方便的计算出内核栈的栈底地址，该地址其实就是进程对应的`struct thread_info`结构的地址。相关代码如下：

```c
#ifndef __ASM_GENERIC_CURRENT_H
#define __ASM_GENERIC_CURRENT_H

#include <linux/thread_info.h>

#define get_current() (current_thread_info()->task)
#define current get_current()

#endif /* __ASM_GENERIC_CURRENT_H */


/* how to get the current stack pointer from C */ 
register unsigned long current_stack_pointer asm("esp") __used; 

/* how to get the thread information struct from C */ 
static inline struct thread_info *current_thread_info(void)                 
{
        return (struct thread_info *)
                (current_stack_pointer & ~(THREAD_SIZE - 1));
}
```

### current在x86架构上的实现

理解了如上信息后，x86架构进一步对`current`宏进行了优化实现：

```c
#ifndef _ASM_X86_CURRENT_H
#define _ASM_X86_CURRENT_H

#include <linux/compiler.h>
#include <asm/percpu.h>

#ifndef __ASSEMBLY__
struct task_struct;

DECLARE_PER_CPU(struct task_struct *, current_task);

static __always_inline struct task_struct *get_current(void)
{
        return this_cpu_read_stable(current_task);
}

#define current get_current()

#endif /* __ASSEMBLY__ */

#endif /* _ASM_X86_CURRENT_H */
```

在`x86`体系结构中，使用了`current_task`这个每CPU变量，来存储当前正在使用`cpu`的进程的`struct task_struct`。
由于采用了每`cpu`变量`current_task`来保存当前运行进程的`task_struct`，所以在进程切换时，就需要更新该变量。

在`arch/x86/kernel/process_64.c`文件中的`__switch_to`函数中有如下代码：
```c
this_cpu_write(current_task, next_p);  
```


> 注意：在早期的内核中，通过`current_thread_info()->task`得到`struct task_struct`在x86上也是支持的。不过在最新的内核中，该方法已经不支持了。
	因为新版本的内核中`thread_info`中已经不存在`task`这个成员了。
```c
struct thread_info {
	unsigned long flags;
	u32 status;
}
SIZE: 16
```


### 实验示例

> 注意：本示例是在x86支持`current_thread_info()->task`的内核上进行的

#### x86支持`current_thread_info()->task`方式

```c?linenums
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/sched.h>

static int __init test_thread_info_init(void)
{
        struct thread_info *ti = NULL;
        struct task_struct *head = NULL;

        printk(KERN_ALERT "[Hello] test_thread_info \n");
        ti = (struct thread_info*)((unsigned long)&ti & ~(THREAD_SIZE - 1));
        head = ti->task;

        printk("kernel stack size = %lx\n", THREAD_SIZE);
        printk("name is %s\n", head->comm);

        return 0;
}

static void __exit test_thread_info_exit(void)
{
        printk(KERN_ALERT "[Goodbye] test_thread_info\n");
}

module_init(test_thread_info_init);
module_exit(test_thread_info_exit);
MODULE_LICENSE("GPL");
```
* 上述模块初始化代码中，`ti`作为局部变量，存储在内核栈中，所以`12`行代码可以获取`struct thread_info`结构体的地址。
* 插入模块，打印出进程的名称`insmod`，说明结果符合预期。

#### 验证一下`task_current`和`thread_info`的关系

实验方法：
（1）启动一个stress进程，持续占用CPU。

```bash
# stress -c 1
```

（2）获得stress进程的进程号，使用taskset将其绑定到cpu1上。

```bash
# ps aux | grep stress
root      3427  0.0  0.0   7308   424 pts/2    S+   15:25   0:00 stress -c 1
root      3428 99.9  0.0   7308   100 pts/2    R+   15:25   6:21 stress -c 1
root      3918  0.0  0.0 112708   968 pts/3    S+   15:31   0:00 grep --color=auto stress
 # taskset -p 02 3428
pid 3428's current affinity mask: f
pid 3428's new affinity mask: 2
```

此时，我们可以通过`crash`查看这些数据的关系：
```
crash> p current_task:1
per_cpu(current_task, 1) = $1 = (struct task_struct *) 0xffff95c498211fc0
crash> task_struct.comm 0xffff95c498211fc0
  comm = "stress\000\000\060\000\000\000\000\000\000"
crash> task_struct.stack 0xffff95c498211fc0
  stack = 0xffff95c407c28000
crash> thread_info.task 0xffff95c407c28000
  task = 0xffff95c498211fc0 
```
* `cpu1`上正在执行的进程的描述符地址为：`0xffff95c498211fc0`。
* 其进程名称为我们期望的`stress`。
* 通过描述符的`stack`域，可以得到进程的栈底地址为：`0xffff95c407c28000`，其实也就是`thread_info`的地址。
* 通过`thread_info`的`task`域可以看出，其值和`current_task:1`的值一样。
