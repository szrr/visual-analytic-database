/* This file is generated by code_gen.py */
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <string.h>
#include <unistd.h>
#include <malloc.h>
#include <time.h>
#include <getopt.h>
#include <linux/limits.h>
#include "../include/common.h"
#include "../include/hashJoin.h"
#include "../include/schema.h"
#include "../include/Mempool.h"
#include <map>
#include "../include/cpuCudaLib.h"
#include "../include/gpuCudaLib.h"
#include <faiss/gpu/GpuAutoTune.h>
#include <faiss/gpu/GpuCloner.h>
#include <faiss/gpu/GpuIndexIVFPQ.h>
#include <faiss/gpu/StandardGpuResources.h>
#include <faiss/index_io.h>
#include <faiss/IndexFlat.h>
#include <faiss/IndexIVFPQ.h>
extern struct tableNode* tableScan(struct scanNode *,struct statistic *, Mempool *, Mempool *, Mempool *, int *, int *, int *, faiss::Index*);
extern void createIndex (struct tableNode *, int, int, struct statistic *);
extern struct tableNode* hashJoin(struct joinNode *, struct statistic *, Mempool *, Mempool *, Mempool *, int *);
extern struct tableNode* knnJoin(struct joinNode *, struct statistic *, Mempool *, Mempool *, Mempool *, int *, faiss::Index*);
extern struct tableNode* cartesianProductJoin(struct joinNode *, struct statistic *, Mempool *, Mempool *, Mempool *, int *);
extern int *buildColumnHash(struct tableNode *, int, struct statistic *);
extern struct tableNode* groupBy(struct groupByNode *,struct statistic *, Mempool *, Mempool *);
extern struct tableNode* orderBy(struct orderByNode *, struct statistic *);
extern char* materializeCol(struct materializeNode * mn, struct statistic *);
int searchFrameNum = 0;

#define CHECK_POINTER(p) do {\
    if(p == NULL){   \
        perror("Failed to allocate host memory");    \
        exit(-1);      \
    }} while(0)

