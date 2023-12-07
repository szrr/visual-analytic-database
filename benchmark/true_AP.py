import numpy as np
from numpy import sort


file_path = 'AP.txt'
lines = []

with open(file_path, 'r') as file:
    lines = file.readlines()

# 处理每一行，将其拆分为列表
result_list = []

for line in lines:
    # 去除行尾的换行符
    line = line.strip()

    # 使用空格分割字符串
    line_elements = line.split()
    line_elements = line_elements[2::]

    # 将元素转换为适当的类型
    line_elements = [int(element) if element.isdigit() else element for element in line_elements]

    # 添加到结果列表
    if line_elements != []:
        result_list.append(line_elements)

# print(result_list)

# for i in range(len(result_list)):
#     print(len(result_list[i]))

AP = []
for i in range(len(result_list)):
    search_video = result_list[i][0]
    search_index = int(result_list[i][1])
    # print(search_video, search_index)
    rank = []

    for j in range( int(len(result_list[i])/2) - 1):
        index = int(result_list[i][j*2+3])
        # print(index)
        if index != -1 and search_index != -1 and index > search_index:
            rank.append(index-1)
        else:
            rank.append(index)
    rank = sort(np.array(rank))
    print(rank)

    sum_ = 0.0
    relevant_retrievals = 0
    for j in range(len(rank)):
        if rank[j] == -1:
            continue
        relevant_retrievals += 1
        sum_ += relevant_retrievals / (rank[j] + 1)
    score = sum_ / len(rank)
    print(score)
    AP.append(score)
        
print("mAP =", sum(AP) / len(AP))