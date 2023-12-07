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
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
#include <cuda.h>
#include <time.h>
#include "../include/common.h"
#include "../include/hashJoin.h"
#include "../include/gpuCudaLib.h"
#include "scanImpl.cu"
#include <thrust/scan.h>
#include <thrust/execution_policy.h>

#include "../include/Mempool.h"

/*
 * copy left table column.
 */

__global__ void joinLeft(char* result, char* column, int attrSize, int num, int count) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < num * count) {
        // cal index of current tid
        int elementIdx = tid / count;

        // initial path
        char* src = column + elementIdx * attrSize;
        char* dst = result + tid * attrSize;

        // copy element
        memcpy(result + tid * attrSize, column + elementIdx * attrSize, attrSize);
    }
}

__global__ void joinRight(char* result, char* column, int attrSize, int num, int count) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    if (tid < count) {
        memcpy(result + tid * attrSize * num, column, attrSize * num);
    }
}

// __global__ void joinRight(char* result, char* column, int attrSize, int num, int count) {
//     int tid = blockIdx.x * blockDim.x + threadIdx.x;
//     int totalSize = attrSize * num;

//     // Total number of operations required
//     int operations = count * totalSize;

//     // Each thread copies one element (byte in this case)
//     if (tid < operations) {
//         int destIdx = tid + (tid / totalSize) * totalSize; // calculate destination index by skipping the already copied chunks
//         result[destIdx] = column[tid % totalSize]; // copy data from column to result
//     }
// }

/*
 * hashJoin implements the foreign key join between a fact table and dimension table.
 *
 * Prerequisites:
 *  1. the data to be joined can be fit into GPU device memory.
 *  2. dimension table is not compressed
 *  
 * Input:
 *  jNode: contains information about the two joined tables.
 *  pp: records statistics such as kernel execution time
 *
 * Output:
 *  A new table node
 */

