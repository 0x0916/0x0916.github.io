
本文首先介绍了读写信号量，然后介绍了其`API`，接着以一个实验的形式，给大家展示了读写信号量内部的`count`值的含义。只有明白了`count`的含义，我们在分析问题时才能得心应手。 

<!--more-->
![](./pic.jpg "")

### 系统环境

* 发行版：`centos7.5 `（Virtual Box虚拟机）
* 内核版本：[3.10.0-862.14.4.el7.x86_64](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.14.4.el7.src.rpm)
* 处理器：`Intel(R) Core(TM) i7-4770HQ CPU @ 2.20GHz`
* 内存：`4GB`

### 读写信号量介绍

读写信号量对访问者进行了细分，或者为**读者**，或者为**写者**，读者在持有读写信号量期间只能对该读写信号量保护的共享资源进行读访问，如果一个任务除了需要读，可能还需要写，那么它必须被归类为写者，它在对共享资源访问之前必须先获得写者身份，写者在发现自己不需要写访问的情况下可以降级为读者。读写信号量同时拥有的读者数不受限制，也就说可以有任意多个读者同时拥有一个读写信号量。

如果一个读写信号量当前没有被写者拥有并且也没有写者等待读者释放信号量，那 么任何读者都可以成功获得该读写信号量；否则，读者必须被挂起直到写者释放该信号量。如果一个读写信号量当前没有被读者或写者拥有并且也没有写者等待该信号量，那么一个写者可以成功获得该读写信号量，否则写者将被挂起，直到没有任何访问者。因此，写者是排他性的，独占性的。

读写信号量有两种实现：

* 一种是通用的，不依赖于硬件架构，因此，增加新的架构不需要重新实现它，但缺点是性能低，获得和释放读写信号量的开销大；
* 另一种是架构相关的，因此性能高，获取和释放读写信号量的开销小，但增加新的架构需要重新实现。在内核配置时，可以通过选项去控制使用哪一种实现。


### 读写信号量的相关`API`：

| API | |
|---|---|
|`DECLARE_RWSEM(name)`|该宏声明一个读写信号量`name`并对其进行初始化。|
|`void init_rwsem(struct rw_semaphore *sem)`|该函数对读写信号量`sem`进行初始化。|
|`void down_read(struct rw_semaphore *sem)`|读者调用该函数来得到读写信号量`sem`。该函数会导致调用者睡眠，因此只能在进程上下文使用。|
|`int __must_check down_read_killable(struct rw_semaphore *sem);`||
|`int down_read_trylock(struct rw_semaphore *sem)`|该函数类似于`down_read`，只是它不会导致调用者睡眠。它尽力得到读写信号量`sem`，如果能够立即得到，它就得到该读写信号量，并且返回1，否则表示不能立刻得到该信号量，返回`0`。因此，它也可以在中断上下文使用。|
|`void down_write(struct rw_semaphore *sem)`|写者使用该函数来得到读写信号量`sem`，它也会导致调用者睡眠，因此只能在进程上下文使用。|
|`int __must_check down_write_killable(struct rw_semaphore *sem);`||
|`int down_write_trylock(struct rw_semaphore *sem)`|该函数类似于`down_write`，只是它不会导致调用者睡眠。该函数尽力得到读写信号量，如果能够立刻获得，就获得该读写信号量并且返回1，否则表示无法立刻获得，返回`0`。它可以在中断上下文使用。|
|`void up_read(struct rw_semaphore *sem)`|读者使用该函数释放读写信号量`sem`。它与`down_read`或`down_read_trylock`配对使用。如果`down_read_trylock`返回`0`，不需要调用`up_read`来释放读写信号量，因为根本就没有获得信号量。|
|`void up_write(struct rw_semaphore *sem)`|写者调用该函数释放信号量`sem`。它与`down_write`或`down_write_trylock`配对使用。如果`down_write_trylock`返回`0`，不需要调用`up_write`，因为返回`0`表示没有获得该读写信号量。|
|`void downgrade_write(struct rw_semaphore *sem)`|该函数用于把写者降级为读者，这有时是必要的。因为写者是排他性的，因此在写者保持读写信号量期间，任何读者或写者都将无法访问该读写信号量保护的共享资源，对于那些当前条件下不需要写访问的写者，降级为读者将，使得等待访问的读者能够立刻访问，从而增加了并发性，提高了效率。|



