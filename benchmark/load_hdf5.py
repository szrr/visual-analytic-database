import h5py
import numpy as np

def printname(name):
    print(name)

with h5py.File('sift-128-euclidean.hdf5', 'r') as file:
    file.visit(printname)
    dataset = file['train']
    data = dataset[:]
    print(data.shape)
    np.save('sift1m.npy', data)

    dataset = file['test']
    data = dataset[:]
    print(data.shape)
    # for i in range (100): 
    #     print(i, ":",data[0][i])

    dataset = file['neighbors']
    data = dataset[:]
    print(data.shape)

    # for i in range (100): 
    #     print(i, ":",data[0][i])

    # dataset = file['distances']
    # data = dataset[:]
    # print(data.shape)
