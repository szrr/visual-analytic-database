/*
   Copyright (c) 2012-2013 The Ohio State University.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/


#include <stdio.h>
#include <cuda.h>
#include <string.h>
#include <time.h>
#include "../include/common.h"
#include "../include/gpuCudaLib.h"
#include "../include/cudaHash.h"
#include "../include/Mempool.h"
#include "scanImpl.cu"

#include <cuda_runtime.h>
#include <thrust/sort.h>
#include <thrust/device_ptr.h>
#include <thrust/device_vector.h>
#include <faiss/IndexFlat.h>
#include <faiss/gpu/GpuIndexFlat.h>
#include <faiss/gpu/StandardGpuResources.h>
#include <faiss/gpu/impl/IndexUtils.h>
#include <faiss/gpu/utils/DeviceUtils.h>
#include <iostream>
#include <iomanip>
#include <fstream>
#include <vector>
#include <string>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <set>
#include <thread>
#include <map>
#include <queue>
#include <functional>
#include <mutex>
#include <condition_variable>
#include <algorithm>

const float THRESHOLD = 2.8;

const int MATCH = 3;
const int MISMATCH = -3;
const int GAP = -2;

std::mutex resmap_mutex;

int threshold(float num){
    if(num < THRESHOLD){
        return 1;
    }
    return 0;
}

/*
    ThreadPool for multi-thread VIDEO_SIMILARITY()
*/
class ThreadPool {
public:
    ThreadPool(size_t threads);
    ~ThreadPool();

    template<class F, class... Args>
    void enqueue(F&& f, Args&&... args);

private:
    std::vector<std::thread> workers;
    std::queue<std::function<void()>> tasks;

    std::mutex queue_mutex;
    std::condition_variable condition;
    bool stop;
    int activeThreads = 0;  // 跟踪当前正在执行任务的线程数

public:
    bool allTasksCompleted();  // 函数检查所有任务是否完成

};

ThreadPool::ThreadPool(size_t threads) : stop(false) {
    for(size_t i = 0; i < threads; ++i)
        workers.emplace_back([this] {
            for(;;) {
                std::function<void()> task;
                {
                    std::unique_lock<std::mutex> lock(this->queue_mutex);
                    this->condition.wait(lock, [this] { return this->stop || !this->tasks.empty(); });
                    if(this->stop && this->tasks.empty()) return;
                    task = std::move(this->tasks.front());
                    this->tasks.pop();

                    this->activeThreads++;  // 开始执行任务，增加activeThreads计数
                }
                task();
                {
                    std::unique_lock<std::mutex> lock(this->queue_mutex);
                    this->activeThreads--;  // 任务完成，减少activeThreads计数
                }
            }
        });
}

ThreadPool::~ThreadPool() {
    {
        std::unique_lock<std::mutex> lock(queue_mutex);
        stop = true;
    }
    condition.notify_all();
    for(std::thread &worker: workers)
        worker.join();
}

bool ThreadPool::allTasksCompleted() {
    std::unique_lock<std::mutex> lock(queue_mutex);
    return tasks.empty() && activeThreads == 0;
}

template<class F, class... Args>
void ThreadPool::enqueue(F&& f, Args&&... args) {
    {
        std::unique_lock<std::mutex> lock(queue_mutex);
        tasks.emplace(std::bind(std::forward<F>(f), std::forward<Args>(args)...));
    }
    condition.notify_one();
}

float computeSumForSegment(const float* dist, int start, int k) {
    float sum = 0.0f;
    for (int i = 1; i < k; ++i) {
        sum += dist[start + i];
    }
    return sum;
}

int matchScore(int sim) {
    return sim == 1 ? MATCH : MISMATCH;
}

void SWAlign(std::vector<std::vector<int>> &simVec, int search_start, int search_end, int ref_start, int ref_end, int &max_score, std::vector<int> &seq){

    if(search_start < search_end && ref_start < ref_end){
        /* Backtracking: cal subsequence and score, add subsequence to seq
            1. initial dp matrix, get max score and address
            2. backtracking and record subsequence of search video and reference video
        */
        int len1 = search_end - search_start + 1;
        int len2 = ref_end - ref_start + 1;
        
        std::vector<std::vector<int>> dp(len1 + 1, std::vector<int>(len2 + 1, 0));
        
        int max_i = 0, max_j = 0;
        int start_i = 0, start_j = 0;

        // Fill the dp matrix
        for(int i = 1; i <= len1; i++) {
            for(int j = 1; j <= len2; j++) {
                int match = dp[i - 1][j - 1] + matchScore(simVec[i-1 + search_start][j-1 + ref_start]);
                int delete_op = dp[i - 1][j] + GAP;
                int insert_op = dp[i][j - 1] + GAP;
                
                dp[i][j] = std::max({0, match, delete_op, insert_op});
                
                if(dp[i][j] > max_score) {
                    max_score = dp[i][j];
                    max_i = i;
                    max_j = j;
                }
            }
        }

        int i = max_i;
        int j = max_j;
        while(i > 0 && j > 0 && dp[i][j] != 0) {
            if(dp[i][j] == dp[i-1][j-1] + matchScore(simVec[i-1 + search_start][j-1 + ref_start])) {
                i--;
                j--;
                start_i = i;
                start_j = j;
            } else if(dp[i][j] == dp[i-1][j] + GAP) {
                i--;
                start_i = i;
                start_j = j;
            } else {
                j--;
                start_i = i;
                start_j = j;
            }
        }
        seq[0] = start_i + search_start;
        seq[1] = max_i + search_start;
        seq[2] = start_j + ref_start;
        seq[3] = max_j + ref_start;
    } else {
        max_score = 0;
    }
}

int RSWAlign(std::vector<std::vector<int>> &simVec, int search_start, int search_end, int ref_start, int ref_end, std::vector<std::vector<int>> &subsequence, std::vector<int> &seqScore){
    int score = 0;
    std::vector<int> seq{0, 0, 0, 0};
    
    // printf("Begin RSWAlign\n");
    // printf("search_start = %d, search_end = %d, ref_start = %d, ref_end = %d\n", search_start, search_end, ref_start, ref_end);
    // cal seq
    SWAlign(simVec, search_start, search_end, ref_start, ref_end, score, seq);
    // printf("\nSWAlign in RSWAlign\n");
    // printf("seq[0] = %d, seq[1] = %d, seq[2] = %d, seq[3] = %d\n", seq[0], seq[1], seq[2], seq[3]);

    if(seq[0] < seq[1] && seq[2] < seq[3]){
        subsequence.push_back(seq);
        seqScore.push_back(score);
        // left
        // printf("\nleft in RSWAlign\n");
        score += RSWAlign(simVec, search_start, seq[0]-1, ref_start, seq[2]-1, subsequence, seqScore);

        // right
        // printf("\nright in RSWAlign\n");
        score += RSWAlign(simVec, seq[1]+1, search_end, seq[3]+1, ref_end, subsequence, seqScore);
    }
    return score;
}

