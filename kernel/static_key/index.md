
本节介绍了`static_key`这个内核基础设施。

<!--more-->
![](pic.jpg "")

### 理解问题

在`linux`内核中，`control cgroup`是实现容器的核心技术之一，在`control cgroup`中有一个叫做`cpu cgroup`的子系统，它用来限制一组进程的`cpu`使用量。为了达到限制的目的，就需要对进程单位时间内使用的`cpu`时间进行统计，而统计会耗费一定的代价，所以内核设计者为了减少系统损耗，只有当系统启用了`cpu cgroup`且被设置了`cpu`限制时，采用执行统计`cpu`时间信息的代码。


内核中有一个全局的变量`__cfs_bandwidth_used`，初始化时，其值为`0`，
```
crash> p __cfs_bandwidth_used
__cfs_bandwidth_used = $1 = {
  enabled = {
    counter = 0
  }, 
  entries = 0xffffffffa9521640, 
  next = 0x0
}
crash> 
```
当创建了一个新的`cpu cgroup`,并且设置`cpu quota`，其值加`1`:

```
# cd /sys/fs/cgroup/cpu
# mkdir test
# echo 100000 > test/cpu.cfs_quota_us 
```
查看`__cfs_bandwidth_used`的值
```
crash> p __cfs_bandwidth_used
__cfs_bandwidth_used = $2 = {
  enabled = {
    counter = 1
  }, 
  entries = 0xffffffffa9521640, 
  next = 0x0
}
```

当取消对该`cpu cgoup`的`cpu`限制时，该值减少`1`

```
# echo -1 > test/cpu.cfs_quota_us 
```
查看`__cfs_bandwidth_used`的值

```
crash> p __cfs_bandwidth_used
__cfs_bandwidth_used = $3 = {
  enabled = {
    counter = 0
  }, 
  entries = 0xffffffffa9521640, 
  next = 0x0
}
```

在内核代码中，就是通过判断`__cfs_bandwidth_used`的值是否为`0`，来决定是否需要执行相关`cpu`时间的统计代码。

* `__cfs_bandwidth_used`的值为0， 不执行时间统计相关代码
* `__cfs_bandwidth_used`的值为非0，执行时间统计相关代码




由于调度代码比较核心，在里面判断`__cfs_bandwidth_used`是否为`0`也有一定的开销，所以内核开发者为了优化，利用编译器的特性，就有了`static_key`这个机制了。

### static_key机制

简单来说，如果你对代码性能很敏感，而且大多数情况下分支路径是确定的，可以考虑使用`static keys`。`static keys`可以代替普通的变量进行分支判断，目的是用来优化频繁使用`if-else`判断的问题，这里涉及到指令分支预取的一下问题。简单地说，现代`cpu`都有预测功能，变量的判断有可能会造成硬件预测失败，影响流水线性能。虽然有`likely`和`unlikely`，但还是会有小概率的预测失败。

#### 定义一个static_key

```c
struct static_key key = STATIC_KEY_INIT_FALSE; 
```

注意：这个`key`及其初始值必须是静态存在的，不能定义为局部变量或者使用动态分配的内存。通常为全局变量或者静态变量。
其中的`STATIC_KEY_INIT_FALSE`表示这个`key`的默认值为`false`，对应的分支默认不进入，如果是需要默认进入的，用`STATIC_KEY_INIT_TRUE`，这里如果不赋值，系统默认为`STATIC_KEY_INIT_FALSE`，在代码运行中不能再用`STATIC_KEY_INIT_FALSE/STATIC_KEY_INIT_TRUE`进行赋值。 


#### 判断语句

对于默认为`false（STATIC_KEY_INIT_FALSE）`的，使用

```c
if (static_key_false(&key))
	do unlikely code
else
	do likely code
```

对于默认为`true（STATIC_KEY_INIT_TRUE）`的，使用

```c
if (static_key_true((&static_key))) 
	do the likely work; 
else 
	do unlikely work
```

#### 修改判断条件 

使用`static_key_slow_inc`让分支条件变成`true`，使用`static_key_slow_dec`让分支条件变成`false`，与其初始的默认值无关。该接口是带计数的， 也就是：

* 初始值为`STATIC_KEY_INIT_FALSE`的，那么： `static_key_slow_inc; static_key_slow_inc; static_key_slow_dec` 那么 
`if (static_key_false((&static_key)))`对应的分支会进入，而再次`static_key_slow_dec`后，该分支就不再进入了。 
* 初始值为`STATIC_KEY_INIT_TRUE`的，那么： 
`static_key_slow_dec; static_key_slow_dec; static_key_slow_inc` 那么 
`if (static_key_true((&static_key)))`对应的分支不会进入，而再次`static_key_slow_inc`后，该分支就进入了。

#### static-key的内核实现

`static_key_false`的实现：

对`X86`场景其实现如下，其它架构下的实现类似。 
```
static __always_inline bool static_key_false(struct static_key *key)
{
        return arch_static_branch(key);
}

static __always_inline bool arch_static_branch(struct static_key *key)                                               
{                                                                                                                    
        asm_volatile_goto("1:"                                                                                       
                ".byte " __stringify(STATIC_KEY_INIT_NOP) "\n\t"                                                     
                ".pushsection __jump_table,  \"aw\" \n\t"                                                            
                _ASM_ALIGN "\n\t"
                _ASM_PTR "1b, %l[l_yes], %c0 \n\t"
                ".popsection \n\t"
                : :  "i" (key) : : l_yes);
        return false;
l_yes:
        return true;
}
```

*  其中的`asm_volatile_goto`宏 使用了`asm goto`，是`gcc`的特性，其允许在嵌入式汇编中`jump`到一个`C`语言的`label`，详见`gcc`的`manual`(https://gcc.gnu.org/onlinedocs/gcc/Extended-Asm.html)， 但是本处其作用只是将`C`语言的`label “l_yes”`传递到嵌入式汇编中。 
*  ` STATIC_KEY_INITIAL_NOP`其实就是`NOP`指令 
* ` .pushsection __jump_table`是通知编译器，以下的内容写入到段`“__jump_table”` 
*  `_ASM_PTR “1b, %l[l_yes], %c0`，是往段`“__jump_table”`中写入`label “1b”、C label “l_yes”`和输入参数`struct static_key *key`的地址，这些信息对应于`struct jump_entry` 中的`code`、`target`、`key`成员，在后续的处理中非常重要。 
* ` .popsection`表示以下的内容回到之前的段，其实多半就是`.text`段。 

可见，以上代码的作用就是：执行`NOP`指令后返回`false`，同时把`NOP`指令的地址、代码`”return true”`对应地址、`struct static_key *key`的地址写入到段`“__jump_table”`。由于固定返回为`false`且为`always inline`，编译器会把 
```
if (static_key_false((&static_key))) 
do the unlikely work; 
else 
do likely work 
```
优化为： 
```
nop 
do likely work 
retq 
l_yes: 
do the unlikely work; 
```
正常场景，就没有判断了。


`static_key_true`的实现：
```
static __always_inline bool static_key_true(struct static_key *key)                                               
{                                    
        return !static_key_false(key);                                                                               
}
``` 

执行`static_key_slow_inc(&key)`后，底层通过`gcc`提供的`goto`功能，再结合`c`代码编写的动态修改内存功能，就可以让使用`key`的代码从执行`false`分支变成执行`true`分支。当然这个更改代价时比较昂贵的，不是所有的情况都适用。

### 参考文章

* https://blog.csdn.net/phenix_lord/article/details/49232297

