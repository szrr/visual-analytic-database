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
#include "../include/utils.h"
#include "../include/hashJoin.h"
#include "../include/gpuCudaLib.h"
#include "scanImpl.cu"
#include <thrust/scan.h>
#include <thrust/execution_policy.h>

#include "../include/Mempool.h"

#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>

#include <faiss/gpu/GpuAutoTune.h>
#include <faiss/gpu/GpuCloner.h>
#include <faiss/gpu/GpuIndexIVFPQ.h>
#include <faiss/gpu/StandardGpuResources.h>
#include <faiss/index_io.h>
#include <faiss/IndexFlat.h>
#include <faiss/IndexIVFPQ.h>

__global__ static void copy_left_table(const char* data, size_t size, int num, int k, char* result) {
    int index = threadIdx.x + blockIdx.x * blockDim.x;

    if (index < num) {
        const char* src = data + index * size;
        char* dest = result + index * size * k;

        for (int i = 0; i < k; i++) {
            memcpy(dest, src, size);
            dest += size;
        }
    }
}

__global__ static void copy_right_table(const char* data, size_t size, int num, const long* nns, char* result) {
    int index = threadIdx.x + blockIdx.x * blockDim.x;

    if (index < num) {
        long nn = nns[index];
        const char* src = data + nn * size;
        char* dest = result + index * size;

        memcpy(dest, src, size);
    }
}

