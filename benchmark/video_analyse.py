with open('AP.txt', 'r') as file:
    # 逐行读取文件内容
    lines = file.readlines()

# 初始化空列表以存储第一列和第二列的数据
name1 = []
ap1 = []

# 遍历每一行并提取数据
for line in lines:
    # 使用空格分割每一行
    parts = line.split()

    # 获取第一列和第二列的数据，并将第二列转换为浮点数
    name1.append(parts[0])
    ap1.append(float(parts[1]))

# 打印结果
# print("Column 1:", name1)
# print("Column 2:", ap1)

with open('AP_k20_thre24.txt', 'r') as file:
    # 逐行读取文件内容
    lines = file.readlines()

# 初始化空列表以存储第一列和第二列的数据
name2 = []
ap2 = []

# 遍历每一行并提取数据
for line in lines:
    # 使用空格分割每一行
    parts = line.split()

    # 获取第一列和第二列的数据，并将第二列转换为浮点数
    name2.append(parts[0])
    ap2.append(float(parts[1]))

count = 0
for i in range(len(ap2)):
    if ap1[i] > ap2[i]:
        count+=1

print(count)

ap_better = []
for i in range(len(ap2)):
    if ap1[i] > ap2[i]:
        ap_better.append(ap1[i])
    else:
        ap_better.append(ap2[i])

print(len(ap_better))

average = sum(ap_better) / len(ap_better)
print(average)