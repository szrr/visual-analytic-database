#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include "npy.hpp"
#include <unistd.h>

using namespace std;

enum OptionType {
    TYPE_UNKNOWN = 0,
    TYPE_ENCRYPT,
    TYPE_DECRYPT
};

// #define _VECTOR_SIZE 19

struct columnHeader{
    long totalTupleNum; /* the total number of tuples in this column */
    long tupleNum;      /* the number of tuples in this block */
    long blockSize;     /* the size of the block in bytes */
    int blockTotal;     /* the total number of blocks that this column is divided into */
    int blockId;        /* the block id of the current block */
    int format;         /* the format of the current block */
    char padding[4060]; /* for futher use */
};

void printHelp() {
    std::cout << "Usage: ./initColumn -p <InputNpyFilePath> -d <VectorDimensions> -n <OutputFileName>" << std::endl;
    std::cout << "Options:" << std::endl;
    std::cout << "  -h            Display this help message" << std::endl;
    std::cout << "  -p <filepath> Specify the input .npy file path" << std::endl;
    std::cout << "  -n <filename> Specify the output file name" << std::endl;
}

void split(std::vector<std::string> &Result, std::string &Input,const char* Regex);
void load_data(std::vector<int> &feature_data, string path);

int main(int argc, char * argv[]){
    
    int opt = 0;
    string npy_file_path;
    string output_file_name;
    OptionType option_type = TYPE_UNKNOWN;
    int dim = 0;

    std::string arg = argv[1];
    if (arg == "-h" || arg == "--help") {
        printHelp();
        return 0;
    }

    while((opt = getopt(argc, argv, "h:p:n:")) != -1) {
        switch(opt) {
            case 'h':
                printHelp();
                return 0;
            case 'p':
                npy_file_path = string(optarg);
                break;
            case 'n':
                output_file_name = string(optarg);
                break;
        }
    }
    
    std::vector<int> data;
    load_data(data, npy_file_path);
    printf("data[0] = %d\n", data[0]);

    FILE * out[1];
    char path[4096] = {0};
    std::strcpy(path, output_file_name.c_str());
    out[0] = fopen(path, "w");
    if(!out[0]){
        printf("Failed to open %s\n",path);
        exit(-1);
    }

	struct columnHeader header;
    long tupleNum = 0;
    long tupleCount =0;
    tupleNum = data.size();
    // std::cout << tupleNum << std::endl;
    header.totalTupleNum = tupleNum;
    header.tupleNum = tupleNum;
    header.format = 3; //UNCOMPRESSED
    header.blockId = 0;
    header.blockTotal = 1;
    header.blockSize = header.tupleNum * dim * sizeof(float);
    // header 4096Byte = 4kB
    fwrite(&header, sizeof(struct columnHeader), 1, out[0]);
    // std::cout << sizeof(header) << std::endl;
    int *p = data.data();

    printf("data.size = %ld\n", data.size());
    fwrite(p, sizeof(int), data.size(), out[0]);
}

void load_data(std::vector<int> &int_data, std::string path) {
    
    std::string feature_path = path;
    std::vector<unsigned long> shape {};
    // std::vector<float> feature_data; // 必须指定<dtype>类型与npy对应
    bool is_fortran;

    /* load ndarray features as vector<float> */
    npy::LoadArrayFromNumpy(feature_path, shape, is_fortran, int_data);
    for(int i = 0; i < shape.size(); i++)
        std::cout << "data shape[" << i << "] = " << shape[i] << std::endl;
    // std::cout << std::endl;

}

void split(std::vector<std::string> &Result, std::string &Input,const char* Regex)  
{
    int pos = 0;  
    int npos = 0;  
    int regexlen = strlen(Regex);  
    while((npos=Input.find(Regex, pos))!=-1)  
    {  
        std::string tmp = Input.substr(pos,npos-pos);  
        Result.push_back(tmp);  
        pos = npos+regexlen;  
    }  
    Result.push_back(Input.substr(pos,Input.length()-pos));  
}  