std::vector<std::vector<int>> convertToSimVec(const std::vector<float>& distVec, int numRows, int numCols) {
    std::vector<std::vector<int>> simVec(numRows, std::vector<int>(numCols));

    for(int i = 0; i < numRows; i++) {
        for(int j = 0; j < numCols; j++) {
            simVec[i][j] = threshold(distVec[i * numCols + j]);
        }
    }

    return simVec;
}

int calScore(std::vector<float> &distVec, int num, std::vector<std::vector<int>> &seq, std::vector<int> &seqScore) {
    // cal score
    int refLen = distVec.size() / num;
    std::vector<std::vector<int>> similarityVec = convertToSimVec(distVec, num, refLen);

    // printf("Breakpoint in calScore\n");
    int score = RSWAlign(similarityVec, 0, num-1, 0, refLen-1, seq, seqScore);
    return score;
}

void normalize(float* array, int size) {
    if (size <= 0) {
        return;  // 防止除以零
    }

    // 找到最小值和最大值
    float min = array[0];
    float max = array[0];

    for (int i = 1; i < size; i++) {
        if (array[i] < min) {
            min = array[i];
        }
        if (array[i] > max) {
            max = array[i];
        }
    }

    printf("[normalize] max = %f, min = %f\n", max, min);

    // 归一化数组元素
    for (int i = 0; i < size; i++) {
        array[i] = (array[i] - min) / (max - min);
    }
}

__global__ void copyElement(float* data, int size, float* result) {
    int index = (int)(0.999 * size); // 99.9% position
    *result = data[index];
}

void sortAndFindElement(float* data, int size, float* result) {
    // Use thrust to sort
    thrust::device_ptr<float> dev_ptr(data);
    thrust::sort(dev_ptr, dev_ptr + size);

    // Launch kernel to copy 90% element to result
    copyElement<<<1, 1>>>(data, size, result);

    cudaDeviceSynchronize();
}

/*
 * Combine the group by columns to build the group by keys. 
 */

__global__ static void build_groupby_key(char ** content, int gbColNum, int * gbIndex, int * gbType, int * gbSize, long tupleNum, int * key, int *num, int* groupNum){

    int stride = blockDim.x * gridDim.x;
    int offset = blockIdx.x * blockDim.x + threadIdx.x;

    for(long i = offset; i< tupleNum; i+= stride){
        char buf[128] = {0};
        int hkey;
        // if(gbColNum == 1 && gbIndex[0] != -1 && gbType[0] == INT) {
        //     int k = ((int *)(content[gbIndex[0]]))[i];
        //     hkey = k % HSIZE;
        // }else
        {
            for (int j=0; j< gbColNum; j++){
                char tbuf[32]={0};
                int index = gbIndex[j];

                if (index == -1){
                    gpuItoa(1,tbuf,10);
                    gpuStrncat(buf,tbuf,1);

                }else if (gbType[j] == STRING){
                    gpuStrncat(buf, content[index] + i*gbSize[j], gbSize[j]);

                }else if (gbType[j] == INT){
                    int key = ((int *)(content[index]))[i];
                    gpuItoa(key,tbuf,10);
                    gpuStrcat(buf,tbuf);
                }
            }
            if(gbColNum == 1 && gbIndex[0] != -1 && gbType[0] == INT)
                hkey = StringHashInt(buf) % HSIZE;
            else
                hkey = StringHash(buf) % HSIZE;
        }
        key[i]= hkey;
        num[hkey] = 1;
        atomicAdd(&(groupNum[hkey]), 1);
    }
}


/*
 * Count the number of groups 
 */

__global__ static void count_group_num(int *num, int tupleNum, int *totalCount){
        int stride = blockDim.x * gridDim.x;
        int offset = blockIdx.x * blockDim.x + threadIdx.x;
        int localCount = 0;

        for(int i=offset; i<tupleNum; i+= stride){
                if(num[i] == 1){
                        localCount ++;
                }
        }

        atomicAdd(totalCount,localCount);
}

/*
 * Calculate the groupBy expression.
 */

__device__ static float calMathExp(char **content, struct mathExp exp, int pos){
    float res ;

    if(exp.op == NOOP){
        if (exp.opType == CONS)
            res = exp.opValue;
        else if(exp.opType == COLUMN_INTEGER){
            int index = exp.opValue;
            res = ((int *)(content[index]))[pos];
        }else if(exp.opType == COLUMN_DECIMAL){
            int index = exp.opValue;
            res = ((float *)(content[index]))[pos];
        }
    
    }else if(exp.op == PLUS ){
        res = calMathExp(content, ((struct mathExp*)exp.exp)[0],pos) + calMathExp(content, ((struct mathExp*)exp.exp)[1], pos);

    }else if (exp.op == MINUS){
        res = calMathExp(content, ((struct mathExp*)exp.exp)[0],pos) - calMathExp(content, ((struct mathExp*)exp.exp)[1], pos);

    }else if (exp.op == MULTIPLY){
        res = calMathExp(content, ((struct mathExp*)exp.exp)[0],pos) * calMathExp(content, ((struct mathExp*)exp.exp)[1], pos);

    }else if (exp.op == DIVIDE){
        res = calMathExp(content, ((struct mathExp*)exp.exp)[0],pos) / calMathExp(content, ((struct mathExp*)exp.exp)[1], pos);
    }

    return res;
}


__device__ __forceinline__ float atomicMaxFloat (float * addr, float value) {
    float old;
    old = (value >= 0) ? __int_as_float(atomicMax((int *)addr, __float_as_int(value))) :
         __uint_as_float(atomicMin((unsigned int *)addr, __float_as_uint(value)));

    return old;
}

__device__ __forceinline__ float atomicMinFloat (float * addr, float value) {
        float old;
        old = (value >= 0) ? __int_as_float(atomicMin((int *)addr, __float_as_int(value))) :
             __uint_as_float(atomicMax((unsigned int *)addr, __float_as_uint(value)));

        return old;
}

/*
 * group by constant. Currently only support SUM function.
 */

