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
    std::cout << "  -p <filepath> Specify the input NPY file path" << std::endl;
    std::cout << "  -d <dim>      Specify the vector dimensions" << std::endl;
    std::cout << "  -n <filename> Specify the output file name" << std::endl;
}

void split(std::vector<std::string> &Result, std::string &Input,const char* Regex);
void load_data(std::vector<float> &feature_data, string path);

int main(int argc, char * argv[]){
    
    int opt = 0;
    string txt_file_path;
    string output_file_name;
    OptionType option_type = TYPE_UNKNOWN;
    int dim = 0;

    std::string arg = argv[1];
    if (arg == "-h" || arg == "--help") {
        printHelp();
        return 0;
    }

    while((opt = getopt(argc, argv, "h:p:d:n:")) != -1) {
        switch(opt) {
            case 'h':
                printHelp();
                return 0;
            case 'p':
                txt_file_path = string(optarg);
                break;
            case 'd':
                dim = atoi(optarg);
                break;
            case 'n':
                output_file_name = string(optarg);
                break;
        }
    }
    

    FILE * out[1];
    char path[4096] = {0};
    std::strcpy(path, output_file_name.c_str());
    out[0] = fopen(path, "w");
    if(!out[0]){
        printf("Failed to open %s\n",path);
        exit(-1);
    }


    int count = 0;
    std::ifstream inputFile(txt_file_path);
    std::string line;

    // 逐行读取文本文件
    while (std::getline(inputFile, line)) {
        // 去掉换行符
        if (!line.empty() && line[line.size() - 1] == '\n') {
            line.erase(line.size() - 1);
        }

        // count line num
        if (line.size() == dim) {
            count += 1;
        }
    }
    printf("Text count = %d\n", count);

	struct columnHeader header;
    long tupleNum = 0;
    long tupleCount =0;
    tupleNum = count;
    // std::cout << tupleNum << std::endl;
    header.totalTupleNum = tupleNum;
    header.tupleNum = tupleNum;
    header.format = 3; //UNCOMPRESSED
    header.blockId = 0;
    header.blockTotal = 1;
    header.blockSize = header.tupleNum * dim * sizeof(float);
    // header 4096Byte = 4kB
    fwrite(&header, sizeof(struct columnHeader), 1, out[0]);
    std::cout << sizeof(header) << std::endl;


    std::ifstream inputFile2(txt_file_path);
    const char* data = (char*)malloc(sizeof(char) * 23);
    // 逐行读取文本文件
    while (std::getline(inputFile2, line)) {
        // 去掉换行符
        
        if (!line.empty() && line[line.size() - 1] == '\n') {
            line.erase(line.size() - 1);
        }
        // printf("%d:%s", line.size(), line);

        // 使用 fwrite 将数据写入二进制文件
        if (line.size() == dim) {
            // printf("************************");
            const char* data = line.c_str();
            // printf("%s", data);
            // printf("\n");
            fwrite(data, sizeof(char), line.size(), out[0]);
        }
    }
}