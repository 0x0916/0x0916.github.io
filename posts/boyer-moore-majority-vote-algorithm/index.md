[Boyer-Moore majority vote algorithm][1](摩尔投票算法)是一种在线性时间`O(n)`和空间复杂度的情况下，在一个元素序列中查找包含最多的元素。它是以`Robert S.Boyer`和`J Strother Moore`命名的，1981年发明的，是一种典型的流算法(`streaming algorithm`)。

在它最简单的形式就是，查找最多的元素，也就是在输入中重复出现超过一半以上(`n/2`)的元素。


<!--more-->

### 基本的摩尔投票问题

> 找出一组数字序列中出现次数大于总数1/2的数字（并且假设这个数字一定存在）。显然这个数字只可能有一个。摩尔投票算法是基于这个事实：每次从序列里选择两个不相同的数字删除掉（或称为“抵消”），最后剩下一个数字或几个相同的数字，就是出现次数大于总数一半的那个。


实现的算法从第一个数开始扫描整个数组，有两个变量**major**和**count**。其实这两个变量想表达的是一个**隐形的数组array**，`array`存储的是“当前暂时无法删除的数字”，我们先不要管`major`和`count`，只考虑这个`array`，同时再维护一个结果数组`result`，`result`里面存储的是每次删除一对元素之后的当前结果。

为了方便理解举一个示例输入：{1,2,1,3,1,1,2,1,5}

* 从第一个数字1开始，我们想要把它和一个不是1的数字一起从数组里抵消掉，但是目前我们只扫描了一个1，所以暂时无法抵消它，把它加入到array，array变成了{1}，result由于没有抵消任何元素所以还是原数组{1,2,1,3,1,1,2,1,5}。
* 然后继续扫描第二个数，是2，我们可以把它和一个不是2的数字抵消掉了，因为我们之前扫描到一个1，所以array变成了{},result变成了{1,3,1,1,2,1,5}
* 继续扫描第三个数1，无法抵消，于是array变成了{1},result还是{1,3,1,1,2,1,5};
* 接下来扫描到3,可以将3和array数组里面的1抵消,于是array变成了{},result变成了{1,1,2,1,5}
* 接下来扫描到1，此时array为空，所以无法抵消这个1，array变成了{1},result还是{1,1,2,1,5}
* 接下来扫描到1，此时虽然array不为空，但是array里也是1，所以还是无法抵消，把它也加入这个array,于是array变成了{1,1}（其实到这我们可以发现，array里面只可能同时存在一种数，因为只有array为空或当前扫描到的数和array里的数字相同时才把这个数字放入array）,result还是{1,1,2,1,5}
* 接下来扫描到2，把它和一个1抵消掉，至于抵消哪一个1，无所谓，array变成了{1},result是{1,1,5}
* 接下来扫描到1，不能抵消，array变成了{1,1}，result{1,1,5}
* 接下来扫描到5，可以将5和一个1抵消，array变成了{1},result变成了{1}


至此扫描完成了数组里的所有数，result里剩了1，所以1就是大于一半的数组。

再回顾一下这个过程，其实就是删除（抵消）了（1，2），（1，3），（1，5）剩下了一个1。

除去冗余关系：实际代码中没有`array`，也没有`result`，因为我们不需要。由于前面提到`array`里只可能同时存储一种数字，所以我们用major来表示当前`array`里存储的数，`count`表示`array`的长度,即目前暂时无法删除的元素个数，最后扫描完所有的数字，`array`和`result`变成一样了，都表示**最后还是无法删除的数字**。



我们再根据只有两个变量的实际代码理一遍：

major 初始化随便一个数，
count 初始化为0
输入：{1,2,1,3,1,1,2,1,5}