读写信号量适于在**读多写少**的情况下使用，在`linux`内核中对进程的**内存映像描述**结构的访问就使用了读写信号量进行保护。

在`Linux`中，每一个进程都用一个类型为`struct task_struct`的结构来描述，该结构的类型为`struct mm_struct`的字段`mm`描述了进程的内存映像，特别是`mm_struct`结构的`mmap`字段维护了整个进程的内存块列表，该列表将在进程生存期间被大量地遍历或修改。

因此`mm_struct`结构就有一个字段`mmap_sem`来对`mmap`的访问 进行保护，`mmap_sem`就是一个读写信号量，在`proc`文件系统里有很多进程内存使用情况的接口，通过它们能够查看某一进程的内存使用情况，命令 `free`、`ps`和`top`都是通过`proc`来得到内存使用信息的，`proc`接口就使用`down_read`和`up_read`来读取进程的`mmap`信息。

当进程动态地分配或释放内存时，需要修改`mmap`来反映分配或释放后的内存映像，因此动态内存分配或释放操作需要以写者身份获得读写信号量`mmap_sem`来对`mmap`进行更新。系统调用`brk`和`munmap`就使用了`down_write`和`up_write`来保护对`mmap`的访问。



### `kernel`中的定义

在`kernel`中，读写信号量的定义如下：

```c?linenums
/* All arch specific implementations share the same struct */
struct rw_semaphore {
        RH_KABI_REPLACE(long            count,
                        atomic_long_t   count)
        raw_spinlock_t  wait_lock;
        struct optimistic_spin_queue osq; /* spinner MCS lock */
        struct slist_head       wait_list;
        /*
         * Write owner. Used as a speculative check to see
         * if the owner is running on the cpu.
         */
        struct task_struct      *owner;
};
```
`wait_lock`用来保护链表`wait_list`，`wait_list`是一个链表，存放了所有的等待信号的进程，信号量的状态由`count`表示。


### `count`值分析

以下通过编写内核模块来演示`count`的值的变化情况，模块代码请移步[这里][1] ，该代码在[3.10.0-862.14.4.el7.x86_64](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.14.4.el7.src.rpm)上编译通过。

#### 初始化

读写信号量初始化时，`rw_semaphore.count`的值为`0x0000000000000000`。

#### `down_read` 和  `up_read`

* 当有一个`reader`持有时，其值为`0x0000000000000001`；
* 当有两个`reader`持有时，其值为`0x0000000000000002`;
* 当有`n`个`reader`持有时，其值为`0x000000000000000n`。
* 读写锁同时可以有多个`reader`

```bash
# cat /proc/rwsem_test 
semaphore.count: 0x0000000000000000
# echo "down_read A" > /proc/rwsem_test 
# cat /proc/rwsem_test                           
semaphore.count: 0x0000000000000001
# echo "down_read B" > /proc/rwsem_test
# cat /proc/rwsem_test
semaphore.count: 0x0000000000000002
# echo "down_read C" > /proc/rwsem_test
# cat /proc/rwsem_test 
semaphore.count: 0x0000000000000003
# echo "up_read C" > /proc/rwsem_test
# cat /proc/rwsem_test 
semaphore.count: 0x0000000000000002
# echo "up_read A" > /proc/rwsem_test
# cat /proc/rwsem_test
semaphore.count: 0x0000000000000001
# echo "up_read B" > /proc/rwsem_test
# cat /proc/rwsem_test
semaphore.count: 0x0000000000000000

```

#### `down_write` 和  `up_write`