__global__ static void agg_cal_cons(char ** content, int colNum, struct groupByExp* exp, long tupleNum, char ** result){

    int stride = blockDim.x * gridDim.x;
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    float buf[32];
    for(int i = 0; i < colNum; i++){
        int func = exp[i].func;
        if(func == MAX)
            buf[i] = FLOAT_MIN;
        else if(func == MIN)
            buf[i] = FLOAT_MAX;
        else
            buf[i] = 0;
    }

    for(int i=index;i<tupleNum;i+=stride){
        for(int j=0;j<colNum;j++){
            int func = exp[j].func;
            if (func == SUM){
                float tmpRes = calMathExp(content, exp[j].exp, i);
                buf[j] += tmpRes;
            }else if (func == AVG){

                float tmpRes = calMathExp(content, exp[j].exp, i)/tupleNum;
                buf[j] += tmpRes;
            }else if (func == MAX){

                float tmpRes = calMathExp(content, exp[j].exp, i);
                buf[j] = buf[j] > tmpRes ? buf[j] : tmpRes;
            }else if (func == MIN){

                float tmpRes = calMathExp(content, exp[j].exp, i);
                buf[j] = buf[j] < tmpRes ? buf[j] : tmpRes;
            }
        }
    }

    for(int i=0;i<colNum;i++)
    {
        int func = exp[i].func;
        if (func == SUM)
            atomicAdd(&((float *)result[i])[0], buf[i]);
        else if (func == MAX)
            atomicMaxFloat(&((float *)result[i])[0], buf[i]);
        else if (func == MIN)
            atomicMinFloat(&((float *)result[i])[0], buf[i]);
    }
}

/*
 * gropu by
 */

__global__ static void agg_cal(char ** content, int colNum, struct groupByExp* exp, int * gbType, int * gbSize, long tupleNum, int * key, \
    int *psum, int * groupNum, char ** result, int *dkeys = nullptr, float* dvalues = nullptr, int dnum = 0){

    int stride = blockDim.x * gridDim.x;
    int index = blockIdx.x * blockDim.x + threadIdx.x;

    for(int i=index;i<tupleNum;i+=stride){

        int hKey = key[i];
//        int offset = atomicAdd(&(psum[hKey]), 1);
        int offset = psum[hKey];


        for(int j=0;j<colNum;j++){
            int func = exp[j].func;
            if(func ==NOOP){
                int type = exp[j].exp.opType;

                if(type == CONS){
                    int value = exp[j].exp.opValue;
                    ((int *)result[j])[offset] = value;
                }else{
                    int index = exp[j].exp.opValue;
                    int attrSize = gbSize[j];
                    if(attrSize == sizeof(int))
                        ((int *)result[j])[offset] = ((int*)content[index])[i];
                    else
                        memcpy(result[j] + offset*attrSize, content[index] + i * attrSize, attrSize);
                }

            }else if (func == SUM ){
                float tmpRes = calMathExp(content, exp[j].exp, i);
                atomicAdd(& ((float *)result[j])[offset], tmpRes);
            }else if (func == MAX ){
                float tmpRes = calMathExp(content, exp[j].exp, i);
                atomicMaxFloat(& ((float *)result[j])[offset], tmpRes);

            }else if (func == MIN ){
                float tmpRes = calMathExp(content, exp[j].exp, i);
                atomicMinFloat(& ((float *)result[j])[offset], tmpRes);

            }else if (func == AVG){
                float tmpRes = calMathExp(content, exp[j].exp, i)/groupNum[hKey];
                atomicAdd(& ((float *)result[j])[offset], tmpRes);
            }else if (func == OUTLIER_SCORE){
                float tmpRes = (( (float*) (content[j]) )[i]);
                atomicMaxFloat(& ((float *)result[j])[offset], tmpRes);
            }
        }
    }
    if(dkeys != NULL){
        for(int i=0; i<colNum; i++){
            int func = exp[i].func;
            if (func == VIDEO_SIMILARITY){
                for(int j=0; j<dnum; j++){
                    int hKey = dkeys[j];
                    int offset = psum[hKey];
                    ((float *)result[i])[offset] = dvalues[j];
                }
            }
        }
    }
}