* 扫描到1，count是0（没有元素可以和当前的1抵消），于是major = 1，count = 1（此时有1个1无法被抵消）
* 扫描到2，它不等于major，于是可以抵消掉一个major => count -= 1，此时count = 0,其实可以理解为扫到的元素都抵消完了，这里可以暂时不改变major的值
* 扫描到1，它等于major，于是count += 1 => count = 1
* 扫描到3，它不等于major，可以抵消一个major => count -= 1 => count = 0，此时又抵消完了(实际的直觉告诉我们，扫描完前四个数，1和2抵消了，1和3抵消了)
* 扫描到1，它等于major，于是count += 1 => count = 1
* 扫描到1，他等于major，无法抵消 => count += 1 => count = 2 (扫描完前六个数，剩两个1无法抵消)
* 扫描到2，它不等于major，可以抵消一个major => count -= 1 => count = 1,此时还剩1个1没有被抵消
* 扫描到1，它等于major，无法抵消 => count += 1 => count = 2
* 扫描到5，它不等于major，可以抵消一个major => count -= 1 => count = 1

至此扫描完成，还剩1个1没有被抵消掉，它就是我们要找的数。

###  算法形式化描述

```
Initialize an element m and a counter i with i = 0
For each element x of the input sequence:
		If i = 0, then assign m = x and i = 1
		else if m = x, then assign i = i + 1
		else assign i = i − 1
Return m
```

一般在实践中，根据具体情况，可以判断最后找到的m的出现次数是否超过一半，如果未超过一半，则返回-1，所以有如下的形式化描述：

```
Initialize an counter n with n = 0
Initialize an element m and a counter i with i = 0
For each element x of the input sequence:
		n++
		If i = 0, then assign m = x and i = 1
		else if m = x, then assign i = i + 1
		else assign i = i − 1
		
Initialize an counter mcount with mcount = 0		
For each element x of the input sequence:
		if m = x, then mcount++

if mcount > len(n/2), then return m
else return -1
```

### C实现

```c

#include <stdio.h>


int majority_element(int array[], int len);

int main(int argc, char **argv)
{

	int a[] = {2, 2, 1, 1, 1, 2, 1};
	int b[] = {2, 2, 1, 1, 1, 2, 3, 3, 3};
	int c[] = {2, 2, 1, 2, 1, 2};
	int d[] = {2, 2, 1, 1, 1, 2};

	printf("a[] = {2, 2, 1, 1, 1, 2, 1}\n");
	printf("b[] = {2, 2, 1, 1, 1, 2, 3, 3, 3}\n");
	printf("c[] = {2, 2, 1, 2, 1, 2}\n");
	printf("d[] = {2, 2, 1, 1, 1, 2}\n");
	printf("major element in a[] is %d\n", majority_element(a, 7));
	printf("major element in b[] is %d\n", majority_element(b, 9));
	printf("major element in c[] is %d\n", majority_element(c, 6));
	printf("major element in d[] is %d\n", majority_element(d, 6));
	return 0;
}


int majority_element(int array[], int len)
{
	int major = 0, count = 0;
	int i;
	int num = 0;

	for (i = 0 ; i < len; i++) {
		if (count == 0) {
			major = array[i];
			count = 1;
		} else if (major == array[i]) {
			count++;
		} else {
			count--;
		}
	}

	for (i = 0; i < len; i++) {
		if (array[i] == major)
			num++;
	}

	if (num > len/2)
		return major;
	return -1;
}

```


保存以上代码到`main.c`文件中，编译并执行，结果如下：

```bash
# gcc main.c -o majority-vote-algorithm
# ./majority-vote-algorithm 
a[] = {2, 2, 1, 1, 1, 2, 1}
b[] = {2, 2, 1, 1, 1, 2, 3, 3, 3}
c[] = {2, 2, 1, 2, 1, 2}
d[] = {2, 2, 1, 1, 1, 2}
major element in a[] is 1
major element in b[] is -1
major element in c[] is 2
major element in d[] is -1
```

[1]: https://en.wikipedia.org/wiki/Boyer%E2%80%93Moore_majority_vote_algorithm