struct tableNode * knnJoin(struct joinNode *jNode, struct statistic *pp,
                            Mempool *host_mp = NULL, Mempool *dev_mp = NULL, Mempool *res_mp = NULL, int *rightTableHash = NULL, faiss::Index *faiss_index = NULL){

    // float *disArray = (float*)malloc(1024*1024);
    // printf("[driver.cu] the type of result[0] = %d\n", jNode->rightTable->attrType[0]);
    // printf("dataset_videoTable->attrSize[0] = %d\n", jNode->rightTable->attrSize[0]);
    // printf("dataset_videoTable->tupleNum = %d\n", jNode->rightTable->tupleNum);
    // memcpy(disArray, jNode->rightTable->content[0], sizeof(char) * jNode->rightTable->attrSize[0] * jNode->rightTable->tupleNum);
    // for(int i = 0; i < 100; i++){
    //     printf("search feature[%d] = ", i);
    //     for(int j = 0; j < 19; j++){
    //         printf("%f\t", disArray[i*19 + j]);
    //     }
    //     printf("\n");
    // }

    printf("================ [knnJoin.cu] Start ================\n");
    struct timespec annsAddStart, annsAddEnd;
    struct timespec annsSearchStart, annsSearchEnd;
    struct timespec readIndexStart, readIndexEnd;
    struct timespec start, end;
    struct timespec annsStart, annsEnd;

    //Start total timer
    struct timespec startS0, endS0;
    clock_gettime(CLOCK_REALTIME,&startS0);

    struct tableNode * res = NULL;

    char *gpu_result = NULL;
    int *gpu_count = NULL;
    long *gpu_nns = NULL;

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
    grid = 1;

    if(host_mp == NULL) {
        res = (struct tableNode*) malloc(sizeof(struct tableNode));
        CHECK_POINTER(res);
    }else
        res = (struct tableNode *) host_mp->alloc(sizeof(struct tableNode));

    
    res->totalAttr = jNode->totalAttr;
    res->tupleSize = jNode->tupleSize;
    res->tupleNum = jNode->nearestk * jNode->leftTable->tupleNum;
    if(host_mp == NULL) {
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
    }else{
        res->attrType = (int *) host_mp->alloc(res->totalAttr * sizeof(int));
        res->attrSize = (int *) host_mp->alloc(res->totalAttr * sizeof(int));
        res->attrIndex = (int *) host_mp->alloc(res->totalAttr * sizeof(int));
        res->attrTotalSize = (int *) host_mp->alloc(res->totalAttr * sizeof(int));
        res->dataPos = (int *) host_mp->alloc(res->totalAttr * sizeof(int));
        res->dataFormat = (int *) host_mp->alloc(res->totalAttr * sizeof(int));
        res->content = (char **) host_mp->alloc(res->totalAttr * sizeof(char *));
    }

    for(int i=0;i<jNode->leftOutputAttrNum;i++){
        int pos = jNode->leftPos[i];
        res->attrType[pos] = jNode->leftOutputAttrType[i];
        int index = jNode->leftOutputIndex[i];
        res->attrSize[pos] = jNode->leftTable->attrSize[index];
        res->dataFormat[pos] = UNCOMPRESSED;
        res->attrTotalSize[pos] = res->attrSize[pos] * res->tupleNum;
    }

    for(int i=0;i<jNode->rightOutputAttrNum;i++){
        int pos = jNode->rightPos[i];
        res->attrType[pos] = jNode->rightOutputAttrType[i];
        int index = jNode->rightOutputIndex[i];
        res->attrSize[pos] = jNode->rightTable->attrSize[index];
        res->dataFormat[pos] = UNCOMPRESSED;
        res->attrTotalSize[pos] = res->attrSize[pos] * res->tupleNum;
    }
    

    /* generate nearest neighbor index
       search vector : left table join index
       search data   : right table join index
       index length  : left table tupleNum * nearestk
    */

    printf("[knnJoin] left tupleNum = %ld\n", jNode->leftTable->tupleNum);

    // int searchIndex = jNode->leftKeyIndex;
    float *searhVec = (float *)(jNode->leftTable->content[jNode->leftKeyIndex]);
    float *feature = (float *)(jNode->rightTable->content[jNode->rightKeyIndex]);
    size_t feature_num = (size_t)(jNode->rightTable->tupleNum);
    char index_path[256];
    memset(index_path, '\0', sizeof(index_path));
    if(jNode->rightTable->attrName != NULL) {
        strcat(index_path, jNode->rightTable->attrName[jNode->rightKeyIndex]);
        strcat(index_path, "_index.faissindex");
    } else {
        printf("attrName not exist\n");
        exit(1);
    }
    int dev_no = 0;
    int k = jNode->nearestk;
    printf("k = %d\n", k);
    int nq = jNode->leftTable->tupleNum;  //query num
    std::vector<faiss::idx_t> nns(k * nq);
    std::vector<float> dis(k * nq);
    std::cout << "index path : " << index_path << std::endl;
    std::cout << "fileExists(index_path) = " << fileExists(index_path) << std::endl;

    clock_gettime(CLOCK_REALTIME,&annsStart);
    if(faiss_index != NULL){
        // searching...
        clock_gettime(CLOCK_REALTIME,&annsSearchStart);
        // index->search(nq, dFilter[i].searchVec.data(), k, dis.data(), nns.data());
        faiss_index->search(nq, searhVec, k, dis.data(), nns.data());
        clock_gettime(CLOCK_REALTIME,&annsSearchEnd);
        pp->indexSearch += (annsSearchEnd.tv_sec -  annsSearchStart.tv_sec)* BILLION + annsSearchEnd.tv_nsec - annsSearchStart.tv_nsec;
    }
    else if (fileExists(index_path)) {
        // read faiss index from index_path
        faiss::gpu::StandardGpuResources resources;
        clock_gettime(CLOCK_REALTIME,&readIndexStart);
        faiss::Index *index = faiss::read_index(index_path);
        clock_gettime(CLOCK_REALTIME,&readIndexEnd);
        double readIndexTotal = (readIndexEnd.tv_sec -  readIndexStart.tv_sec)* BILLION + readIndexEnd.tv_nsec - readIndexStart.tv_nsec;
        printf("read_index time: %f\n", readIndexTotal/(1000*1000));
        clock_gettime(CLOCK_REALTIME,&start);
        index = faiss::gpu::index_cpu_to_gpu(&resources, dev_no, index);
        clock_gettime(CLOCK_REALTIME,&end);
        double total = (end.tv_sec -  start.tv_sec)* BILLION + end.tv_nsec - start.tv_nsec;
        printf("index_cpu_to_gpu time: %f\n", total/(1000*1000));
        
        // add...
        // clock_gettime(CLOCK_REALTIME,&annsAddStart);
        // index->add(feature_num, feature);
        // clock_gettime(CLOCK_REALTIME,&annsAddEnd);
        // double annsAddTotal = (annsAddEnd.tv_sec -  annsAddStart.tv_sec)* BILLION + annsAddEnd.tv_nsec - annsAddStart.tv_nsec;
        // printf("Faiss add time: %f\n", annsAddTotal/(1000*1000));
        // searching...
        clock_gettime(CLOCK_REALTIME,&annsSearchStart);
        index->search(nq, searhVec, k, dis.data(), nns.data());
        clock_gettime(CLOCK_REALTIME,&annsSearchEnd);
        double annsSearchTotal = (annsSearchEnd.tv_sec -  annsSearchStart.tv_sec)* BILLION + annsSearchEnd.tv_nsec - annsSearchStart.tv_nsec;
        printf("Faiss Search time: %f\n", annsSearchTotal/(1000*1000));
    }
    else
    {
        // train index
        printf("Train faiss index\n");
        printf("feature_num = %ld\n", feature_num);

        // vector dims
        int d = jNode->leftTable->attrSize[jNode->leftKeyIndex] / sizeof(float);
        printf("dimensions = %d\n", d);

        // train feature num
        size_t nb = feature_num;
        
        printf("Initial faiss member parameters\n");
        faiss::gpu::StandardGpuResources resources;
        
        int remain = d % 4;
        // if d is not a multiple of 4, use FlatL2 index
        // else use IVFPQ
        if(remain or jNode->rightTable->tupleNum < 1000){
            // printf("dims is not a multiple of 4, use FlatL2\n");
            faiss::gpu::GpuIndexFlatConfig config;
            config.device = 0;
            faiss::gpu::GpuIndexFlatL2 gpuIndex(&resources, d, config);
            gpuIndex.add(nb, feature);

            // save index
            double t0 = elapsed();
            if(jNode->rightTable->attrName != NULL)
                write_index(faiss::gpu::index_gpu_to_cpu(&gpuIndex), index_path);
            printf("[%.3f s] Finish write_index() \n", elapsed() - t0);

            // searching...
            clock_gettime(CLOCK_REALTIME,&annsSearchStart);
            gpuIndex.search(nq, searhVec, k, dis.data(), nns.data());
            clock_gettime(CLOCK_REALTIME,&annsSearchEnd);
            double annsSearchTotal = (annsSearchEnd.tv_sec -  annsSearchStart.tv_sec)* BILLION + annsSearchEnd.tv_nsec - annsSearchStart.tv_nsec;
            printf("Faiss Search time: %f\n", annsSearchTotal/(1000*1000));
        }else{
            int ncentroids = int(sqrt(feature_num));
            faiss::gpu::GpuIndexIVFPQConfig config;
            config.device = dev_no;
            faiss::gpu::GpuIndexIVFPQ index(&resources, d, ncentroids, 4, 8, faiss::METRIC_L2, config);

            double t0 = elapsed();
            printf(" Generating %ld vectors in %dD for training\n",
                nb,
                d);

            index.train(feature_num, feature);
            printf("[%.3f s] Finish training \n", elapsed() - t0);
            
            index.add(feature_num, feature);

            // save index
            t0 = elapsed();
            if(jNode->rightTable->attrName != NULL)
                write_index(faiss::gpu::index_gpu_to_cpu(&index), index_path);
            printf("[%.3f s] Finish write_index() \n", elapsed() - t0);
            
            clock_gettime(CLOCK_REALTIME,&annsSearchStart);
            
            // searching...
            index.search(nq, searhVec, k, dis.data(), nns.data());

            clock_gettime(CLOCK_REALTIME,&annsSearchEnd);
            double annsSearchTotal = (annsSearchEnd.tv_sec -  annsSearchStart.tv_sec)* BILLION + annsSearchEnd.tv_nsec - annsSearchStart.tv_nsec;
            printf("Faiss Search time: %f\n", annsSearchTotal/(1000*1000));
        }
        
    }

    // for(int i = 0; i < nq; i++){
    //     float distance = 0.0;
    //     for(int j = 0; j < k; j++){
    //         distance += dis[i*k + j];
    //     }
    //     printf("%f\n", distance);
    // }

    clock_gettime(CLOCK_REALTIME,&annsEnd);
    pp->knn_ANNs_time += (annsEnd.tv_sec -  annsStart.tv_sec)* BILLION + annsEnd.tv_nsec - annsStart.tv_nsec;

    // for (int i = 0; i < nq; i++) {
    // for (int i = 0; i < 1; i++) {
    //     printf("query %2d: ", i);
    //     for (int j = 0; j < k; j++) {
    //         printf("%7ld ", nns[j + i * k]);
    //         printf(" %f ", disArray[nns[j + i * k]*19]);
    //     }
    //     printf("\n");
    // }

    // for(int i = 0; i < 100; i++){
    //     printf("search feature[%d] = ", i);
    //     for(int j = 0; j < 19; j++){
    //         printf("%f\t", disArray[i*19 + j]);
    //     }
    //     printf("\n");
    // }

    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_nns, sizeof(faiss::idx_t) * nns.size()));
    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpu_nns, nns.data(), sizeof(faiss::idx_t) * nns.size(), cudaMemcpyHostToDevice));

    clock_gettime(CLOCK_REALTIME,&start);
    
    /* join two table by nns */
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

        for(int j=0;j<jNode->leftOutputAttrNum;j++){
            if (jNode->leftPos[j] == i){
                found = 1;
                leftRight = 0;
                pos = j;
                break;
            }
        }
        if(!found){
            for(int j=0;j<jNode->rightOutputAttrNum;j++){
                if(jNode->rightPos[j] == i){
                    found = 1;
                    leftRight = 1;
                    pos = j;
                    break;
                }
            }
        }

        if(leftRight == 0){
            index = jNode->leftOutputIndex[pos];
            dataPos = jNode->leftTable->dataPos[index];
            format = jNode->leftTable->dataFormat[index];
            attrSize  = jNode->leftTable->attrSize[index];
            attrType  = jNode->leftTable->attrType[index];
            colSize = jNode->leftTable->attrTotalSize[index];

            if(dataPos == MEM) {
                CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&table, colSize));
                CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(table, jNode->leftTable->content[index], colSize, cudaMemcpyHostToDevice));
            } 
            else {
                table = jNode->leftTable->content[index];
            }

            resSize = res->tupleNum * attrSize;
        }else{
            index = jNode->rightOutputIndex[pos];
            dataPos = jNode->rightTable->dataPos[index];
            format = jNode->rightTable->dataFormat[index];

            table = jNode->rightTable->content[index];
            attrSize = jNode->rightTable->attrSize[index];
            attrType = jNode->rightTable->attrType[index];
            colSize = jNode->rightTable->attrTotalSize[index];

            if(dataPos == MEM) {
                CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&table, colSize));
                CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(table, jNode->rightTable->content[index], colSize, cudaMemcpyHostToDevice));
            } 
            else {
                table = jNode->rightTable->content[index];
            }

            resSize = attrSize * res->tupleNum;
            leftRight = 1;
        }

        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpu_result,resSize));

        if(leftRight == 0){

            if(format == UNCOMPRESSED){
                /* left table make k copies by tuple */
                // int numBlocks = 1;
                // int threadsPerBlock = jNode->leftTable->tupleNum;
                // copy_left_table<<<numBlocks, threadsPerBlock>>>(table, attrSize, jNode->leftTable->tupleNum, k, gpu_result);
                int threads = 256;
                int blocks = (jNode->leftTable->tupleNum + threads - 1) / threads;
                copy_left_table<<<blocks, threads>>>(table, attrSize, jNode->leftTable->tupleNum, k, gpu_result);
                CUDA_SAFE_CALL_NO_SYNC(cudaDeviceSynchronize());
            }
            else{
                printf("Datatype isn't compressed!");
                exit(1);
            }

        }else{

            if(format == UNCOMPRESSED){
                /* right table copy by nns */
                CUDA_SAFE_CALL_NO_SYNC(cudaDeviceSynchronize());
                // int threadsPerBlock = res->tupleNum;
                // copy_right_table<<<1, threadsPerBlock>>>(table, attrSize, res->tupleNum, gpu_nns, gpu_result);
                int threads = 256;
                int blocks = (res->tupleNum + threads - 1) / threads;
                copy_right_table<<<blocks, threads>>>(table, attrSize, res->tupleNum, gpu_nns, gpu_result);
                CUDA_SAFE_CALL_NO_SYNC(cudaDeviceSynchronize());

            }else{
                printf("Datatype isn't compressed!");
                exit(1);
            }

        }
        
        CUDA_SAFE_CALL_NO_SYNC(cudaDeviceSynchronize());

        res->dataFormat[i] = UNCOMPRESSED;
        if(res->dataPos[i] == MEM){
            res->content[i] = (char *) malloc(resSize);
            CHECK_POINTER(res->content[i]);
            memset(res->content[i],0,resSize);
            CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(res->content[i],gpu_result,resSize,cudaMemcpyDeviceToHost));
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpu_result));

        }else if(res->dataPos[i] == GPU){
            res->content[i] = gpu_result;
        }
    }
    CUDA_SAFE_CALL_NO_SYNC(cudaDeviceSynchronize());
    clock_gettime(CLOCK_REALTIME,&end);
    double total = (end.tv_sec -  start.tv_sec)* BILLION + end.tv_nsec - start.tv_nsec;
    printf("copy data time: %f\n", total/(1000*1000));

    //Stop total timer
    clock_gettime(CLOCK_REALTIME, &endS0);
    pp->knnJoin_totalTime += (endS0.tv_sec - startS0.tv_sec)* BILLION + endS0.tv_nsec - startS0.tv_nsec;
    printf("[Info] knnJoin_totalTime = %lf\n", pp->knnJoin_totalTime/(1000*1000));
    
    //Increase count call
    pp->join_callTimes++;

    printf("[knnJoin] res->tupleNum = %ld\n", res->tupleNum);
    // float disArray[1024*1024];
    // char intArray[2048];
    // printf("[knnJoin] the type of result[2] :%d\n", res->attrType[3]);
    // cudaMemcpy(disArray, res->content[3], res->attrSize[3] * res->tupleNum, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 10; i++){
    //     printf("test feature[%d] = ", i);
    //     for(int j = 0; j < 19; j++){
    //         printf("%f\t", disArray[i*19 + j]);
    //     }
    //     printf("\n");
    // }
    return res;

}