struct tableNode * cartesianProductJoin(struct joinNode *jNode, struct statistic *pp,
                            Mempool *host_mp = NULL, Mempool *dev_mp = NULL, Mempool *res_mp = NULL, int *rightTableHash = NULL){

    // test cartesian input
    // int count = 5;
    // float * test = (float *)malloc(sizeof(float) * 2048 * count);
    // cudaMemcpy(test, jNode->rightTable->content[1], sizeof(float) * 2048 * count, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 2048 * count; i++){
    //     printf("(right table) column[%d] = %f\n", i, test[i]);
    // }
    // cudaMemcpy(test, jNode->leftTable->content[0], sizeof(float) * 2048 * count, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 2048 * count; i++){
    //     printf("(left table) column[%d] = %f\n", i, test[i]);
    // }

    printf("\n================ [cartesianProductJoin.cu] Start ================\n");

    //Start total timer
    struct timespec startS0, endS0;
    clock_gettime(CLOCK_REALTIME,&startS0);

    //Start timer for Step 1 - Allocate memory for intermediate results
    struct timespec startS1, endS1;
    clock_gettime(CLOCK_REALTIME,&startS1);

    struct tableNode * res = NULL;

    char *gpu_result = NULL, *gpu_fact = NULL;

    int defaultBlock = 4096;
    dim3 grid(defaultBlock);
    dim3 block(256);

    int blockNum;
    int threadNum;

    // blockNum = jNode->leftTable->tupleNum / block.x + 1;
    // if(blockNum < defaultBlock)
    //     grid = blockNum;
    // else
    //     grid = defaultBlock;
    // grid = 1;

    res = (struct tableNode*) malloc(sizeof(struct tableNode));
    CHECK_POINTER(res);

    res->totalAttr = jNode->totalAttr;
    res->tupleSize = jNode->tupleSize;
    res->attrType = (int *) malloc(res->totalAttr * sizeof(int));
    CHECK_POINTER(res->attrType);
    res->attrSize = (int *) malloc(res->totalAttr * sizeof(int));
    CHECK_POINTER(res->attrSize);
    res->attrIndex = (int *) malloc(res->totalAttr * sizeof(int));
    CHECK_POINTER(res->attrIndex);
    res->attrTotalSize = (int *) malloc(res->totalAttr * sizeof(int));
    CHECK_POINTER(res->attrTotalSize);
    res->dataPos = (int *) malloc(res->totalAttr * sizeof(int));
    CHECK_POINTER(res->dataPos);
    res->dataFormat = (int *) malloc(res->totalAttr * sizeof(int));
    CHECK_POINTER(res->dataFormat);
    res->content = (char **) malloc(res->totalAttr * sizeof(char *));
    CHECK_POINTER(res->content);

    for(int i=0;i<jNode->leftOutputAttrNum;i++){
        int pos = jNode->leftPos[i];
        res->attrType[pos] = jNode->leftOutputAttrType[i];
        int index = jNode->leftOutputIndex[i];
        res->attrSize[pos] = jNode->leftTable->attrSize[index];
        res->dataFormat[pos] = UNCOMPRESSED;
    }

    for(int i=0;i<jNode->rightOutputAttrNum;i++){
        int pos = jNode->rightPos[i];
        res->attrType[pos] = jNode->rightOutputAttrType[i];
        int index = jNode->rightOutputIndex[i];
        res->attrSize[pos] = jNode->rightTable->attrSize[index];
        res->dataFormat[pos] = UNCOMPRESSED;
    }

    long primaryKeySize = sizeof(int) * jNode->rightTable->tupleNum;

    //Stop for Step 1 - Allocate memory for intermediate results
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS1);
    pp->joinProf_step1_allocateMem += (endS1.tv_sec - startS1.tv_sec)* BILLION + endS1.tv_nsec - startS1.tv_nsec;

    //Start timer for Step 3 - Join
    struct timespec startS3, endS3;
    clock_gettime(CLOCK_REALTIME,&startS3);

   /*
    *  join on GPU
    */

    int leftTupleNum = jNode->leftTable->tupleNum;
    int rightTupleNum = jNode->rightTable->tupleNum;
    threadNum = grid.x * block.x;
    
    // printf("Join Thread number %d\n", threadNum);
    //sc 20 -> 512, 256
    //sc 15 -> 256, 256

    res->tupleNum = jNode->leftTable->tupleNum * jNode->rightTable->tupleNum;
    
    //Start timer for Step 4 - Materialize result
    struct timespec startS4, endS4;
    clock_gettime(CLOCK_REALTIME,&startS4);

    for(int i=0; i<res->totalAttr; i++){
        int index, pos;
        long colSize = 0, resSize = 0;
        int leftRight = 0;

        int attrSize, attrType;
        char * table = NULL;
        int found = 0 , dataPos, format;

        if (jNode->keepInGpu[i] == 1)
            res->dataPos[i] = GPU;
        else
            res->dataPos[i] = MEM;

        for(int k=0;k<jNode->leftOutputAttrNum;k++){
            if (jNode->leftPos[k] == i){
                found = 1;
                leftRight = 0;
                pos = k;
                break;
            }
        }
        if(!found){
            for(int k=0;k<jNode->rightOutputAttrNum;k++){
                if(jNode->rightPos[k] == i){
                    found = 1;
                    leftRight = 1;
                    pos = k;
                    break;
                }
            }
        }

        if(leftRight == 0){
            index = jNode->leftOutputIndex[pos];
            dataPos = jNode->leftTable->dataPos[index];
            format = jNode->leftTable->dataFormat[index];

            table = jNode->leftTable->content[index];
            attrSize  = jNode->leftTable->attrSize[index];
            attrType  = jNode->leftTable->attrType[index];
            colSize = jNode->leftTable->attrTotalSize[index];

            resSize = res->tupleNum * attrSize;
        }else{
            index = jNode->rightOutputIndex[pos];
            dataPos = jNode->rightTable->dataPos[index];
            format = jNode->rightTable->dataFormat[index];

            table = jNode->rightTable->content[index];
            attrSize = jNode->rightTable->attrSize[index];
            attrType = jNode->rightTable->attrType[index];
            colSize = jNode->rightTable->attrTotalSize[index];

            resSize = attrSize * res->tupleNum;
            leftRight = 1;
        }

        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_result,resSize));


        if(leftRight == 0){

            //Start timer for Step 41 - Materialize left table result
            struct timespec startS41, endS41;
            clock_gettime(CLOCK_REALTIME,&startS41);

            if(format == UNCOMPRESSED){

                if(dataPos == MEM || dataPos == MMAP || dataPos == PINNED){
                    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpu_fact, colSize));
                    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_fact, table, colSize,cudaMemcpyHostToDevice));
                }else{
                    gpu_fact = table;
                }
                
                int threadsPerBlock = 256;
                int blocks = (leftTupleNum * rightTupleNum + threadsPerBlock - 1) / threadsPerBlock;
                joinLeft<<<blocks,threadsPerBlock>>>(gpu_result, gpu_fact, attrSize, leftTupleNum, rightTupleNum);
                CUDA_SAFE_CALL_NO_SYNC(cudaDeviceSynchronize());
                // if(attrSize == sizeof(int))
                //     joinFact_int<<<grid,block>>>(filterPsum,gpu_fact, attrSize, jNode->leftTable->tupleNum,filterNum,gpu_result);
                // else
                //     joinFact_other<<<grid,block>>>(gpu_resPsum,gpu_fact, attrSize, jNode->leftTable->tupleNum,gpuFactFilter,gpu_result);

            }

            //Stop for Step 41 - Materialize left table result
            CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
            clock_gettime(CLOCK_REALTIME, &endS41);
            pp->joinProf_step41_materialize_res_left += (endS41.tv_sec - startS41.tv_sec)* BILLION + endS41.tv_nsec - startS41.tv_nsec;

        }else{

            //Start timer for Step 42 - Materialize right table result
            struct timespec startS42, endS42;
            clock_gettime(CLOCK_REALTIME,&startS42);

            if(format == UNCOMPRESSED){

                if(dataPos == MEM || dataPos == MMAP || dataPos == PINNED){
                    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpu_fact, colSize));
                    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_fact, table, colSize,cudaMemcpyHostToDevice));
                }else{
                    gpu_fact = table;
                }

                int block = 256;
                int grid = (leftTupleNum * rightTupleNum * attrSize + block - 1) / block;
                printf("[cartesianJoin] attrSize = %d, rightTupleNum = %d, leftTupleNum = %d\n", attrSize, rightTupleNum, leftTupleNum);
                joinRight<<<grid, block>>>(gpu_result, gpu_fact, attrSize, rightTupleNum, leftTupleNum);
                CUDA_SAFE_CALL_NO_SYNC(cudaDeviceSynchronize());
                // if(attrType == sizeof(int))
                //     joinDim_int_new<<<grid,block>>>(filterPsum,gpu_fact, attrSize, jNode->leftTable->tupleNum, filterNum, JRes, gpu_result);
                // else
                //     joinDim_other<<<grid,block>>>(gpu_resPsum,gpu_fact, attrSize, jNode->leftTable->tupleNum, gpuFactFilter,gpu_result);

            }

            //Stop for Step 42 - Materialize right table result
            CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
            clock_gettime(CLOCK_REALTIME, &endS42);
            pp->joinProf_step42_materialize_res_right += (endS42.tv_sec - startS42.tv_sec)* BILLION + endS42.tv_nsec - startS42.tv_nsec;
        }
        
        res->attrTotalSize[i] = resSize;
        res->dataFormat[i] = UNCOMPRESSED;
        if(res->dataPos[i] == MEM){
            res->content[i] = (char *) malloc(resSize);
            memset(res->content[i],0,resSize);
            CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(res->content[i],gpu_result,resSize,cudaMemcpyDeviceToHost));
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_result));

        }else if(res->dataPos[i] == GPU){
            res->content[i] = gpu_result;
        }
        if(dataPos == MEM || dataPos == MMAP || dataPos == PINNED)
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_fact));

    }

    //Stop for Step 4 - Materialize result
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS4);
    pp->joinProf_step4_materialize_res += (endS4.tv_sec - startS4.tv_sec)* BILLION + endS4.tv_nsec - startS4.tv_nsec;
    
    //Stop total timer
    clock_gettime(CLOCK_REALTIME, &endS0);
    pp->cartesianJoin_totalTime += (endS0.tv_sec - startS0.tv_sec)* BILLION + endS0.tv_nsec - startS0.tv_nsec;
    
    //Increase count call
    pp->join_callTimes++;

    // test cartesian output
    // cudaMemcpy(test, res->content[1], sizeof(float) * 2048 * count, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 2048 * count; i++){
    //     printf("(cartesianProductJoin) column[%d] = %f\n", i, test[i]);
    // }

    return res;

}