int main(int argc, char ** argv){

    /* For initializing CUDA device */
    int * cudaTmp;
    cudaMalloc((void**)&cudaTmp,sizeof(int));
    cudaFree(cudaTmp);

    int table;
    int long_index;
    char path[PATH_MAX];
    int setPath = 0;
    struct option long_options[] = {
        {"datadir",required_argument,0,'0'}
    };

    while((table=getopt_long(argc,argv,"",long_options,&long_index))!=-1){
        switch(table){
            case '0':
                setPath = 1;
                strcpy(path,optarg);
                break;
        }
    }

    if(setPath == 1)
        chdir(path);

    struct timespec start, end;
    struct timespec diskStart, diskEnd;
    double diskTotal = 0;
    clock_gettime(CLOCK_REALTIME,&start);
    struct statistic pp;
    pp.total = pp.kernel = pp.pcie = 0;

    pp.outerTableSize = pp.resultTableSize = pp.subCacheHits = 0;

    pp.annsTotalTime = 0;
    pp.loadIndex = 0;
    pp.indexCPU2GPU = 0;
    pp.trainIndex = 0;
    pp.saveIndex = 0;
    pp.indexAddData = 0;
    pp.indexSearch = 0;
    pp.buildIndexTotal = 0;
    pp.tableScanTotal = 0;
    pp.tableScanCount = 0;
    pp.whereMemCopy_s1 = 0;
    pp.dataMemCopy_s2 = 0;
    pp.scanTotal_s3 = 0;
    pp.preScanTotal_s4 = 0;
    pp.preScanCount_s4 = 0;
    pp.preScanResultMemCopy_s5 = 0;
    pp.dataMemCopyOther_s6 = 0;
    pp.materializeResult_s7 = 0;
    pp.finalResultMemCopy_s8 = 0;
    pp.create_tableNode_S01 = 0;
    pp.mallocRes_S02 = 0;
    pp.deallocateBuffs_S03 = 0;
    pp.getIndexPos_idxS1 = 0;
    pp.getRange_idxS2 = 0;
    pp.convertMemToElement_idxS3 = 0;
    pp.getMapping_idxS4 = 0;
    pp.setBitmapZeros_idxS5 = 0;
    pp.buildBitmap_idxS6 = 0;
    pp.countScanKernel_countS1 = 0;
    pp.scanImpl_countS2 = 0;
    pp.preallocBlockSums_scanImpl_S1 = 0;
    pp.prescanArray_scanImpl_S2 = 0;
    pp.deallocBlockSums_scanImpl_S3 = 0;
    pp.setVar_prescan_S1 = 0;
    pp.preScanKernel_prescan_S2 = 0;
    pp.uniformAddKernel_prescan_S3 = 0;

    pp.knnJoin_totalTime = 0;
    pp.knn_ANNs_time = 0;
    pp.cartesianJoin_totalTime = 0;
    pp.join_totalTime = 0;
    pp.join_callTimes = 0;
    pp.join_leftTableSize = 0;
    pp.join_rightTableSize = 0;
    pp.joinProf_step1_allocateMem = 0;
    pp.joinProf_step2_buildHash = 0;
    pp.joinProf_step21_allocateMem = 0;
    pp.joinProf_step22_Count_hash_num = 0;
    pp.joinProf_step23_scanImpl = 0;
    pp.joinProf_step24_buildhash_kernel_memcopy = 0;
    pp.joinProf_step3_join = 0;
    pp.joinProf_step31_allocateMem = 0;
    pp.joinProf_step32_exclusiveScan = 0;
    pp.joinProf_step33_prob = 0;
    pp.joinProf_step4_materialize_res = 0;
    pp.joinProf_step41_materialize_res_left = 0;
    pp.joinProf_step42_materialize_res_right = 0;

    pp.groupby_totalTime = 0;
    pp.groupby_callTimes = 0;
    pp.groupby_step1_allocMem = 0;
    pp.groupby_step2_copyToDevice = 0;
    pp.groupby_step3_buildGroupByKey = 0;
    pp.groupby_step4_groupCount = 0;
    pp.groupby_step5_AllocRes = 0;
    pp.groupby_step6_copyDataCols = 0;
    pp.groupby_step7_computeAgg = 0;
    pp.groupby_step8_deallocate = 0;

    Mempool host_mempool(MEM);
    Mempool gpu_inner_mp(GPU);
    Mempool gpu_inter_mp(GPU);

    // Load columns from the table DATASET_VIDEO
    struct tableNode *dataset_videoTable;
    dataset_videoTable = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
    {
        struct tableNode *_dataset_video_table;
        int outFd;
        long outSize;
        char *outTable;
        long offset, tupleOffset;
        int blockTotal;
        struct columnHeader header;

        // Retrieve the block number from DATASET_VIDEO0
        outFd = open("DATASET_VIDEO0", O_RDONLY);
        read(outFd, &header, sizeof(struct columnHeader));
        blockTotal = header.blockTotal;
        close(outFd);
        offset = 0;
        tupleOffset = 0;
        for(int i = 0; i < blockTotal; i++){

            // Table initialization
            _dataset_video_table = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
            _dataset_video_table->totalAttr = 2;
            _dataset_video_table->attrType = (int *)host_mempool.alloc(sizeof(int) * 2);
            _dataset_video_table->attrSize = (int *)host_mempool.alloc(sizeof(int) * 2);
            _dataset_video_table->attrName = (char **)host_mempool.alloc(sizeof(char *) * 2);

            _dataset_video_table->attrIndex = (int *)host_mempool.alloc(sizeof(int) * 2);
            _dataset_video_table->attrTotalSize = (int *)host_mempool.alloc(sizeof(int) * 2);
            _dataset_video_table->dataPos = (int *)host_mempool.alloc(sizeof(int) * 2);
            _dataset_video_table->dataFormat = (int *)host_mempool.alloc(sizeof(int) * 2);
            _dataset_video_table->content = (char **)host_mempool.alloc(sizeof(char *) * 2);

            // Load column 0, type: TEXT
            _dataset_video_table->attrSize[0] = 23;
            _dataset_video_table->attrIndex[0] = 0;
            _dataset_video_table->attrType[0] = STRING;
            _dataset_video_table->attrName[0] = "DATASET_VIDEO0";
            _dataset_video_table->dataPos[0] = MEM;
            outFd = open("DATASET_VIDEO0", O_RDONLY);
            offset = i * sizeof(struct columnHeader) + tupleOffset * 23;
            lseek(outFd, offset, SEEK_SET);
            read(outFd, &header, sizeof(struct columnHeader));
            offset += sizeof(struct columnHeader);
            _dataset_video_table->dataFormat[0] = header.format;
            outSize = header.tupleNum * 23;
            _dataset_video_table->attrTotalSize[0] = outSize;

            clock_gettime(CLOCK_REALTIME,&diskStart);
            outTable =(char *)mmap(0, outSize, PROT_READ, MAP_SHARED, outFd, offset);
            _dataset_video_table->content[0] = (char *)memalign(256, outSize);
            memcpy(_dataset_video_table->content[0], outTable, outSize);
            munmap(outTable, outSize);
            clock_gettime(CLOCK_REALTIME, &diskEnd);
            diskTotal += (diskEnd.tv_sec -  diskStart.tv_sec)* BILLION + diskEnd.tv_nsec - diskStart.tv_nsec;
            close(outFd);

            // Load column 2, type: VECTOR
            _dataset_video_table->attrSize[1] = 512;
            _dataset_video_table->attrIndex[1] = 2;
            _dataset_video_table->attrType[1] = VECTOR;
            _dataset_video_table->attrName[1] = "DATASET_VIDEO2";
            _dataset_video_table->dataPos[1] = MEM;
            outFd = open("DATASET_VIDEO2", O_RDONLY);
            offset = i * sizeof(struct columnHeader) + tupleOffset * 512;
            lseek(outFd, offset, SEEK_SET);
            read(outFd, &header, sizeof(struct columnHeader));
            offset += sizeof(struct columnHeader);
            _dataset_video_table->dataFormat[1] = header.format;
            outSize = header.tupleNum * 512;
            _dataset_video_table->attrTotalSize[1] = outSize;

            clock_gettime(CLOCK_REALTIME,&diskStart);
            outTable =(char *)mmap(0, outSize, PROT_READ, MAP_SHARED, outFd, offset);
            _dataset_video_table->content[1] = (char *)memalign(256, outSize);
            memcpy(_dataset_video_table->content[1], outTable, outSize);
            munmap(outTable, outSize);
            clock_gettime(CLOCK_REALTIME, &diskEnd);
            diskTotal += (diskEnd.tv_sec -  diskStart.tv_sec)* BILLION + diskEnd.tv_nsec - diskStart.tv_nsec;
            close(outFd);

            _dataset_video_table->tupleSize = 0 + 23 + 512;
            _dataset_video_table->tupleNum = header.tupleNum;

            if(blockTotal != 1){
                mergeIntoTable(dataset_videoTable,_dataset_video_table, &pp);
                clock_gettime(CLOCK_REALTIME, &diskStart);
                freeTable(_dataset_video_table);
                clock_gettime(CLOCK_REALTIME, &diskEnd);
                diskTotal += (diskEnd.tv_sec -  diskStart.tv_sec)* BILLION + diskEnd.tv_nsec - diskStart.tv_nsec;
            }else{
                dataset_videoTable = _dataset_video_table;
            }
            tupleOffset += header.tupleNum;
        }
        dataset_videoTable->colIdxNum = 0;
        _dataset_video_table->keepInGpuIdx = 1;
    }

    // Load columns from the table SEARCH_VIDEO
    struct tableNode *search_videoTable;
    search_videoTable = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
    {
        struct tableNode *_search_video_table;
        int outFd;
        long outSize;
        char *outTable;
        long offset, tupleOffset;
        int blockTotal;
        struct columnHeader header;

        // Retrieve the block number from SEARCH_VIDEO1
        outFd = open("SEARCH_VIDEO1", O_RDONLY);
        read(outFd, &header, sizeof(struct columnHeader));
        blockTotal = header.blockTotal;
        close(outFd);
        offset = 0;
        tupleOffset = 0;
        for(int i = 0; i < blockTotal; i++){

            // Table initialization
            _search_video_table = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
            _search_video_table->totalAttr = 1;
            _search_video_table->attrType = (int *)host_mempool.alloc(sizeof(int) * 1);
            _search_video_table->attrSize = (int *)host_mempool.alloc(sizeof(int) * 1);
            _search_video_table->attrName = (char **)host_mempool.alloc(sizeof(char *) * 1);

            _search_video_table->attrIndex = (int *)host_mempool.alloc(sizeof(int) * 1);
            _search_video_table->attrTotalSize = (int *)host_mempool.alloc(sizeof(int) * 1);
            _search_video_table->dataPos = (int *)host_mempool.alloc(sizeof(int) * 1);
            _search_video_table->dataFormat = (int *)host_mempool.alloc(sizeof(int) * 1);
            _search_video_table->content = (char **)host_mempool.alloc(sizeof(char *) * 1);

            // Load column 1, type: VECTOR
            _search_video_table->attrSize[0] = 512;
            _search_video_table->attrIndex[0] = 1;
            _search_video_table->attrType[0] = VECTOR;
            _search_video_table->attrName[0] = "SEARCH_VIDEO1";
            _search_video_table->dataPos[0] = MEM;
            outFd = open("SEARCH_VIDEO1", O_RDONLY);
            offset = i * sizeof(struct columnHeader) + tupleOffset * 512;
            lseek(outFd, offset, SEEK_SET);
            read(outFd, &header, sizeof(struct columnHeader));
            offset += sizeof(struct columnHeader);
            _search_video_table->dataFormat[0] = header.format;
            outSize = header.tupleNum * 512;
            _search_video_table->attrTotalSize[0] = outSize;

            clock_gettime(CLOCK_REALTIME,&diskStart);
            outTable =(char *)mmap(0, outSize, PROT_READ, MAP_SHARED, outFd, offset);
            _search_video_table->content[0] = (char *)memalign(256, outSize);
            memcpy(_search_video_table->content[0], outTable, outSize);
            munmap(outTable, outSize);
            clock_gettime(CLOCK_REALTIME, &diskEnd);
            diskTotal += (diskEnd.tv_sec -  diskStart.tv_sec)* BILLION + diskEnd.tv_nsec - diskStart.tv_nsec;
            close(outFd);

            _search_video_table->tupleSize = 0 + 512;
            _search_video_table->tupleNum = header.tupleNum;

            if(blockTotal != 1){
                mergeIntoTable(search_videoTable,_search_video_table, &pp);
                clock_gettime(CLOCK_REALTIME, &diskStart);
                freeTable(_search_video_table);
                clock_gettime(CLOCK_REALTIME, &diskEnd);
                diskTotal += (diskEnd.tv_sec -  diskStart.tv_sec)* BILLION + diskEnd.tv_nsec - diskStart.tv_nsec;
            }else{
                search_videoTable = _search_video_table;
            }
            tupleOffset += header.tupleNum;
        }
        search_videoTable->colIdxNum = 0;
        _search_video_table->keepInGpuIdx = 1;
    }



    struct tableNode *result;
    char * subqRes0;

    // Process the TableNode for SEARCH_VIDEO
    struct tableNode *se0;
    se0 = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
    {
        struct tableNode *search_videoTablePartial;
        search_videoTablePartial = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
        search_videoTablePartial->totalAttr = 1;
        search_videoTablePartial->attrType = (int *)host_mempool.alloc(sizeof(int) * 1);
        search_videoTablePartial->attrSize = (int *)host_mempool.alloc(sizeof(int) * 1);
        search_videoTablePartial->attrName = (char **)host_mempool.alloc(sizeof(char *) * 1);

        search_videoTablePartial->attrIndex = (int *)host_mempool.alloc(sizeof(int) * 1);
        search_videoTablePartial->attrTotalSize = (int *)host_mempool.alloc(sizeof(int) * 1);
        search_videoTablePartial->dataPos = (int *)host_mempool.alloc(sizeof(int) * 1);
        search_videoTablePartial->dataFormat = (int *)host_mempool.alloc(sizeof(int) * 1);
        search_videoTablePartial->content = (char **)host_mempool.alloc(sizeof(char *) * 1);
        int tuple_size = 0;
        search_videoTablePartial->attrSize[0] = search_videoTable->attrSize[0];
        search_videoTablePartial->attrIndex[0] = search_videoTable->attrIndex[0];
        search_videoTablePartial->attrType[0] = search_videoTable->attrType[0];
        search_videoTablePartial->attrName[0] = "search_videoTablePartial0";
        search_videoTablePartial->dataPos[0] = search_videoTable->dataPos[0];
        search_videoTablePartial->dataFormat[0] = search_videoTable->dataFormat[0];
        search_videoTablePartial->attrTotalSize[0] = search_videoTable->attrTotalSize[0];
        search_videoTablePartial->content[0] = search_videoTable->content[0];
        tuple_size += search_videoTablePartial->attrSize[0];

        search_videoTablePartial->tupleSize = tuple_size;
        search_videoTablePartial->tupleNum = search_videoTable->tupleNum;

        search_videoTablePartial->colIdxNum = 0;
        search_videoTablePartial->keepInGpuIdx = 1;
        // Load columns from the table SEARCH_VIDEO
        struct tableNode *search_videoTable;
        search_videoTable = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
        {
            struct tableNode *_search_video_table;
            int outFd;
            long outSize;
            char *outTable;
            long offset, tupleOffset;
            int blockTotal;
            struct columnHeader header;

            // Retrieve the block number from SEARCH_VIDEO1
            outFd = open("SEARCH_VIDEO1", O_RDONLY);
            read(outFd, &header, sizeof(struct columnHeader));
            blockTotal = header.blockTotal;
            close(outFd);
            offset = 0;
            tupleOffset = 0;
            for(int i = 0; i < blockTotal; i++){

                // Table initialization
                _search_video_table = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
                _search_video_table->totalAttr = 1;
                _search_video_table->attrType = (int *)host_mempool.alloc(sizeof(int) * 1);
                _search_video_table->attrSize = (int *)host_mempool.alloc(sizeof(int) * 1);
                _search_video_table->attrName = (char **)host_mempool.alloc(sizeof(char *) * 1);

                _search_video_table->attrIndex = (int *)host_mempool.alloc(sizeof(int) * 1);
                _search_video_table->attrTotalSize = (int *)host_mempool.alloc(sizeof(int) * 1);
                _search_video_table->dataPos = (int *)host_mempool.alloc(sizeof(int) * 1);
                _search_video_table->dataFormat = (int *)host_mempool.alloc(sizeof(int) * 1);
                _search_video_table->content = (char **)host_mempool.alloc(sizeof(char *) * 1);

                // Load column 1, type: VECTOR
                _search_video_table->attrSize[0] = 512;
                _search_video_table->attrIndex[0] = 1;
                _search_video_table->attrType[0] = VECTOR;
                _search_video_table->attrName[0] = "SEARCH_VIDEO1";
                _search_video_table->dataPos[0] = MEM;
                outFd = open("SEARCH_VIDEO1", O_RDONLY);
                offset = i * sizeof(struct columnHeader) + tupleOffset * 512;
                lseek(outFd, offset, SEEK_SET);
                read(outFd, &header, sizeof(struct columnHeader));
                offset += sizeof(struct columnHeader);
                _search_video_table->dataFormat[0] = header.format;
                outSize = header.tupleNum * 512;
                _search_video_table->attrTotalSize[0] = outSize;

                clock_gettime(CLOCK_REALTIME,&diskStart);
                outTable =(char *)mmap(0, outSize, PROT_READ, MAP_SHARED, outFd, offset);
                _search_video_table->content[0] = (char *)memalign(256, outSize);
                memcpy(_search_video_table->content[0], outTable, outSize);
                munmap(outTable, outSize);
                clock_gettime(CLOCK_REALTIME, &diskEnd);
                diskTotal += (diskEnd.tv_sec -  diskStart.tv_sec)* BILLION + diskEnd.tv_nsec - diskStart.tv_nsec;
                close(outFd);

                _search_video_table->tupleSize = 0 + 512;
                _search_video_table->tupleNum = header.tupleNum;

                if(blockTotal != 1){
                    mergeIntoTable(search_videoTable,_search_video_table, &pp);
                    clock_gettime(CLOCK_REALTIME, &diskStart);
                    freeTable(_search_video_table);
                    clock_gettime(CLOCK_REALTIME, &diskEnd);
                    diskTotal += (diskEnd.tv_sec -  diskStart.tv_sec)* BILLION + diskEnd.tv_nsec - diskStart.tv_nsec;
                }else{
                    search_videoTable = _search_video_table;
                }
                tupleOffset += header.tupleNum;
            }
            search_videoTable->colIdxNum = 0;
            _search_video_table->keepInGpuIdx = 1;
        }

        se0 = search_videoTable;
        se0->colIdxNum = 0;
    }

    // Process the TableNode for DATASET_VIDEO
    struct tableNode *da0;
    da0 = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
    {
        struct tableNode *dataset_videoTablePartial;
        dataset_videoTablePartial = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
        dataset_videoTablePartial->totalAttr = 2;
        dataset_videoTablePartial->attrType = (int *)host_mempool.alloc(sizeof(int) * 2);
        dataset_videoTablePartial->attrSize = (int *)host_mempool.alloc(sizeof(int) * 2);
        dataset_videoTablePartial->attrName = (char **)host_mempool.alloc(sizeof(char *) * 2);

        dataset_videoTablePartial->attrIndex = (int *)host_mempool.alloc(sizeof(int) * 2);
        dataset_videoTablePartial->attrTotalSize = (int *)host_mempool.alloc(sizeof(int) * 2);
        dataset_videoTablePartial->dataPos = (int *)host_mempool.alloc(sizeof(int) * 2);
        dataset_videoTablePartial->dataFormat = (int *)host_mempool.alloc(sizeof(int) * 2);
        dataset_videoTablePartial->content = (char **)host_mempool.alloc(sizeof(char *) * 2);
        int tuple_size = 0;
        dataset_videoTablePartial->attrSize[0] = dataset_videoTable->attrSize[0];
        dataset_videoTablePartial->attrIndex[0] = dataset_videoTable->attrIndex[0];
        dataset_videoTablePartial->attrType[0] = dataset_videoTable->attrType[0];
        dataset_videoTablePartial->attrName[0] = "dataset_videoTablePartial0";
        dataset_videoTablePartial->dataPos[0] = dataset_videoTable->dataPos[0];
        dataset_videoTablePartial->dataFormat[0] = dataset_videoTable->dataFormat[0];
        dataset_videoTablePartial->attrTotalSize[0] = dataset_videoTable->attrTotalSize[0];
        dataset_videoTablePartial->content[0] = dataset_videoTable->content[0];
        tuple_size += dataset_videoTablePartial->attrSize[0];

        dataset_videoTablePartial->attrSize[1] = dataset_videoTable->attrSize[1];
        dataset_videoTablePartial->attrIndex[1] = dataset_videoTable->attrIndex[1];
        dataset_videoTablePartial->attrType[1] = dataset_videoTable->attrType[1];
        dataset_videoTablePartial->attrName[1] = "dataset_videoTablePartial1";
        dataset_videoTablePartial->dataPos[1] = dataset_videoTable->dataPos[1];
        dataset_videoTablePartial->dataFormat[1] = dataset_videoTable->dataFormat[1];
        dataset_videoTablePartial->attrTotalSize[1] = dataset_videoTable->attrTotalSize[1];
        dataset_videoTablePartial->content[1] = dataset_videoTable->content[1];
        tuple_size += dataset_videoTablePartial->attrSize[1];

        dataset_videoTablePartial->tupleSize = tuple_size;
        dataset_videoTablePartial->tupleNum = dataset_videoTable->tupleNum;

        dataset_videoTablePartial->colIdxNum = 0;
        dataset_videoTablePartial->keepInGpuIdx = 1;
        // Load columns from the table DATASET_VIDEO
        struct tableNode *dataset_videoTable;
        dataset_videoTable = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
        {
            struct tableNode *_dataset_video_table;
            int outFd;
            long outSize;
            char *outTable;
            long offset, tupleOffset;
            int blockTotal;
            struct columnHeader header;

            // Retrieve the block number from DATASET_VIDEO0
            outFd = open("DATASET_VIDEO0", O_RDONLY);
            read(outFd, &header, sizeof(struct columnHeader));
            blockTotal = header.blockTotal;
            close(outFd);
            offset = 0;
            tupleOffset = 0;
            for(int i = 0; i < blockTotal; i++){

                // Table initialization
                _dataset_video_table = (struct tableNode *)host_mempool.alloc(sizeof(struct tableNode));
                _dataset_video_table->totalAttr = 2;
                _dataset_video_table->attrType = (int *)host_mempool.alloc(sizeof(int) * 2);
                _dataset_video_table->attrSize = (int *)host_mempool.alloc(sizeof(int) * 2);
                _dataset_video_table->attrName = (char **)host_mempool.alloc(sizeof(char *) * 2);

                _dataset_video_table->attrIndex = (int *)host_mempool.alloc(sizeof(int) * 2);
                _dataset_video_table->attrTotalSize = (int *)host_mempool.alloc(sizeof(int) * 2);
                _dataset_video_table->dataPos = (int *)host_mempool.alloc(sizeof(int) * 2);
                _dataset_video_table->dataFormat = (int *)host_mempool.alloc(sizeof(int) * 2);
                _dataset_video_table->content = (char **)host_mempool.alloc(sizeof(char *) * 2);

                // Load column 0, type: TEXT
                _dataset_video_table->attrSize[0] = 23;
                _dataset_video_table->attrIndex[0] = 0;
                _dataset_video_table->attrType[0] = STRING;
                _dataset_video_table->attrName[0] = "DATASET_VIDEO0";
                _dataset_video_table->dataPos[0] = MEM;
                outFd = open("DATASET_VIDEO0", O_RDONLY);
                offset = i * sizeof(struct columnHeader) + tupleOffset * 23;
                lseek(outFd, offset, SEEK_SET);
                read(outFd, &header, sizeof(struct columnHeader));
                offset += sizeof(struct columnHeader);
                _dataset_video_table->dataFormat[0] = header.format;
                outSize = header.tupleNum * 23;
                _dataset_video_table->attrTotalSize[0] = outSize;

                clock_gettime(CLOCK_REALTIME,&diskStart);
                outTable =(char *)mmap(0, outSize, PROT_READ, MAP_SHARED, outFd, offset);
                _dataset_video_table->content[0] = (char *)memalign(256, outSize);
                memcpy(_dataset_video_table->content[0], outTable, outSize);
                munmap(outTable, outSize);
                clock_gettime(CLOCK_REALTIME, &diskEnd);
                diskTotal += (diskEnd.tv_sec -  diskStart.tv_sec)* BILLION + diskEnd.tv_nsec - diskStart.tv_nsec;
                close(outFd);

                // Load column 2, type: VECTOR
                _dataset_video_table->attrSize[1] = 512;
                _dataset_video_table->attrIndex[1] = 2;
                _dataset_video_table->attrType[1] = VECTOR;
                _dataset_video_table->attrName[1] = "DATASET_VIDEO2";
                _dataset_video_table->dataPos[1] = MEM;
                outFd = open("DATASET_VIDEO2", O_RDONLY);
                offset = i * sizeof(struct columnHeader) + tupleOffset * 512;
                lseek(outFd, offset, SEEK_SET);
                read(outFd, &header, sizeof(struct columnHeader));
                offset += sizeof(struct columnHeader);
                _dataset_video_table->dataFormat[1] = header.format;
                outSize = header.tupleNum * 512;
                _dataset_video_table->attrTotalSize[1] = outSize;

                clock_gettime(CLOCK_REALTIME,&diskStart);
                outTable =(char *)mmap(0, outSize, PROT_READ, MAP_SHARED, outFd, offset);
                _dataset_video_table->content[1] = (char *)memalign(256, outSize);
                memcpy(_dataset_video_table->content[1], outTable, outSize);
                munmap(outTable, outSize);
                clock_gettime(CLOCK_REALTIME, &diskEnd);
                diskTotal += (diskEnd.tv_sec -  diskStart.tv_sec)* BILLION + diskEnd.tv_nsec - diskStart.tv_nsec;
                close(outFd);

                _dataset_video_table->tupleSize = 0 + 23 + 512;
                _dataset_video_table->tupleNum = header.tupleNum;

                if(blockTotal != 1){
                    mergeIntoTable(dataset_videoTable,_dataset_video_table, &pp);
                    clock_gettime(CLOCK_REALTIME, &diskStart);
                    freeTable(_dataset_video_table);
                    clock_gettime(CLOCK_REALTIME, &diskEnd);
                    diskTotal += (diskEnd.tv_sec -  diskStart.tv_sec)* BILLION + diskEnd.tv_nsec - diskStart.tv_nsec;
                }else{
                    dataset_videoTable = _dataset_video_table;
                }
                tupleOffset += header.tupleNum;
            }
            dataset_videoTable->colIdxNum = 0;
            _dataset_video_table->keepInGpuIdx = 1;
        }

        da0 = dataset_videoTable;
        da0->colIdxNum = 0;
    }

    // Join two tables: se0, da0
    struct tableNode *se0_da0;

    {

        struct joinNode jNode;
        jNode.leftTable = se0;
        jNode.rightTable = da0;
        jNode.totalAttr = 3;
        jNode.keepInGpu = (int *)host_mempool.alloc(sizeof(int) * 3);
        for(int k=0; k<3; k++)
            jNode.keepInGpu[k] = 1;
        jNode.leftOutputAttrNum = 1;
        jNode.rightOutputAttrNum = 2;
        jNode.leftOutputAttrType = (int *)host_mempool.alloc(sizeof(int)*1);
        jNode.leftOutputIndex = (int *)host_mempool.alloc(sizeof(int)*1);
        jNode.leftPos = (int *)host_mempool.alloc(sizeof(int)*1);
        jNode.tupleSize = 0;
        jNode.leftOutputIndex[0] = 0;
        jNode.leftOutputAttrType[0] = VECTOR;
        jNode.leftPos[0] = 1;
        jNode.tupleSize += se0->attrSize[0];
        jNode.rightOutputAttrType = (int *)host_mempool.alloc(sizeof(int)*2);
        jNode.rightOutputIndex = (int *)host_mempool.alloc(sizeof(int)*2);
        jNode.rightPos = (int *)host_mempool.alloc(sizeof(int)*2);
        jNode.rightOutputIndex[0] = 0;
        jNode.rightOutputAttrType[0] = STRING;
        jNode.rightPos[0] = 0;
        jNode.tupleSize += da0->attrSize[0];
        jNode.rightOutputIndex[1] = 1;
        jNode.rightOutputAttrType[1] = VECTOR;
        jNode.rightPos[1] = 2;
        jNode.tupleSize += da0->attrSize[1];
        jNode.leftKeyIndex = -1;
        jNode.rightKeyIndex = -1;
        struct tableNode *joinRes;
        int dev_memsize = hashJoinGPUMemSize(&jNode, false);
        if(gpu_inner_mp.freesize() < dev_memsize)
            gpu_inner_mp.resize(gpu_inner_mp.usedsize() + dev_memsize);
        char *origin_pos_join = gpu_inner_mp.freepos();
        searchFrameNum = (jNode.leftTable)->tupleNum;

        struct timespec kj_s, kj_e;
        clock_gettime(CLOCK_REALTIME, &kj_s);
        joinRes = cartesianProductJoin(&jNode, &pp, &host_mempool, &gpu_inner_mp, NULL, NULL);
        clock_gettime(CLOCK_REALTIME, &kj_e);
        double knnTime = (kj_e.tv_sec -  kj_s.tv_sec)* BILLION + kj_e.tv_nsec - kj_s.tv_nsec;
        printf("knn Time: %lf\n", knnTime/(1000*1000));
        gpu_inner_mp.freeto(origin_pos_join);

        struct scanNode joinRel;
        joinRel.tn = joinRes;
        joinRel.hasWhere = 0;
        joinRel.whereAttrNum = 0;
        joinRel.whereIndex = (int *)host_mempool.alloc(sizeof(int) * 0);
        joinRel.outputIndex = (int *)host_mempool.alloc(sizeof(int) * 3);
        joinRel.outputNum = 3;
        joinRel.outputIndex[0] = 0;
        joinRel.outputIndex[1] = 1;
        joinRel.outputIndex[2] = 2;
        joinRel.keepInGpu = 1;
        joinRel.project = (struct projectFunction *)host_mempool.alloc(sizeof(struct projectFunction));
        joinRel.projectNum =1;
        (joinRel.project)->projectNum =1;
        (joinRel.project)->exp = (struct projectExp*)host_mempool.alloc(sizeof(struct projectExp) *1);
        (joinRel.project)->exp[0].index    = 1;
        (joinRel.project)->exp[0].secondIndex    = 2;
        (joinRel.project)->exp[0].func     = DISTANCE;
        (joinRel.project)->exp[0].funcType = 2;
        joinRel.projectPart = 1;
        joinRel.projectIndex = (int *)host_mempool.alloc(sizeof(int) * 2);
        joinRel.projectNum = 1;
        joinRel.projectIndex[0] = 0;
        joinRel.projectIndex[1] = 100;
        dev_memsize = tableScanGPUMemSize(&joinRel);
        if(gpu_inner_mp.freesize() < dev_memsize)
            gpu_inner_mp.resize(gpu_inner_mp.usedsize() + dev_memsize);
        char *origin_pos = gpu_inner_mp.freepos();
        joinRes = tableScan(&joinRel, &pp, &host_mempool, &gpu_inner_mp, NULL, NULL, NULL, NULL, NULL);
        gpu_inner_mp.freeto(origin_pos);

        freeScan(&joinRel, false);

        se0_da0 = joinRes;
    }

    result = se0_da0;
    struct materializeNode mn;
    mn.table = result;
    char *final = materializeCol(&mn, &pp);


    clock_gettime(CLOCK_REALTIME, &end);
    double timeE = (end.tv_sec -  start.tv_sec)* BILLION + end.tv_nsec - start.tv_nsec;
    // printf("<--Disk Load Time-->           : %lf\n", diskTotal/(1000*1000));
    // printf("\n");
    // printf("<--Build index time-->         : %lf\n", pp.buildIndexTotal/(1000*1000));

    // printf("\n");
    // printf("<--ANNs total time-->          : %lf\n", pp.annsTotalTime/(1000*1000));

    // printf("Load anns index                : %lf\n", pp.loadIndex/(1000*1000));

    // printf("Load index from CPU to GPU     : %lf\n", pp.indexCPU2GPU/(1000*1000));

    // printf("Train anns index               : %lf\n", pp.trainIndex/(1000*1000));

    // printf("Save anns index                : %lf\n", pp.saveIndex/(1000*1000));

    // printf("Add data to anns index         : %lf\n", pp.indexAddData/(1000*1000));

    // printf("Search anns index              : %lf\n", pp.indexSearch/(1000*1000));

    // printf("<---SUB()--->\n");
    // printf("Outer table size           : %d\n", pp.outerTableSize);

    // printf("Sub Cache hits             : %d\n", pp.subCacheHits);

    // printf("Result table size          : %d\n", pp.resultTableSize);

    // printf("<----------------->");
    // printf("\n");
    // printf("<---TableScan()--->\n");
    // printf("Total time      : %lf\n", pp.tableScanTotal/(1000*1000));
    // printf("Calls           : %d\n", pp.tableScanCount);

    // printf("Step 1 - memCopy where clause                 : %lf\n", pp.whereMemCopy_s1/(1000*1000));
    // printf("Step 2 - memCopy predicate col                : %lf\n", pp.dataMemCopy_s2/(1000*1000));
    // printf("Step 3 - Scan                                 : %lf\n", pp.scanTotal_s3/(1000*1000));
    // printf("Idx Step 3.1 - Get index position             : %lf\n", pp.getIndexPos_idxS1/(1000*1000));
    // printf("Idx Step 3.2 - Get range                      : %lf\n", pp.getRange_idxS2/(1000*1000));
    // printf("Idx Step 3.3 - Convert addrs to elements      : %lf\n", pp.convertMemToElement_idxS3/(1000*1000));
    // printf("Idx Step 3.4 - Get mapping position           : %lf\n", pp.getMapping_idxS4/(1000*1000));
    // printf("Idx Step 3.5 - Set bitmap to zero             : %lf\n", pp.setBitmapZeros_idxS5/(1000*1000));
    // printf("Idx Step 3.6 - Build bitmap                   : %lf\n", pp.buildBitmap_idxS6/(1000*1000));
    // printf("Step 4 - CountRes(PreScan)                    : %lf\n", pp.preScanTotal_s4/(1000*1000));
    // printf("PreScan Step 4.1 - Count selected rows kernel : %lf\n", pp.countScanKernel_countS1/(1000*1000));
    // printf("PreScan Step 4.2 - scanImpl time              : %lf\n", pp.scanImpl_countS2/(1000*1000));
    // printf("scanImpl Step 4.2.1 - preallocBlockSums time  : %lf\n", pp.preallocBlockSums_scanImpl_S1/(1000*1000));
    // printf("scanImpl Step 4.2.2 - prescanArray time       : %lf\n", pp.prescanArray_scanImpl_S2/(1000*1000));
    // printf("scanImpl Step 4.2.3 - deallocBlockSums time   : %lf\n", pp.deallocBlockSums_scanImpl_S3/(1000*1000));
    // printf("prescan Step 4.2.3.1 - set variables time     : %lf\n", pp.setVar_prescan_S1/(1000*1000));
    // printf("prescan Step 4.2.3.2 - prescan Kernel time    : %lf\n", pp.preScanKernel_prescan_S2/(1000*1000));
    // printf("prescan Step 4.2.3.3 - uniformAdd Kernel time : %lf\n", pp.uniformAddKernel_prescan_S3/(1000*1000));
    // printf("Step 5 - memReturn countRes                   : %lf\n", pp.preScanResultMemCopy_s5/(1000*1000));
    // printf("Step 6 - Copy rest of columns                 : %lf\n", pp.dataMemCopyOther_s6/(1000*1000));
    // printf("Step 7 - Materialize result                   : %lf\n", pp.materializeResult_s7/(1000*1000));
    // printf("Step 8 - Copy final result                    : %lf\n", pp.finalResultMemCopy_s8/(1000*1000));
    // printf("Other 1 - Create tableNode                    : %lf\n", pp.create_tableNode_S01/(1000*1000));
    // printf("Other 2 - Malloc res                          : %lf\n", pp.mallocRes_S02/(1000*1000));
    // printf("Other 3 - Deallocate buffers                  : %lf\n", pp.deallocateBuffs_S03/(1000*1000));
    // printf("<----------------->");
    // printf("\n");
    // printf("<---Join--->\n");
    // printf("Calls                     : %d\n", pp.join_callTimes);

    // printf("<---knnJoin()--->\n");
    // printf("Total time                : %lf\n", pp.knnJoin_totalTime/(1000*1000));
    // printf("Total ANNs time           : %lf\n", pp.knn_ANNs_time/(1000*1000));
    // printf("<---cartesianJoin()--->\n");
    // printf("Total time                : %lf\n", pp.cartesianJoin_totalTime/(1000*1000));
    // printf("<---HashJoin()--->\n");
    // printf("Total time                : %lf\n", pp.join_totalTime/(1000*1000));
    // printf("Left table Size           : %d\n", pp.join_leftTableSize);

    // printf("Right table Size          : %d\n", pp.join_rightTableSize);

    // printf("Step 1 - Allocate memory for intermediate results : %lf\n", pp.joinProf_step1_allocateMem/(1000*1000));
    // printf("Step 2 - Build hashTable                          : %lf\n", pp.joinProf_step2_buildHash/(1000*1000));
    // printf("Step 2.1 - Allocate memory                        : %lf\n", pp.joinProf_step21_allocateMem/(1000*1000));
    // printf("Step 2.2 - Count_hash_num                         : %lf\n", pp.joinProf_step22_Count_hash_num/(1000*1000));
    // printf("Step 2.3 - scanImpl                               : %lf\n", pp.joinProf_step23_scanImpl/(1000*1000));
    // printf("Step 2.4 - build_hash_table (+ memCopy op)        : %lf\n", pp.joinProf_step24_buildhash_kernel_memcopy/(1000*1000));
    // printf("Step 3 - Join                                     : %lf\n", pp.joinProf_step3_join/(1000*1000));
    // printf("Step 3.1 - Allocate memory                        : %lf\n", pp.joinProf_step31_allocateMem/(1000*1000));
    // printf("Step 3.2 - Exclusive scan                         : %lf\n", pp.joinProf_step32_exclusiveScan/(1000*1000));
    // printf("Step 3.3 - Prob and memcpy ops                    : %lf\n", pp.joinProf_step33_prob/(1000*1000));
    // printf("Step 4 - Materialize result                       : %lf\n", pp.joinProf_step4_materialize_res/(1000*1000));
    // printf("Step 4.1 - Materialize left part (joinFact)       : %lf\n", pp.joinProf_step41_materialize_res_left/(1000*1000));
    // printf("Step 4.2 - Materialize right part (joinDim)       : %lf\n", pp.joinProf_step42_materialize_res_right/(1000*1000));
    // printf("<----------------->");
    // printf("\n");
    // printf("<---GroupBy()--->\n");
    // printf("Total time      : %lf\n", pp.groupby_totalTime/(1000*1000));
    // printf("Calls           : %d\n", pp.groupby_callTimes);

    // printf("Step 1 - Allocate memory for intermediate results : %lf\n", pp.groupby_step1_allocMem/(1000*1000));
    // printf("Step 2 - Copy data to GPU                         : %lf\n", pp.groupby_step2_copyToDevice/(1000*1000));
    // printf("Step 3 - Build Group By Key                       : %lf\n", pp.groupby_step3_buildGroupByKey/(1000*1000));
    // printf("Step 4 - Count number of groups                   : %lf\n", pp.groupby_step4_groupCount/(1000*1000));
    // printf("Step 5 - Allocate memory for result               : %lf\n", pp.groupby_step5_AllocRes/(1000*1000));
    // printf("Step 6 - Copy columns to device                   : %lf\n", pp.groupby_step6_copyDataCols/(1000*1000));
    // printf("Step 7 - Calculate aggregate values               : %lf\n", pp.groupby_step7_computeAgg/(1000*1000));
    // printf("Step 8 - De-allocate memory                       : %lf\n", pp.groupby_step8_deallocate/(1000*1000));
    // printf("<----------------->");
    // printf("\n");
    // printf("Total Time: %lf\n", timeE/(1000*1000));
}