* 当有`writer`持有时，且等待`wait_list`为空，其值为`0xffffffff00000001`；
* 当有`writer`持有时，且等待`wait_list`不为空，其值为`0xfffffffe00000001`
* 读写信号量同时只能有一个`writer`持有

```bash
# cat /proc/rwsem_test 
semaphore.count: 0x0000000000000000
# echo "down_write A" > /proc/rwsem_test 
# cat /proc/rwsem_test
semaphore.count: 0xffffffff00000001
# echo "down_write B" > /proc/rwsem_test
# cat /proc/rwsem_test
semaphore.count: 0xfffffffe00000001
        wait list: comm = B, type = RWSEM_WAITING_FOR_WRITE
# echo "down_write C" > /proc/rwsem_test
# cat /proc/rwsem_test
semaphore.count: 0xfffffffe00000001
        wait list: comm = B, type = RWSEM_WAITING_FOR_WRITE
        wait list: comm = C, type = RWSEM_WAITING_FOR_WRITE
# echo "up_write A" > /proc/rwsem_test
# cat /proc/rwsem_test
semaphore.count: 0xfffffffe00000001
        wait list: comm = C, type = RWSEM_WAITING_FOR_WRITE
# echo "up_write B" > /proc/rwsem_test 
# cat /proc/rwsem_test 
semaphore.count: 0xffffffff00000001
# echo "up_write C" > /proc/rwsem_test 
# cat /proc/rwsem_test 
semaphore.count: 0x0000000000000000

```

#### 其他情况下`count`的值

通过以下场景，我们理解一下`count`的值变化规律。其中`ABC`为读者，`DEF`为写者。

* 初始化时，`count`的值为`0x0000000000000000`,`wait_list`为空；
```
# cat /proc/rwsem_test 
semaphore.count: 0x0000000000000000
```
* 当`A`读者获取信号量后，`count`的值为：`0x0000000000000001`，`wait_list`为空；
```
# echo "down_read A" > /proc/rwsem_test 
# cat /proc/rwsem_test 
semaphore.count: 0x0000000000000001
```
* 当`B`读者获取信号量后，`count`的值为：`0x0000000000000002`，`wait_list`为空；
```
# echo "down_read B" > /proc/rwsem_test                                             # cat /proc/rwsem_test 
semaphore.count: 0x0000000000000002
```
* 当`D`写者尝试获取信号量时，由于读者没有释放，此时`count`的值为：`0xffffffff00000002`,`wait_list`为`D`写者；
```
# echo "down_write D" > /proc/rwsem_test 
# cat /proc/rwsem_test 
semaphore.count: 0xffffffff00000002
        wait list: comm = D, type = RWSEM_WAITING_FOR_WRITE
```
* 当`C`读者尝试获取信号量时，由于`AB`读者没有释放，此时`count`的值为：`0xffffffff00000002`,`wait_list`为`D`写者，`C`读者；
```
# echo "down_read C" > /proc/rwsem_test 
# cat /proc/rwsem_test 
semaphore.count: 0xffffffff00000002
        wait list: comm = D, type = RWSEM_WAITING_FOR_WRITE
        wait list: comm = C, type = RWSEM_WAITING_FOR_READ
```
* 当`E`写者尝试获取信号量时，由于`AB`读者没有释放，此时`count`的值为：`0xffffffff00000002`,`wait_list`为`D`写者，`C`读者，`E`写者；
```
# echo "down_write E" > /proc/rwsem_test 
# cat /proc/rwsem_test 
semaphore.count: 0xffffffff00000002
        wait list: comm = D, type = RWSEM_WAITING_FOR_WRITE
        wait list: comm = C, type = RWSEM_WAITING_FOR_READ
        wait list: comm = E, type = RWSEM_WAITING_FOR_WRITE
```
* `A`读者释放信号量，由于`B`读者没有释放，`count`的值为：`0xffffffff00000001`，`wait_list`为`D`写者，`C`读者，`E`写者；
```
# echo "up_read A" > /proc/rwsem_test   
# cat /proc/rwsem_test 
semaphore.count: 0xffffffff00000001
        wait list: comm = D, type = RWSEM_WAITING_FOR_WRITE
        wait list: comm = C, type = RWSEM_WAITING_FOR_READ
        wait list: comm = E, type = RWSEM_WAITING_FOR_WRITE
```
* `B`读者释放信号量（`count`值为`0xffffffff00000000`），此时`D`写者获取到信号量，`count`的值为：`0xfffffffe00000001`，`wait_list`为`C`读者，`E`写者；
```
# echo "up_read B" > /proc/rwsem_test   
# cat /proc/rwsem_test 
semaphore.count: 0xfffffffe00000001
        wait list: comm = C, type = RWSEM_WAITING_FOR_READ
        wait list: comm = E, type = RWSEM_WAITING_FOR_WRITE
```
* `D `写着释放信号量（`count`值为`0xffffffff00000000`），此时`C`读者获取到信号量，`count`的值为：`0xffffffff00000001`,
`wait_list`为`E`写者；
```
# echo "up_write D" > /proc/rwsem_test
# cat /proc/rwsem_test 
semaphore.count: 0xffffffff00000001
        wait list: comm = E, type = RWSEM_WAITING_FOR_WRITE
```
* `C`读者释放信号量（`count`值为`0xffffffff00000000`），此时`E`写者获取到信号量，`count`的值为: `0xffffffff00000001`,`wait_list`为空
```
# echo "up_read C" > /proc/rwsem_test 
# cat /proc/rwsem_test 
semaphore.count: 0xffffffff00000001
```
* `E`释放信号量，此时`count`的值为: `0x0000000000000000`,`wait_list`为空
 ```
# echo "up_write E" > /proc/rwsem_test      
# cat /proc/rwsem_test 
semaphore.count: 0x0000000000000000
 ```

