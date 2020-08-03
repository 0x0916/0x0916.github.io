内核里有很多代码里有类似`do{}while(0)`这样的写法，这个写法有两个不同的用法。
本文介绍了`do{}while(0)`的两个不同的用法。

<!--more-->

### 1.形成单独逻辑块（避免宏替换以后产生错误）

举个例子：（https://elixir.bootlin.com/linux/v2.6.39.4/source/include/net/udp.h#L211）

```
#define UDP6_INC_STATS_BH(net, field, is_udplite) 	    do { \
	if (is_udplite) SNMP_INC_STATS_BH((net)->mib.udplite_stats_in6, field);\
	else		SNMP_INC_STATS_BH((net)->mib.udp_stats_in6, field);  \
} while(0)
#define UDP6_INC_STATS_USER(net, field, __lite)		    do { \
	if (__lite) SNMP_INC_STATS_USER((net)->mib.udplite_stats_in6, field);  \
	else	    SNMP_INC_STATS_USER((net)->mib.udp_stats_in6, field);      \
} while(0)

#define UDPX_INC_STATS_BH(sk, field) \
	do { \
		if ((sk)->sk_family == AF_INET) \
			UDP_INC_STATS_BH(sock_net(sk), field, 0); \
		else \
			UDP6_INC_STATS_BH(sock_net(sk), field, 0); \
	} while (0);

```
先看前两个宏用了do {…} while(0) ，如果展开到第三个宏就是：
```
#define UDPX_INC_STATS_BH(sk, field) \
	do { \
		if ((sk)->sk_family == AF_INET) \
			do { \
					if (is_udplite) SNMP_INC_STATS_BH((net)->mib.udplite_stats_in6, field);\
				else		SNMP_INC_STATS_BH((net)->mib.udp_stats_in6, field);  \
			} while(0);
		else \
			 do { \
				if (__lite) SNMP_INC_STATS_USER((net)->mib.udplite_stats_in6, field);  \
				else	    SNMP_INC_STATS_USER((net)->mib.udp_stats_in6, field);      \
			} while(0);
	} while (0);

```
如果去掉前两个宏的do while去掉， 就变成：
```
#define UDPX_INC_STATS_BH(sk, field) \
	do { \
		if ((sk)->sk_family == AF_INET) \
					if (is_udplite) SNMP_INC_STATS_BH((net)->mib.udplite_stats_in6, field);\
				else		SNMP_INC_STATS_BH((net)->mib.udp_stats_in6, field);  \
		else \
				if (__lite) SNMP_INC_STATS_USER((net)->mib.udplite_stats_in6, field);  \
				else	    SNMP_INC_STATS_USER((net)->mib.udp_stats_in6, field);      \
	} while (0);

```
显而易见，else无法匹配，代码完全错乱，无法编译通过。
所以一般只要在宏定义中含有逻辑判断的情况，都要用do while去分割，这样比较安全，再修改代码也不需要会过头去重新匹配if else 等。

### 2. 精简判断分支（不使用goto语句）

比如如下代码
```
bool Execute()
{
	// 分配资源
	int *p = new int;
	bool bOk(true);// 执行并进行错误处理
	bOk = func1();
	if(!bOk) goto errorhandle;
	bOk = func2();
	if(!bOk) goto errorhandle;
	bOk = func3();
	if(!bOk) goto errorhandle;
	// ..........

	// 执行成功，释放资源并返回
	delete p;
	p = NULL;
	return true;
errorhandle:
	delete p;
	p = NULL;
	return false;
}

```
虽然正确的使用`goto`可以大大提高程序的灵活性与简洁性，但太灵活的东西往往是很危险的，它会让我们的程序捉摸不定，那么怎么才能避免使用`goto`语句，又能消除代码冗余呢，请看`do…while(0)`循环：
```
bool Execute()
{
	// 分配资源
	int *p = new int;bool bOk(true);
	do
	{
		// 执行并进行错误处理
		bOk = func1();
		if(!bOk) break;
		bOk = func2();
		if(!bOk) break;
		bOk = func3();
		if(!bOk) break;
		// ..........
	}while(0);

	// 释放资源
	delete p;
	p = NULL;
	return bOk;
}

```


### 参考文章
* https://lp007819.wordpress.com/2011/03/17/%e5%86%85%e6%a0%b8%e4%bb%a3%e7%a0%81%e5%a5%87%e6%8a%80%e6%b7%ab%e5%b7%a7-dowhile-%e5%ae%8f/
