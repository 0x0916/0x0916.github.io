在内存管理和调度负载均衡中，有许多代码逻辑要遍历`node`上的**内存**和**cpu**信息，加上现在的内核都支持内存和`cpu`的热插拔，所以系统上`node`的状态在内核上要有专门的数据结构进行描述。

本文就研究一下用于描述`node`信息的数据结构。

<!--more-->

![](./pic.jpg "")

### 系统环境

* 发行版：`centos7.5`
* 内核版本：[3.10.0-862.14.4.el7.x86_64](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.14.4.el7.src.rpm)
* 处理器：`40core（Intel(R) Xeon(R) CPU E5-2630 v4 @ 2.20GHz）`
* 内存：`128GB`，两个`NUMA node`

### 查看numa信息

我们知道，现在的服务器一般都是`NUMA`架构，通常包含两个`numa node`，每个`node`上都有与其比较近的`cpu`和内存，我们可以通过命令`numactl --hardware`查看信息：

```bash
$ numactl --hardware
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 3 4 5 6 7 8 9 20 21 22 23 24 25 26 27 28 29
node 0 size: 65133 MB
node 0 free: 16561 MB
node 1 cpus: 10 11 12 13 14 15 16 17 18 19 30 31 32 33 34 35 36 37 38 39
node 1 size: 65536 MB
node 1 free: 5572 MB
node distances:
node   0   1 
  0:  10  21 
  1:  21  10 
```

此外，在`linux`系统中，每个`node`的详细信息，可以通过目录`/sys/devices/system/node`进行查看：

```bash
 $ pwd
/sys/devices/system/node
 $ ls -l
total 0
-r--r--r-- 1 root root 4096 Jan  4 10:36 has_cpu
-r--r--r-- 1 root root 4096 Jan  4 10:36 has_memory
-r--r--r-- 1 root root 4096 Jan  4 10:36 has_normal_memory
drwxr-xr-x 4 root root    0 Nov 14 15:39 node0
drwxr-xr-x 4 root root    0 Nov 14 15:39 node1
-r--r--r-- 1 root root 4096 Jan  4 10:36 online
-r--r--r-- 1 root root 4096 Jan  4 10:36 possible
drwxr-xr-x 2 root root    0 Jan  3 16:51 power
-rw-r--r-- 1 root root 4096 Jan  4 10:36 uevent
```

### node_states 全局变量

`linux` 内核定义了一个全局变量`node_states`，其类型为`nodemask_t`:

```c
typedef struct { DECLARE_BITMAP(bits, MAX_NUMNODES); } nodemask_t;
nodemask_t node_states[NR_NODE_STATES] __read_mostly;
```

通过`crash`命令，我们可以看到在真实的服务器系统上，这些变量的实际定义：

```c
crash> whatis nodemask_t
typedef struct {
    unsigned long bits[16];
} nodemask_t;
SIZE: 128
crash> whatis node_states
nodemask_t node_states[5];
```

从上可以看出：

* `NR_NODE_STATES`的值为`5`，经过对比代码，目前系统上描述了以下几种资源
	* `N_POSSIBLE`： 描述对应的`node`上未来是否会`online`
	* `N_ONLINE`：描述对应的`node`是否`online`
	* `N_NORMAL_MEMORY`：描述对应的`node`是否有`normal memory`
	* `N_MEMORY`：描述对应的`node`是否有内存
	* `N_CPU`：描述对应的`node`上是否有`cpu`
* 通过`nodemask_t`可以看出，系统上最大支持`1024`（`16*64`）个node，其实，通过内核的`config`，也可以计算出系统最大支持`1024`个`node`，这里的`CONFIG_NODES_SHIFT`为`10`。

```c
#define NODES_SHIFT     CONFIG_NODES_SHIFT
#define MAX_NUMNODES    (1 << NODES_SHIFT)
```

我所查看的机器上有两个`node`，那么接下来我们通过`crash`查看一下`node_states`的值：

```
crash> p node_states
node_states = $1 = 
 {{
    bits = {3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
  }, {
    bits = {3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
  }, {
    bits = {3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
  }, {
    bits = {3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
  }, {
    bits = {3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
  }}
```
* 第一行3代表系统上只会有两个`node`，`node0`和`node1`
* 第二行3代表系统上目前`node0`和`node1`都是`online`的
* 第三行3代表系统上`node0`和`node1`都有`normal memory`
* 第四行3代表系统上`node0`和`node1`都有内存
* 第五行3代表系统上`node0`和`node1`上都有`cpu`


有了`node_states`后，我们就可以方便的遍历所有`node`，并且跳过那些已经不存在或者没有某些资源的`node`。

```c
//遍历所有可能的node结点
#define for_each_node(node)        for_each_node_state(node, N_POSSIBLE)
//遍历已经online的node结点
#define for_each_online_node(node) for_each_node_state(node, N_ONLINE)
//统计总的online状态的node结点个数
#define num_online_nodes()      num_node_state(N_ONLINE)
//统计总的可能得node结点个数
#define num_possible_nodes()    num_node_state(N_POSSIBLE)
//判断node结点是否online
#define node_online(node)       node_state((node), N_ONLINE)
//判断是否存在node结点
#define node_possible(node)     node_state((node), N_POSSIBLE)
//选择第一个online的node结点
#define first_online_node       first_node(node_states[N_ONLINE])
//选择第一个有内存的node结点
#define first_memory_node       first_node(node_states[N_MEMORY])
```