通过以上场景，我们可以总结以下规律：

1. 当读者持有锁时，且没有写者等待时，后续的读者可以直接获取锁成功；
1. 当有一个写者等待时，后续的写者和读者都不能获取锁；
1. 当写者持有锁时，后续的写者和读者都不能获取锁；
1. 等待`wait_list`上，第一个都是写者；
1. 当写者释放锁时，等待`wait_list`上的第一个将会获取锁（不管其时读者还是写着）；

归纳一下`count`值的含义：

|count 值 | 含义 |
| ---|---|
|`0x0000000000000000`| 信号量没有被任何读者和写着持有，且没有读者和写者尝试获取信号量|
|`0x000000000000000X`| `X`个读者持有信号量，且没有写者尝试获取信号量|
|`0xffffffff0000000X`| `X`个读者持有信号量，且等待`list`不为空且包含写者|
|`0xffffffff00000001`| 一个读者持有信号量，等待`list`不为空且包含写者|
|`0xffffffff00000001`| 一个写者持有信号量，等待`list`为空|
|`0xfffffffe00000001`| 写着持有信号量，且等待`list`不为空|
|`0xffffffff00000000`| 代表等待`list`有读者或者写者，但是谁也没有获取到锁，一般是中间状态|

### `x86`实现细节分析

```c
/*
 * trylock for reading -- returns 1 if successful, 0 if contention
 */
int down_read_trylock(struct rw_semaphore *sem)
{
        int ret = __down_read_trylock(sem);

        if (ret == 1)
                rwsem_acquire_read(&sem->dep_map, 0, 1, _RET_IP_);
        return ret;
}
```

