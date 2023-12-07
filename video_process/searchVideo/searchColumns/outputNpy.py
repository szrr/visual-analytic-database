import numpy as np

path = 'features.npy'
data = np.load(path)


# print("all :")
# for value in data.flatten():
    # print(value)

    

print(path, "shape:", data.shape)
