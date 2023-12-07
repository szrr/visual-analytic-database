#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include "npy.hpp"

#define _VECTOR_SIZE 2048

struct columnHeader{
    long totalTupleNum; /* the total number of tuples in this column */
    long tupleNum;      /* the number of tuples in this block */
    long blockSize;     /* the size of the block in bytes */
    int blockTotal;     /* the total number of blocks that this column is divided into */
    int blockId;        /* the block id of the current block */
    int format;         /* the format of the current block */
    char padding[4060]; /* for futher use */
};

void split(std::vector<std::string> &Result, std::string &Input,const char* Regex);
void load_data(std::vector<float> &feature_data, std::vector<int64_t> &indexs, std::vector<std::string> &videos);

int main(){
    std::vector<float> feature_data;
    std::vector<int64_t> indexs;
    std::vector<std::string> videos;
    load_data(feature_data, indexs, videos);

    FILE * out[1];
    char path[4096] = {0};
    sprintf(path,"%s%d", "FRAMES", 0);
    out[0] = fopen(path, "w");
    if(!out[0]){
        printf("Failed to open %s\n",path);
        exit(-1);
    }

	struct columnHeader header;
    long tupleNum = 0;
    long tupleCount =0;
    tupleNum = feature_data.size() / _VECTOR_SIZE;
    // std::cout << tupleNum << std::endl;
    header.totalTupleNum = tupleNum;
    header.tupleNum = tupleNum;
    header.format = 3; //UNCOMPRESSED
    header.blockId = 0;
    header.blockTotal = 1;
    header.blockSize = header.tupleNum * _VECTOR_SIZE * sizeof(float);
    // header 4096Byte = 4kB
    fwrite(&header, sizeof(struct columnHeader), 1, out[0]);
    std::cout << sizeof(header) << std::endl;
    float *p = feature_data.data();
    //feature 183928kB
    fwrite(p, sizeof(float), feature_data.size(), out[0]);
}

void load_data(std::vector<float> &feature_data, std::vector<int64_t> &indexs, std::vector<std::string> &videos) {
    
    std::string feature_path = "/mnt/data/szr/vectordataset/features.npy";
    std::string index_path = "/mnt/data/szr/vectordataset/indexs.npy";

    std::vector<unsigned long> shape {};
    // std::vector<float> feature_data; // 必须指定<dtype>类型与npy对应
    bool is_fortran;

    /* load ndarray features as vector<float> */
    npy::LoadArrayFromNumpy(feature_path, shape, is_fortran, feature_data);
    for(int i = 0; i < shape.size(); i++)
        std::cout << "feature shape[" << i << "] = " << shape[i] << std::endl;
    // std::cout << std::endl;
    
    /* load ndarray indexs as vector<long> */
    std::vector<unsigned long> shape0 {};
    // std::vector<int64_t> indexs;
    npy::LoadArrayFromNumpy(index_path, shape0, is_fortran, indexs);
    indexs.push_back(shape[0]);  //增加indexs[videonum] = framenum  后期判定frame属于哪个video更加方便
    // std::cout << "******************* Print the indexs *******************" << std::endl;
    // for(int i = 0; i < indexs.size(); i++)
    // {
    //     std::cout << "[" << i << "] = " << indexs[i] << "\t";
    //     if(i % 10 == 0 && i > 0)
    //         std::cout << std::endl;
    // }
    // std::cout << std::endl;
    // std::cout << std::endl;

    /* load videos as vector<string> */
    std::ifstream inf;
    inf.open("/mnt/data/szr/vectordataset/videos.txt");
    std::string line;
    std::getline(inf, line);
    //std::vector<std::string> videos;
    split(videos, line, " ");
    // delete EOF
    videos.pop_back();
    std::cout << "The num of videos is " << videos.size() << std::endl;
    std::cout << std::endl;
    // for(int i = 0; i < videos.size(); ++i)
    // {
    //     std::cout << videos[i] << std::endl;
    //     std::cout << videos[i].length() << std::endl;
    // }

    
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