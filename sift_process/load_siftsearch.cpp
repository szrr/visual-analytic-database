#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>

void readFloatArray(std::vector<float>& buffer, char* filename) {
    FILE* file = fopen(filename, "rb");
    if (file != nullptr) {
        // 获取文件大小
        fseek(file, 0, SEEK_END);
        long fileSize = ftell(file);
        fseek(file, 0, SEEK_SET);
        // 计算数组元素数量
        std::size_t count = fileSize / sizeof(float);
        printf("[DISTANCE Info]searchVec dimensions = %ld\n", count);
        // 调整向量大小以容纳数据
        buffer.resize(count);
        // buffer[0] = 1;
        // 读取数据到向量
        fread(buffer.data(), sizeof(float), count, file);
        fclose(file);
    } else {
        std::cerr << "Failed to open file." << std::endl;
    }
}

int main() {
    std::vector<float> searchV;
    char filename[50] = "/home/szr/subquery/sift_process/siftsearch";
    readFloatArray(searchV, filename);
    for(int i = 0; i < searchV.size(); i++){
        printf("searchV[%d] = %f\n", i, searchV[i]);
    }
}