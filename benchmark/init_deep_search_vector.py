import h5py
import sys

def printname(name):
    print(name)

with h5py.File('deep-image-96-angular.hdf5', 'r') as file:
    # file.visit(printname)
    # dataset = file['train']
    # data = dataset[:]
    # print(data.shape)

    index = int(sys.argv[1])

    dataset = file['test']
    data = dataset[:]
    search_vec = data[index]
    print(search_vec.shape)
    search_vec.tofile("deepsearchvec")
    # for i in range (100): 
    #     print(i, ":",data[0][i])

    # dataset = file['neighbors']
    # data = dataset[:]
    # print(data.shape)

    # for i in range (100): 
    #     print(i, ":",data[0][i])

    # dataset = file['distances']
    # data = dataset[:]
    # print(data.shape)
