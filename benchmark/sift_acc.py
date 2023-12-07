import h5py
import numpy as np
import sys

i = int(sys.argv[1])

# 读取文件中的数字
with open("output.txt", "r") as f:
    numbers = [int(line.strip()) for line in f.readlines()]

data = []
with h5py.File('sift-128-euclidean.hdf5', 'r') as file:
    dataset = file['neighbors']
    data = dataset[:]
# print(data.shape)

# 转换为numpy数组
numbers_np = np.array(numbers)
numbers_np = numbers_np[0:100]
# print(numbers_np.shape)
# print(numbers_np)

# 假设你的groundtruth是一个numpy数组,例如:
groundtruth = data[i]
# print(groundtruth)

# 计算召回率
intersection = np.intersect1d(numbers_np, groundtruth).shape[0]
recall = intersection / len(groundtruth)

print("Recall:", recall)
with open('sift_acc.txt', 'a') as file:
    file.write(f'\n{recall}')