void loadFloatArray(std::vector<float>& buffer, char* filename) {
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

__global__ static void init_int_array(int *array, int array_size, int init_value)
{
    int stride = blockDim.x * gridDim.x;
    int index = blockIdx.x * blockDim.x + threadIdx.x;

    for(int i = index; i < array_size; i += stride)
        array[i] = init_value;
}

__global__ void mergeAndSum(float* data, int num, int k, float* res) {
    int tid = threadIdx.x + blockIdx.x * blockDim.x;

    if (tid < num) {
        float sum = 0.0f;
        float* vector = &data[tid * k];

        for (int i = 1; i < k; i++) {
            sum += vector[i];
        }

        res[tid] = sum;
    }
}

__global__ void findValue(float* data, int size, float* result) {
    int tid = threadIdx.x + blockIdx.x * blockDim.x;

    // 每个线程处理一个数据
    if (tid < size) {
        // 在共享内存中拷贝数据
        extern __shared__ float sharedData[];
        sharedData[tid] = data[tid];
        __syncthreads();

        // 使用并行排序算法对数据进行排序
        for (int stride = 1; stride < size; stride *= 2) {
            int index = 2 * stride * tid;
            if (index < size) {
                // 进行合并排序
                float temp = sharedData[index];
                if (index + stride < size) {
                    float nextValue = sharedData[index + stride];
                    if (temp > nextValue) {
                        sharedData[index] = nextValue;
                        sharedData[index + stride] = temp;
                    }
                }
            }
            __syncthreads();
        }

        // 将位置在 90% 处的值输出
        if (tid == static_cast<int>(size * 0.9) - 1) {
            *result = sharedData[tid];
        }
    }
}

float calcL2Distance(const std::vector<float>& vec1, const std::vector<float>& vec2, int startIdx1, int startIdx2, int vectorSize) {
    float dist = 0.0f;
    for (int i = 0; i < vectorSize; i++) {
        float diff = vec1[startIdx1 + i] - vec2[startIdx2 + i];
        dist += diff * diff;
    }
    return std::sqrt(dist);
}

std::map<int, std::vector<float>> calcDistances(std::vector<float>& searchV, std::map<int, std::vector<float>>& hashmap, int vectorSize) {
    std::map<int, std::vector<float>> result;
    for (auto& pair : hashmap) {
        int key = pair.first;
        std::vector<float>& vectors = pair.second;
        for (int i = 0; i < searchV.size(); i += vectorSize) {
            for (int j = 0; j < vectors.size(); j += vectorSize) {
                float dist = calcL2Distance(searchV, vectors, i, j, vectorSize);
                result[key].push_back(dist);
            }
        }
    }
    return result;
}

std::map<int, float> calVideoSimlarity(std::map<int, std::vector<float>> distmap, int searchFrameNum){
    // fake algorithm
    std::map<int, float> res;
    float count = 1.0;
    for(auto &pair : distmap){
        printf("pair.first = %d\n", pair.first);
        res[pair.first] = count;
        count += 1.0;
    }

    // thinking... true algorithm

    return res;
}

/* 
 * groupBy: group by the data and calculate. 
 * 
 * Prerequisite:
 *  input data are not compressed
 *
 * Input:
 *  gb: the groupby node which contains the input data and groupby information
 *  pp: records the statistics such as kernel execution time 
 *
 * Return:
 *  a new table node
 */

struct tableNode * groupBy(struct groupByNode * gb, struct statistic * pp,
                           Mempool *host_mp = NULL, Mempool *dev_mp = NULL){

    
    printf("\n=============== [groupby.cu] start =============\n");

    float disArray[1024*1024];
    int intArray[40960];
    // printf("[groupBy] attrType[2] :%d\n", gb->table->attrType[2]);
    // cudaMemcpy(disArray, gb->table->content[2], gb->table->attrSize[2] * gb->table->tupleNum, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 10; i++){
    //     printf("test feature[%d] = ", i);
    //     for(int j = 0; j < 10; j++){
    //         printf("%f\t", disArray[i*10 + j]);
    //     }
    //     printf("\n");
    // }

    // printf("[groupBy] attrType[0] :%d\n", gb->table->attrType[0]);
    // cudaMemcpy(intArray, gb->table->content[0], gb->table->attrSize[0] * gb->table->tupleNum, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 100; i++){
    //     for(int j = 0; j < 10; j++){
    //         printf("%d\t", intArray[i * 10 + j]);
    //     }
    //     printf("\n");
    // }

    // printf("[groupBy] attrType[1] :%d\n", gb->table->attrType[1]);
    // cudaMemcpy(intArray, gb->table->content[1], gb->table->attrSize[1] * gb->table->tupleNum, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 10; i++){
    //     for(int j = 0; j < 10; j++){
    //         printf("%d\t", intArray[i * 10 + j]);
    //     }
    //     printf("\n");
    // }

    // char intArray[16384*16];
    // printf("[groupby.cu] the type of result[0] :%d\n", gb->table->attrType[0]);
    // printf("[groupby.cu] the type of result[1] :%d\n", gb->table->attrType[1]);
    // cudaMemcpy(intArray, gb->table->content[0], sizeof(char) * 23 * 400*16, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 400*16; i++){
    //     printf("video_name[%d] = ", i);
	// 	for(int j = 0; j < 23; j++){
    //         printf("%c", intArray[i*23 + j]);
    //     }
    //     printf("\n");
	// }

    //Start total timer
    struct timespec startS0, endS0;
    struct timespec s, e;
    double tt;
    clock_gettime(CLOCK_REALTIME,&s);
    clock_gettime(CLOCK_REALTIME,&startS0);

    //Start timer for Step 1 - Allocate memory for intermediate results
    struct timespec startS1, endS1;
    clock_gettime(CLOCK_REALTIME,&startS1);

    int *gpuGbIndex = NULL, gpuTupleNum, gpuGbColNum;
    int *gpuGbType = NULL, *gpuGbSize = NULL;

    int *gpuGbKey = NULL;
    char ** gpuContent = NULL, **column = NULL;

    /*
     * @gbCount: the number of groups
     * gbConstant: whether group by constant
     */

    int gbCount;
    int gbConstant = 0;

    struct tableNode *res = NULL;
    if(host_mp == NULL) {
        res = (struct tableNode *) malloc(sizeof(struct tableNode));
        CHECK_POINTER(res);
    } else
        res = (struct tableNode *) host_mp->alloc(sizeof(struct tableNode));

    res->tupleSize = gb->tupleSize;
    res->totalAttr = gb->outputAttrNum;

    if(host_mp == NULL) {
        res->attrType = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->attrType);
        res->attrSize = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->attrSize);
        res->attrTotalSize = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->attrTotalSize);
        res->dataPos = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->dataPos);
        res->dataFormat = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->dataFormat);
        res->content = (char **) malloc(sizeof(char **) * res->totalAttr);
        CHECK_POINTER(res->content);
    } else {
        res->attrType = (int *) host_mp->alloc((sizeof(int) * res->totalAttr));
        res->attrSize = (int *) host_mp->alloc((sizeof(int) * res->totalAttr));
        res->attrTotalSize = (int *) host_mp->alloc((sizeof(int) * res->totalAttr));
        res->dataPos = (int *) host_mp->alloc((sizeof(int) * res->totalAttr));
        res->dataFormat = (int *) host_mp->alloc(sizeof(int) * res->totalAttr);
        res->content = (char **) host_mp->alloc(sizeof(char **) * res->totalAttr);
    }

    for(int i=0;i<res->totalAttr;i++){
        res->attrType[i] = gb->attrType[i];
        res->attrSize[i] = gb->attrSize[i];
        res->dataFormat[i] = UNCOMPRESSED;
        printf("res->attrType[%d] = %d\n", i, gb->attrType[i]);
    }

    gpuTupleNum = gb->table->tupleNum;
    int alignedGpuTupleNum = gpuTupleNum;
    NP2(alignedGpuTupleNum);
    printf("[groupby] tupleNum = %d\n", gpuTupleNum);
    gpuGbColNum = gb->groupByColNum;

    // if video_similarity() function exist = 1, else = 0
    int video_similarity_exist = 0;
    // the index of video_similarity() function input column, if not exist = -1
    int video_similarity_index = -1;
    // the index of video_similarity() function, 0:pathVideo 1:tableVideo
    int video_similarity_type = -1;

    int outlier_score_exist = 0;
    int outlier_score_index = -1;

    int searchFrameNum;

    for(int i = 0; i < res->totalAttr; i++) {
        if (gb->gbExp[i].func == OUTLIER_LINE) {
            int colIndex = gb->gbExp[i].index;
            res->attrType[colIndex] = FLOAT;
            res->attrSize[colIndex] = sizeof(float);
        }
        else if (gb->gbExp[i].func == VIDEO_SIMILARITY) {
            video_similarity_exist = 1;
            video_similarity_index = gb->gbExp[i].index;
            video_similarity_type = gb->gbExp[i].type;
            if(video_similarity_type == 1)
                searchFrameNum = gb->gbExp[i].searchFrameNum;
            res->attrType[video_similarity_index] = FLOAT;
            res->attrSize[video_similarity_index] = sizeof(float);
        }
        else if (gb->gbExp[i].func == OUTLIER_SCORE) {
            outlier_score_exist = 1;
            int colIndex = gb->gbExp[i].index;
            outlier_score_index = colIndex;
            res->attrType[colIndex] = FLOAT;
            res->attrSize[colIndex] = sizeof(float);
        }
    }

    if(gpuGbColNum == 1 && gb->groupByIndex[0] == -1){
        gbConstant = 1;
    }

    dim3 grid(1024);
    dim3 block(128);
    int blockNum = gpuTupleNum / block.x + 1;
    if(blockNum < 1024)
        grid = blockNum;

    //hashTable: gpu_hashNum[hkey] = 1, hkey = hash(element)
    int *gpu_hashNum = NULL;
    
    int *gpu_psum = NULL;
    
    //the number of groups
    int *gpuGbCount = NULL;

    //hashTable: gpuGbCount[hkey] += 1, hkey = hash(element)
    int *gpu_groupNum = NULL;

    if(dev_mp == NULL)
        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuContent, gb->table->totalAttr * sizeof(char *)));
    else
        gpuContent = (char **) dev_mp->alloc(gb->table->totalAttr * sizeof(char *));

    if(host_mp == NULL) {
        column = (char **) malloc(sizeof(char *) * gb->table->totalAttr);
        CHECK_POINTER(column);
    } else
        column = (char **) host_mp->alloc(sizeof(char *) * gb->table->totalAttr);

    printf("gb->table->totalAttr = %d\n", gb->table->totalAttr);

    //Stop for Step 1 - Allocate memory for intermediate results
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS1);
    pp->groupby_step1_allocMem += (endS1.tv_sec - startS1.tv_sec)* BILLION + endS1.tv_nsec - startS1.tv_nsec;
    
    //Start timer for Step 2 - Copy data to GPU
    struct timespec startS2, endS2;
    clock_gettime(CLOCK_REALTIME,&startS2);

    for(int i=0;i<gb->table->totalAttr;i++){
        int attrSize = gb->table->attrSize[i];
        if(gb->table->dataPos[i]==MEM){
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)& column[i], attrSize * gb->table->tupleNum));
            CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(column[i], gb->table->content[i], attrSize * gb->table->tupleNum, cudaMemcpyHostToDevice));

            CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(&gpuContent[i], &column[i], sizeof(char *), cudaMemcpyHostToDevice));
        }else{
            CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(&gpuContent[i], &gb->table->content[i], sizeof(char *), cudaMemcpyHostToDevice));
        }
    }

    //Stop for Step 2 - Copy data to GPU
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS2);
    pp->groupby_step2_copyToDevice += (endS2.tv_sec - startS2.tv_sec)* BILLION + endS2.tv_nsec - startS2.tv_nsec;
            
    if(gbConstant != 1){

        //Start timer for Step 3 - build_groupby_key kernel
        struct timespec startS3, endS3;
        clock_gettime(CLOCK_REALTIME,&startS3);

        if (dev_mp == NULL)
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuGbType, sizeof(int) * gb->groupByColNum));
        else
            gpuGbType = (int *) dev_mp->alloc(sizeof(int) * gb->groupByColNum);
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuGbType,gb->groupByType, sizeof(int) * gb->groupByColNum, cudaMemcpyHostToDevice));

        if (dev_mp == NULL)
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuGbSize, sizeof(int) * gb->groupByColNum));
        else
            gpuGbSize = (int *) dev_mp->alloc(sizeof(int) * gb->groupByColNum);
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuGbSize,gb->groupBySize, sizeof(int) * gb->groupByColNum, cudaMemcpyHostToDevice));

        if (dev_mp == NULL)
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuGbKey, alignedGpuTupleNum * sizeof(int)));
        else
            gpuGbKey = (int *) dev_mp->alloc(alignedGpuTupleNum * sizeof(int));

        if (dev_mp == NULL)
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuGbIndex, sizeof(int) * gb->groupByColNum));
        else
            gpuGbIndex = (int *) dev_mp->alloc(sizeof(int) * gb->groupByColNum);
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuGbIndex, gb->groupByIndex,sizeof(int) * gb->groupByColNum, cudaMemcpyHostToDevice));

        if (dev_mp == NULL)
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_hashNum,sizeof(int)*HSIZE));
        else
            gpu_hashNum = (int *)dev_mp->alloc(sizeof(int) * HSIZE);
        CUDA_SAFE_CALL_NO_SYNC(cudaMemset(gpu_hashNum,0,sizeof(int)*HSIZE));

        if (dev_mp == NULL)
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_groupNum,sizeof(int)*HSIZE));
        else
            gpu_groupNum = (int *) dev_mp->alloc(sizeof(int) * HSIZE);
        CUDA_SAFE_CALL_NO_SYNC(cudaMemset(gpu_groupNum,0,sizeof(int)*HSIZE));

        build_groupby_key<<<grid,block>>>(gpuContent,gpuGbColNum, gpuGbIndex, gpuGbType,gpuGbSize,gpuTupleNum, gpuGbKey, gpu_hashNum, gpu_groupNum);
        CUDA_SAFE_CALL_NO_SYNC(cudaDeviceSynchronize());

        if (dev_mp == NULL) {
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuGbType));
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuGbSize));
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuGbIndex));
        }

        gbCount = 1;

        if (dev_mp == NULL)
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuGbCount,sizeof(int)));
        else
            gpuGbCount = (int *) dev_mp->alloc(sizeof(int));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemset(gpuGbCount, 0, sizeof(int)));

        //Stop for Step 3 - build_groupby_key kernel
        CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
        clock_gettime(CLOCK_REALTIME, &endS3);
        pp->groupby_step3_buildGroupByKey += (endS3.tv_sec - startS3.tv_sec)* BILLION + endS3.tv_nsec - startS3.tv_nsec;
    
        //Start timer for Step 4 - count_group_num
        struct timespec startS4, endS4;
        clock_gettime(CLOCK_REALTIME,&startS4);

        count_group_num<<<grid,block>>>(gpu_hashNum, HSIZE, gpuGbCount);
        CUDA_SAFE_CALL_NO_SYNC(cudaDeviceSynchronize());

        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(&gbCount, gpuGbCount, sizeof(int), cudaMemcpyDeviceToHost));

        if (dev_mp == NULL)
            CUDA_SAFE_CALL(cudaMalloc((void**)&gpu_psum,HSIZE*sizeof(int)));
        else
            gpu_psum = (int *) dev_mp->alloc(HSIZE * sizeof(int));
        scanImpl(gpu_hashNum,HSIZE,gpu_psum,pp);

        if (dev_mp == NULL) {
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuGbCount));
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_hashNum));
        }

        //Stop for 4 - Count number of groups
        CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
        clock_gettime(CLOCK_REALTIME, &endS4);
        pp->groupby_step4_groupCount += (endS4.tv_sec - startS4.tv_sec)* BILLION + endS4.tv_nsec - startS4.tv_nsec;
    }

    if(gbConstant == 1)
        res->tupleNum = 1;
    else
        res->tupleNum = gbCount;
    printf("[INFO]Number of groupBy results: %ld\n",res->tupleNum);

    // init set<hkey,vector>
    int *gbKey;
    int d_num; /* number of videos */
    int* d_keys; /* keys of videos */
    float* d_values; /* values of videos */

    printf("video_similarity_exist = %d\n", video_similarity_exist);
    if (video_similarity_exist == 1 and video_similarity_type == 0) {
        // video_similarity(extraction(path), v1) 
        printf("video_similarity(extraction(path), v1)\n");
        gbKey = (int*)malloc(alignedGpuTupleNum * sizeof(int));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gbKey, gpuGbKey, alignedGpuTupleNum * sizeof(int), cudaMemcpyDeviceToHost));
        printf("vecCol attrSize = %d\n", gb->table->attrSize[video_similarity_index]);
        printf("tupleNum = %ld\n", gb->table->tupleNum);
        int colSize = gb->table->attrSize[video_similarity_index] * gb->table->tupleNum;
        std::vector<float> vecCol(colSize);
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(vecCol.data(), gb->table->content[video_similarity_index], colSize, cudaMemcpyDeviceToHost));
        // for(int i = 0; i < alignedGpuTupleNum; i++){
        //     printf("[gbKey] gbKey[%d] = %d\n", i, gbKey[i]);
        // }
        int vecSize = gb->table->attrSize[video_similarity_index] / sizeof(float);
        printf("vecSize = %d\n", vecSize);
        std::map<int, std::vector<float>> hashmap;
        for(int i = 0; i < gb->table->tupleNum; i++){
            int key = gbKey[i];
            std::vector<float> vectorToAdd;
            int startIdx = i * vecSize;
            // printf("startIdx = %d(i * 2048?)\n", startIdx);
            for (int j = 0; j < vecSize; ++j) {
                vectorToAdd.push_back(vecCol[startIdx + j]);
            }
            hashmap[key].insert(hashmap[key].end(), vectorToAdd.begin(), vectorToAdd.end());
        }
        std::vector<float> searchV;
        loadFloatArray(searchV, gb->gbExp[video_similarity_index].videoFeaturePath);
        searchFrameNum = searchV.size() / vecSize;
        printf("searchFrameNum = %d\n", searchFrameNum);
        // for(int i = 0; i < searchFrameNum; i++){
        //     printf("searchV[%d] = %f\n", i, searchV[i]);
        // }
        // process distance
        std::map<int, std::vector<float>> distmap;

        // for searchV
        //      for datasetV
        distmap = calcDistances(searchV, hashmap, vecSize);
        // for (const auto& pair : distmap) {
        //     int key = pair.first;
        //     const std::vector<float>& value = pair.second;

        //     printf("key = %d\n", key);
        //     printf("vec size = %d\n", value.size());
        //     printf("key video size = %d\n", value.size() * 2048 / searchV.size());
        // }
        
        //cal video_similarity
        ThreadPool pool(16);
        std::map<int, float> scoremap;

        
        // for(auto& pair : distmap) {
        //     int refLen = (pair.second).size() / searchFrameNum;
        //     for (int i = 0; i < searchFrameNum; ++i) {
        //         for (int j = 0; j < refLen; ++j) {
        //             std::cout << (pair.second)[i * refLen + j] << "\t";
        //         }
        //     std::cout << std::endl;
        //     }
        // }

        for(auto& pair : distmap) {
            pool.enqueue([&scoremap, &pair, searchFrameNum]() {
                std::vector<std::vector<int>> seq;
                std::vector<int> seqScore;
                int res = calScore(pair.second, searchFrameNum, seq, seqScore);
                // printf("score[%d] = %d\n", pair.first, res);
                std::lock_guard<std::mutex> lock(resmap_mutex);
                scoremap[pair.first] = res;
            });
        }

        while(1){
            if(pool.allTasksCompleted()) {
                std::cout << "All tasks are done!" << std::endl;
                break;
            }
        }

        std::vector<int> keys;
        std::vector<float> values;
        for (const auto& pair : scoremap) {
            keys.push_back(pair.first);
            values.push_back(pair.second);
        }
        d_num = keys.size();

        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&d_keys, keys.size() * sizeof(int)));
        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&d_values, values.size() * sizeof(float)));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(d_keys, keys.data(), keys.size() * sizeof(int), cudaMemcpyHostToDevice));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(d_values, values.data(), values.size() * sizeof(float), cudaMemcpyHostToDevice));
    
        // for(int i = 0; i < values.size(); i++){
        //     printf("values[%d] = %f\n", i, values[i]);
        // }
    } else if (video_similarity_exist == 1 and video_similarity_type == 1) {
        // video_similarity(distance(v1, v2)) 
        printf("video_similarity(distance(v1, v2))\n");
        gbKey = (int*)malloc(alignedGpuTupleNum * sizeof(int));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gbKey, gpuGbKey, alignedGpuTupleNum * sizeof(int), cudaMemcpyDeviceToHost));
        printf("vecCol attrSize = %d\n", gb->table->attrSize[video_similarity_index]);
        printf("tupleNum = %ld\n", gb->table->tupleNum);
        int colSize = gb->table->attrSize[video_similarity_index] * gb->table->tupleNum;
        std::vector<float> vecCol(colSize);
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(vecCol.data(), gb->table->content[video_similarity_index], colSize, cudaMemcpyDeviceToHost));
        std::map<int, std::vector<float>> distmap;
        for(int i = 0; i < gb->table->tupleNum; i++){
            int key = gbKey[i];
            distmap[key].push_back(vecCol[i]);
        }

        std::cout << std::fixed << std::setprecision(7);
        // for(auto& pair : distmap) {
        //     int refLen = (pair.second).size() / searchFrameNum;
        //     for (int i = 0; i < searchFrameNum; ++i) {
        //         for (int j = 0; j < refLen; ++j) {
        //             std::cout << (pair.second)[i * refLen + j] << "\t";
        //         }
        //     std::cout << std::endl;
        //     }
        //     std::cout << std::endl;
        // }

        // multi threads
        ThreadPool pool(16);
        std::map<int, float> scoremap;
        for(auto& pair : distmap) {
            pool.enqueue([&scoremap, &pair, searchFrameNum]() {
                std::vector<std::vector<int>> seq;
                std::vector<int> seqScore;
                int res = calScore(pair.second, searchFrameNum, seq, seqScore);
                printf("score[%d] = %d\n", pair.first, res);
                std::lock_guard<std::mutex> lock(resmap_mutex);
                scoremap[pair.first] = res;
            });
        }
        while(1){
            if(pool.allTasksCompleted()) {
                std::cout << "All tasks are done!" << std::endl;
                break;
            }
        }

        // single thread
        // std::map<int, float> scoremap;
        // for(auto& pair : distmap) {
        //     std::vector<std::vector<int>> seq;
        //     std::vector<int> seqScore;
        //     printf("dist vec size = %d, searchFrameNum = %d\n", pair.second.size(), searchFrameNum);
        //     int res = calScore(pair.second, searchFrameNum, seq, seqScore);
        //     printf("score[%d] = %d\n", pair.first, res);
        //     scoremap[pair.first] = res;
        // }

        std::vector<int> keys;
        std::vector<float> values;
        for (const auto& pair : scoremap) {
            keys.push_back(pair.first);
            values.push_back(pair.second);
        }
        d_num = keys.size();

        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&d_keys, keys.size() * sizeof(int)));
        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&d_values, values.size() * sizeof(float)));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(d_keys, keys.data(), keys.size() * sizeof(int), cudaMemcpyHostToDevice));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(d_values, values.data(), values.size() * sizeof(float), cudaMemcpyHostToDevice));
    
        for(int i = 0; i < values.size(); i++){
            printf("values[%d] = %f\n", i, values[i]);
        }
    }

    

    //Start timer for Step 5 - Allocate memory for result
    struct timespec startS5, endS5;
    clock_gettime(CLOCK_REALTIME,&startS5);

    char ** gpuResult = NULL;
    char ** result = NULL;

    // if(host_mp == NULL) {
    result = (char **)malloc(sizeof(char*)*res->totalAttr);
    CHECK_POINTER(result);
    // } else
    //     result = (char **) host_mp->alloc(sizeof(char *) * res->totalAttr);

    // if(dev_mp == NULL)
    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpuResult, sizeof(char *)* res->totalAttr));
    // else
        // gpuResult = (char **) dev_mp->alloc(sizeof(char *) * res->totalAttr);

    //Stop for 5 - Allocate memory for result
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS5);
    pp->groupby_step5_AllocRes += (endS5.tv_sec - startS5.tv_sec)* BILLION + endS5.tv_nsec - startS5.tv_nsec;

    //Start timer for Step 6 - Copy columns to device
    struct timespec startS6, endS6;
    clock_gettime(CLOCK_REALTIME,&startS6);

    printf("[groupby] res->tupleNum = %ld\n", res->tupleNum);
    printf("[groupby] res->totalAttr = %d\n", res->totalAttr);
    for(int i=0; i<res->totalAttr;i++){
        printf("[groupby] res->attrSize[%d] = %d\n", i, res->attrSize[i]);
    }

    for(int i=0; i<res->totalAttr;i++){
        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&result[i], res->tupleNum * res->attrSize[i]));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemset(result[i], 0, res->tupleNum * res->attrSize[i]));
        res->content[i] = result[i]; 
        res->dataPos[i] = GPU;
        res->attrTotalSize[i] = res->tupleNum * res->attrSize[i];
        //CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(&gpuResult[i], &result[i], sizeof(char *), cudaMemcpyHostToDevice));

        if(gb->gbExp[i].func == MIN && res->attrSize[i] == sizeof(int))
            init_int_array<<<grid, block>>>((int *)result[i], res->tupleNum, FLOAT_MAX);
        else if(gb->gbExp[i].func == MAX && res->attrSize[i] == sizeof(int))
            init_int_array<<<grid, block>>>((int *)result[i], res->tupleNum, FLOAT_MIN);
    }
    CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy(gpuResult, result, sizeof(char *) * res->totalAttr, cudaMemcpyHostToDevice) );

    // if(dev_mp == NULL)
    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuGbType, sizeof(int)*res->totalAttr));
    // else
    //     gpuGbType = (int *) dev_mp->alloc(sizeof(int) * res->totalAttr);
    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuGbType, res->attrType, sizeof(int)*res->totalAttr, cudaMemcpyHostToDevice));

    // if(dev_mp == NULL)
    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuGbSize, sizeof(int)*res->totalAttr));
    // else
    //     gpuGbSize = (int *) dev_mp->alloc(sizeof(int) * res->totalAttr);
    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuGbSize, res->attrSize, sizeof(int)*res->totalAttr, cudaMemcpyHostToDevice));

    struct groupByExp *gpuGbExp;
    // if(dev_mp == NULL)
    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpuGbExp, sizeof(struct groupByExp)*res->totalAttr));
    // else
    //     gpuGbExp = (struct groupByExp *) dev_mp->alloc(sizeof(struct groupByExp) * res->totalAttr);
    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuGbExp, gb->gbExp, sizeof(struct groupByExp)*res->totalAttr, cudaMemcpyHostToDevice));

    for(int i=0;i<res->totalAttr;i++){
        struct mathExp * tmpMath;
        if(gb->gbExp[i].exp.opNum == 2){
            if(dev_mp == NULL)
                CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&tmpMath, 2* sizeof(struct mathExp)));
            else
                tmpMath = (struct mathExp *) dev_mp->alloc(2 * sizeof(struct mathExp));
            CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(tmpMath,(struct mathExp*)gb->gbExp[i].exp.exp,2*sizeof(struct mathExp), cudaMemcpyHostToDevice));
            CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(&(gpuGbExp[i].exp.exp), &tmpMath, sizeof(struct mathExp *), cudaMemcpyHostToDevice));
        }
    }

    gpuGbColNum = res->totalAttr;

    //Stop for 6 - Copy columns to device
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS6);
    pp->groupby_step6_copyDataCols += (endS6.tv_sec - startS6.tv_sec)* BILLION + endS6.tv_nsec - startS6.tv_nsec;

    
    
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
        printf("CUDA Error: %s\n", cudaGetErrorString(err));
    }
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing

    //Start timer for Step 7 - Calculate aggregate values
    struct timespec startS7, endS7;
    clock_gettime(CLOCK_REALTIME,&startS7);

    if(gbConstant !=1){
        if(video_similarity_exist != 1)
            agg_cal<<<grid,block>>>(gpuContent, gpuGbColNum, gpuGbExp, gpuGbType, gpuGbSize, gpuTupleNum, gpuGbKey, gpu_psum, gpu_groupNum,gpuResult);
        else{
            agg_cal<<<grid,block>>>(gpuContent, gpuGbColNum, gpuGbExp, gpuGbType, gpuGbSize, gpuTupleNum, gpuGbKey, gpu_psum, gpu_groupNum,gpuResult, d_keys, d_values, d_num);
        }
        if(dev_mp == NULL) {
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuGbKey));
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_psum));
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_groupNum));
        }
    }
    else{
        if(gb->gbExp[0].func != OUTLIER_LINE){
            printf("[groupby] gb->gbExp[0].func != OUTLIER_LINE\n");
            agg_cal_cons<<<grid,block>>>(gpuContent, gpuGbColNum, gpuGbExp, gpuTupleNum,gpuResult);
        }else{
            printf("[OUTLIER_LINE] OUTLIER_LINE Processing\n");
            int colIndex = gb->gbExp[0].index;
            // dims of vector column
            int size = gb->table->attrSize[colIndex] / sizeof(float);
            printf("colIndex = %d\n", colIndex);
            size_t num  = gb->table->tupleNum;
            // obtain vector column
            // float *dataf = NULL;
            // CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&dataf, sizeof(float) * size * num));
            // CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(dataf, gb->table->content[colIndex], sizeof(float) * size * num, cudaMemcpyHostToDevice));
            float *dataf = (float*)(gb->table->content[colIndex]);

            // for(int i = 0; i < 19*10; i++){
            //     printf("%f\n", dataf[i]);
            // }
            CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing

            // init faiss index
            faiss::gpu::StandardGpuResources resources;
            faiss::gpu::GpuIndexFlatConfig config;
            config.device = 0;
            int dim = size;
            
            printf("[outlier_line] tupleNum = %ld\n", num);
            printf("[outlier_line] column dim = %d\n", dim);
    
            CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing

            // for(int i = 0; i < 190; i++){
            //     printf("float[%d] = %f\n", i, dataf[i]);
            // }

            
            faiss::gpu::GpuIndexFlatL2 gpuIndex(&resources, dim, config);

            printf("BreakPoint\n");
            CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
            cudaError_t err = cudaGetLastError();
            if (err != cudaSuccess) {
                printf("CUDA Error: %s\n", cudaGetErrorString(err));
            }


            gpuIndex.add(num, dataf);
            CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
            
            printf("BreakPoint before Faiss search\n");
            // ANNs search for each element in column
            int k = 11;
            float* dist = (float*)malloc( num * k * sizeof(float));
            faiss::idx_t* ind = (faiss::idx_t*)malloc(num * k * sizeof(faiss::idx_t));
            gpuIndex.search(num, dataf, k, dist, ind);
            std::vector<float> sum(num);

            // Compute averages
            for (int i = 0; i < num; ++i) {
                sum[i] = computeSumForSegment(dist, i * k, k);
                // printf("%f\n", sum[i]);
            }

            // Sort the averages
            std::sort(sum.begin(), sum.end());

            // Get the 90% value
            int index = static_cast<int>(0.999 * num);
            float outlier_line = sum[index];

            printf("[outlier_line] 90 percent of device distance = %f\n", outlier_line);
            
            cudaMemcpy(res->content[colIndex], &outlier_line, sizeof(float), cudaMemcpyHostToDevice);

            // float *distSumHost = (float*)malloc(sizeof(float) * num);
            // CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(distSumHost, distSum, num * sizeof(float), cudaMemcpyDeviceToHost));
            // int n = sizeof(distSumHost) / sizeof(distSumHost[0]);
            // printf("distSum size = %d\n", n);
            // std::sort(distSumHost, distSumHost + n);
            // int pos = static_cast<int>(num * 0.9) - 1;
            // printf("[outlier_line] 90% of host distance = %f", distSumHost[pos]);
        }
    }

    if (outlier_score_index == 1){
        // copy column to HOST
        float *scoreCol = (float*)malloc(sizeof(float) * gbCount);
        int *idCol = (int*)malloc(sizeof(int) * gbCount);
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(scoreCol, result[outlier_score_index], sizeof(float) * gbCount, cudaMemcpyDeviceToHost));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(idCol, result[1-outlier_score_index], sizeof(int) * gbCount, cudaMemcpyDeviceToHost));
        
        float *finalScoreCol = (float*)malloc(sizeof(float) * gbCount);
        float curScore = 0;
        int curPos = 0;
        
        normalize(scoreCol, gbCount);
        
        // perform sequential processing on outlier_score
        for(int i = 0; i < gbCount; i++){
            if(idCol[i] - curPos > 4){
                curScore = 0;
                finalScoreCol[i] = curScore;
                curPos = idCol[i];
            } else {
                curScore += scoreCol[i];
                finalScoreCol[i] = curScore;
                curPos = idCol[i];
            }
        }
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(result[outlier_score_index], finalScoreCol, sizeof(float) * gbCount, cudaMemcpyHostToDevice));
    }

    //Stop for 7 - Calculate aggregate values
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS7);
    pp->groupby_step7_computeAgg += (endS7.tv_sec - startS7.tv_sec)* BILLION + endS7.tv_nsec - startS7.tv_nsec;

    //Start timer for Step 8 - De-allocate memory
    struct timespec startS8, endS8;
    clock_gettime(CLOCK_REALTIME,&startS8);

    for(int i=0; i<gb->table->totalAttr;i++){
        if(gb->table->dataPos[i]==MEM)
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(column[i]));
    }
    if(host_mp == NULL)
        free(column);
    if(dev_mp == NULL) {
        CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuContent));
        CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuGbType));
        CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuGbSize));
        CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuGbExp));
        CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuResult));
    }

    //Stop for 8 - De-allocate memory
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS8);
    pp->groupby_step8_deallocate += (endS8.tv_sec - startS8.tv_sec)* BILLION + endS8.tv_nsec - startS8.tv_nsec;
    
    //Stop total timer
    clock_gettime(CLOCK_REALTIME, &endS0);
    pp->groupby_totalTime += (endS0.tv_sec - startS0.tv_sec)* BILLION + endS0.tv_nsec - startS0.tv_nsec;
    
    //Increase count call
    pp->groupby_callTimes++;


    // cudaMemcpy(intArray, res->content[0], sizeof(char) * 23 * res->tupleNum, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < res->tupleNum; i++){
    //     printf("video_name[%d] = ", i);
	// 	for(int j = 0; j < 23; j++){
    //         printf("%c", intArray[i*23 + j]);
    //     }
    //     printf("\n");
	// }

    // char floatArray[1024];
    // cudaMemcpy(floatArray, res->content[1], sizeof(float) * res->tupleNum, cudaMemcpyDeviceToHost);
	// for(int i = 0; i < res->tupleNum; i++){
	// 	printf("score[%d] = %f\n", i, ((float *)floatArray)[i]);
	// }

    // printf("[groupBy] attrType[1] :%d\n", res->attrType[1]);
    cudaMemcpy(disArray, res->content[1], sizeof(float) * res->tupleNum, cudaMemcpyDeviceToHost);
    for(int j = 0; j < 100; j++){
        printf("%f\t", disArray[j]);
    }

    // printf("[groupBy] attrType[0] :%d\n", res->attrType[0]);
    // cudaMemcpy(disArray, res->content[0], res->attrSize[0] * res->tupleNum, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 1; i++){
    //     printf("%f\n", disArray[i]);
    // }

    printf("[groupby] tupleSize = %d\n", res->tupleSize);
    
    clock_gettime(CLOCK_REALTIME,&e);
    tt = (e.tv_sec - s.tv_sec)* BILLION + e.tv_nsec - s.tv_nsec;
    printf("tt = %f\n", tt/(1000*1000));
    printf("<--Groupby Time -->    : %lf\n\n", pp->groupby_totalTime/(1000*1000));
    return res;
}
