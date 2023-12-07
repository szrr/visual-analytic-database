#include <time.h>
#include <iostream>
#include <fstream>
#include "../include/gpuCudaLib.h"
#include "../include/utils.h"


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

bool fileExists(const std::string& filename)
{
    std::ifstream file(filename);
    return file.good();
}

double elapsed() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}