```c?linenums
/*
 * trylock for reading -- returns 1 if successful, 0 if contention
 */
static inline int __down_read_trylock(struct rw_semaphore *sem)
{
        long result, tmp;
        asm volatile("# beginning __down_read_trylock\n\t"
                     "  mov          %0,%1\n\t"
                     "1:\n\t"
                     "  mov          %1,%2\n\t"
                     "  add          %3,%2\n\t"
                     "  jle          2f\n\t"
                     LOCK_PREFIX "  cmpxchg  %2,%0\n\t"
                     "  jnz          1b\n\t"
                     "2:\n\t"
                     "# ending __down_read_trylock\n\t"
                     : "+m" (sem->count), "=&a" (result), "=&r" (tmp)
                     : "i" (RWSEM_ACTIVE_READ_BIAS)
                     : "memory", "cc");
        return result >= 0 ? 1 : 0;
}
```

* 第`7`和`16`行中的汇编代码是注释；
* 第`7`行中的`asm volatile`的含义如下：
	* `asm`表示要嵌入汇编代码，后续括号中的为汇编代码
	* `volatile`表示不需要`gcc`进行优化汇编代码
* 第8到15行为汇编代码
* 第17行为输出操作数,
	* `"+m" (sem->count)`，其中`+`表示此操作数是可读可写的，`m`表示`A memory operand is allowed, with any kind of address that the machine supports in general.`
	* `"=&a" (result)`，其中`=`表示此操作数是只写的，`&`此操作数独占其指定的寄存器，`a`表示寄存器约束，表示该操作数使用寄存器`%EAX`
	* `"=&r" (tmp)`，其中`r`表示寄存器约束，此时编译器会在通用寄存器中自动选择一个。
* 第18行为输入操作数
	* `"i" (RWSEM_ACTIVE_READ_BIAS)`，其中`i`的解释如下`An immediate integer operand (one with constant value) is allowed. This includes symbolic constants whose values will be known only at assembly time or later.`这里`RWSEM_ACTIVE_READ_BIAS`的值为`0x00000001L`
* 第20行为`Clobber/Modify`，即告诉`gcc`一些情况
	* `cc`表示汇编代码会改变`condition code register`
	* `memory`表示汇编代码会改变内存，从而提示编译器在汇编代码期间，不要值缓存到`cache`中。
* 另外，在汇编代码中，`%n`表示操作数，其按照输出操作数和输入操作数进行的顺序进行引用，从`0`开始编码。
	* 对应到本段代码中：`%0`代表`sem->count`，`%1`代表`result`，`%2`代表`tmp`，`%3`代表`RWSEM_ACTIVE_READ_BIAS`

这段代码编译后的结果如下：

```x86asm?linenums
crash>   dis down_read_trylock
0xffffffff8109c2a0 <down_read_trylock>: nopl   0x0(%rax,%rax,1) [FTRACE NOP]
0xffffffff8109c2a5 <down_read_trylock+5>:       push   %rbp
0xffffffff8109c2a6 <down_read_trylock+6>:       mov    %rsp,%rbp
0xffffffff8109c2a9 <down_read_trylock+9>:       mov    (%rdi),%rax
0xffffffff8109c2ac <down_read_trylock+12>:      mov    %rax,%rdx
0xffffffff8109c2af <down_read_trylock+15>:      add    $0x1,%rdx
0xffffffff8109c2b3 <down_read_trylock+19>:      jle    0xffffffff8109c2bc <down_read_trylock+28>
0xffffffff8109c2b5 <down_read_trylock+21>:      lock cmpxchg %rdx,(%rdi)
0xffffffff8109c2ba <down_read_trylock+26>:      jne    0xffffffff8109c2ac <down_read_trylock+12>
0xffffffff8109c2bc <down_read_trylock+28>:      not    %rax
0xffffffff8109c2bf <down_read_trylock+31>:      shr    $0x3f,%rax
0xffffffff8109c2c3 <down_read_trylock+35>:      pop    %rbp
0xffffffff8109c2c4 <down_read_trylock+36>:      retq   
```

该段代码的目的就是原子的给`rw_semaphore.count` 值加`1`，如果成功加`1`，则返回`1`，失败则返回`0`。

  [1]: https://github.com/datawolf/dive-in-kernel/tree/master/h020_rw_semaphore
