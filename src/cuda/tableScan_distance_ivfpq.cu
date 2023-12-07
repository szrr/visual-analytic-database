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
#include <algorithm>
#include <unordered_set>
#include "scanImpl.cu"
#include "../include/common.h"
#include "../include/gpuCudaLib.h"
#include "../include/Mempool.h"
#include "../include/utils.h"

#include <thrust/execution_policy.h>
#include <thrust/system/cuda/execution_policy.h>
#include <thrust/binary_search.h>

#include <faiss/gpu/GpuAutoTune.h>
#include <faiss/gpu/GpuCloner.h>
#include <faiss/gpu/GpuIndexIVFPQ.h>
#include <faiss/gpu/GpuIndexIVFFlat.h>
#include <faiss/gpu/StandardGpuResources.h>
#include <faiss/index_io.h>
#include <faiss/IndexFlat.h>
#include <faiss/IndexIVFPQ.h>

#define CHECK_POINTER(p)   do {                     \
    if(p == NULL){                                  \
        perror("Failed to allocate host memory");   \
        exit(-1);                                   \
    }} while(0)

/*
 * stringCmp: Compare two strings on GPU using one single GPU thread.
 * @buf1: the first input buffer
 * @buf2: the second input buffer
 * @size: the length of data to be compared
 *
 * Return
 *  1 if buf1 is larger
 *  0 if they are equal
 *  -1 if buf2 is larger
 */

__device__ static inline int stringCmp(char* buf1, char *buf2, int size){
    int i;
    int res = 0;
    for(i=0;i<size;i++){
        if(buf1[i] > buf2[i]){
            res = 1;
            break;
        }else if (buf1[i] < buf2[i]){
            res = -1;
            break;
        }
        if(buf1[i] == 0 && buf2[i] == 0)
            break;
    }
    return res;
}

/*
 * stringFind: Find a substring in a string on GPU using one single GPU thread.
 * @buf1: the string it searches in
 * @buf2: the substring
 * @len1: the length of the string in buf1
 * @len2: the length of the string in buf2
 * @pos:  the position of the string in buf1 where the search starts
 *
 * Return
 *  -1 Failed to find the substring
 *  >0 the position of the substring
 */
__device__ static inline int stringFind(const char *buf1, const char *buf2, int len1, int len2, int pos)
{
    int res = -1;
    const char *str1 = buf1 + pos;
    const char *end1 = buf1 + len1;
    const char *str2 = buf2;
    int matched = 0;

    while(str1 != end1){
        if(*str1 == *str2){
            if(matched == 0)
                res = str1 - buf1;
            matched++;
            if(matched == len2)
                break;
            str1++;
            str2++;
            continue;
        }

        if(matched)
            return -1;

        str1++;
    }
    if(matched != len2) res = -1;
    return res;
}

__device__ static inline int stringLen(const char* buf)
{
    int res = 0;
    while(*buf++ != '\0')
        res++;
    return res;
}


/*
 * testCon: evaluate one selection predicate using one GPU thread
 * @buf1: input data to be tested
 * @buf2: the test criterion, usually a number of a string.
 * @size: the size of the input data buf1
 * @type: the type of the input data buf1
 * @rel: >,<, >=, <= or ==.
 *
 * Return:
 *  0 if the input data meets the criteria
 *  1 otherwise
 */

__device__ static inline int testCon(char *buf1, char* buf2, int size, int type, int rel){
    int res = 1;
    if (type == INT){
        if(rel == EQ){
            res = ( *((int*)buf1) == *(((int*)buf2)) );
        }else if (rel == NOT_EQ){
            res = ( *((int*)buf1) != *(((int*)buf2)) );
        }else if (rel == GTH){
            res = ( *((int*)buf1) > *(((int*)buf2)) );
        }else if (rel == LTH){
            res = ( *((int*)buf1) < *(((int*)buf2)) );
        }else if (rel == GEQ){
            res = ( *((int*)buf1) >= *(((int*)buf2)) );
        }else if (rel == LEQ){
            res = ( *((int*)buf1) <= *(((int*)buf2)) );
        }

    }else if (type == FLOAT){
        if(rel == EQ){
            res = ( *((float*)buf1) == *(((float*)buf2)) );
        }else if (rel == NOT_EQ){
            res = ( *((float*)buf1) != *(((float*)buf2)) );
        }else if (rel == GTH){
            res = ( *((float*)buf1) > *(((float*)buf2)) );
        }else if (rel == LTH){
            res = ( *((float*)buf1) < *(((float*)buf2)) );
        }else if (rel == GEQ){
            res = ( *((float*)buf1) >= *(((float*)buf2)) );
        }else if (rel == LEQ){
            res = ( *((float*)buf1) <= *(((float*)buf2)) );
        }

    }else{
        int tmp = stringCmp(buf1,buf2,size);
        if(rel == EQ){
            res = (tmp == 0);
        }else if (rel == NOT_EQ){
            res = (tmp != 0);
        }else if (rel == GTH){
            res = (tmp > 0);
        }else if (rel == LTH){
            res = (tmp < 0);
        }else if (rel == GEQ){
            res = (tmp >= 0);
        }else if (rel == LEQ){
            res = (tmp <= 0);
        }
    }
    return res;
}


/*
 * transform_dict_filter_and: merge the filter for dictionary-compressed predicate into the final filter.
 * @dictFilter: the filter for the dictionary compressed data
 * @dictFact: the compressed fact table column
 * @tupleNum: the number of tuples in the column
 * @filter: the filter for the uncompressed data
 */

__global__ static void transform_dict_filter_and(int * dictFilter, char *dictFact, long tupleNum, int dNum,  int * filter, int byteNum){

    int stride = blockDim.x * gridDim.x;
    int offset = blockIdx.x*blockDim.x + threadIdx.x;

    int * fact = (int*)(dictFact + sizeof(struct dictHeader));

    int numInt = (tupleNum * byteNum +sizeof(int) - 1) / sizeof(int) ;

    for(long i=offset; i<numInt; i += stride){
        int tmp = fact[i];
        unsigned long bit = 1;

        for(int j=0; j< sizeof(int)/byteNum; j++){
            int t = (bit << ((j+1)*byteNum*8)) -1 - ((1<<(j*byteNum*8))-1);
            int fkey = (tmp & t)>> (j*byteNum*8) ;
            filter[i* sizeof(int)/byteNum + j] &= dictFilter[fkey];
        }
    }
}

__global__ static void transform_dict_filter_init(int * dictFilter, char *dictFact, long tupleNum, int dNum,  int * filter,int byteNum){

    int stride = blockDim.x * gridDim.x;
    int offset = blockIdx.x*blockDim.x + threadIdx.x;

    int * fact = (int*)(dictFact + sizeof(struct dictHeader));
    int numInt = (tupleNum * byteNum +sizeof(int) - 1) / sizeof(int) ;

    for(long i=offset; i<numInt; i += stride){
        int tmp = fact[i];
        unsigned long bit = 1;

        for(int j=0; j< sizeof(int)/byteNum; j++){
            int t = (bit << ((j+1)*byteNum*8)) -1 - ((1<<(j*byteNum*8))-1);
            int fkey = (tmp & t)>> (j*byteNum*8) ;
            filter[i* sizeof(int)/byteNum + j] = dictFilter[fkey];
        }
    }
}

__global__ static void transform_dict_filter_or(int * dictFilter, char *fact, long tupleNum, int dNum,  int * filter,int byteNum){

    int stride = blockDim.x * gridDim.x;
    int offset = blockIdx.x*blockDim.x + threadIdx.x;

    int numInt = (tupleNum * byteNum +sizeof(int) - 1) / sizeof(int) ;

    for(long i=offset; i<numInt; i += stride){
        int tmp = ((int *)fact)[i];
        unsigned long bit = 1;

        for(int j=0; j< sizeof(int)/byteNum; j++){
            int t = (bit << ((j+1)*byteNum*8)) -1 - ((1<<(j*byteNum*8))-1);
            int fkey = (tmp & t)>> (j*byteNum*8) ;
            filter[i* sizeof(int)/byteNum + j] |= dictFilter[fkey];
        }
    }
}

/*
 * genScanFilter_dict_init: generate the filter for dictionary-compressed predicate
 */

__global__ static void genScanFilter_dict_init(struct dictHeader *dheader, int colSize, int colType, int dNum, struct whereExp *where, int *dfilter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(int i=tid;i<dNum;i+=stride){
        int fkey = dheader->hash[i];
        con = testCon((char *)&fkey,where->content,colSize,colType,where->relation);
        dfilter[i] = con;
    }
}

__global__ static void genScanFilter_dict_or(struct dictHeader *dheader, int colSize, int colType, int dNum, struct whereExp *where, int *dfilter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(int i=tid;i<dNum;i+=stride){
        int fkey = dheader->hash[i];
        con = testCon((char *)&fkey,where->content,colSize,colType,where->relation);
        dfilter[i] |= con;
    }
}

__global__ static void genScanFilter_dict_and(struct dictHeader *dheader, int colSize, int colType, int dNum, struct whereExp *where, int *dfilter){
        int stride = blockDim.x * gridDim.x;
        int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(int i=tid;i<dNum;i+=stride){
        int fkey = dheader->hash[i];
        con = testCon((char *)&fkey,where->content,colSize,colType,where->relation);
        dfilter[i] &= con;
    }
}

__global__ static void genScanFilter_rle(char *col, int colSize, int colType, long tupleNum, struct whereExp *where, int andOr, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    struct rleHeader *rheader = (struct rleHeader *) col;
    int dNum = rheader->dictNum;

    for(int i = tid; i<dNum; i += stride){
        int fkey = ((int *)(col+sizeof(struct rleHeader)))[i];
        int fcount = ((int *)(col+sizeof(struct rleHeader)))[i + dNum];
        int fpos = ((int *)(col+sizeof(struct rleHeader)))[i + 2*dNum];

        con = testCon((char *)&fkey,where->content,colSize,colType,where->relation);

        for(int k=0;k<fcount;k++){
            if(andOr == AND)
                filter[fpos+k] &= con;
            else
                filter[fpos+k] |= con;
        }

    }
}

__global__ static void genScanFilter_and_in(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, *(char **)where->content + colSize * j, colSize) == 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_in_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;

    for(long i = tid; i < tupleNum; i += stride){
        int vlen = *((*(int ***)where->content)[i]);
        char *str_st = (*(char ***)where->content)[i] + sizeof(int);
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, str_st + colSize * j, colSize) == 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_nin(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, *(char **)where->content + colSize * j, colSize) == 0);
        filter[i] &= (~con);
    }
}

__global__ static void genScanFilter_and_nin_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;

    for(long i = tid; i < tupleNum; i += stride){
        int vlen = *((*(int ***)where->content)[i]);
        char *str_st = (*(char ***)where->content)[i] + sizeof(int);
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, str_st + colSize * j, colSize) == 0);
        filter[i] &= (~con);
    }
}

__global__ static void genScanFilter_and_like(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 1;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        int pos = 0, res;
        con = 1;
        for(long j = 0; j < vlen; j++){
            const char *str1 = col + colSize * i;
            const char *str2 = *(char **)where->content + colSize * j;
            int len1 = stringLen(str1);
            int len2 = stringLen(str2);
            len1 = len1 < colSize ? len1 : colSize;
            len2 = len2 < colSize ? len2 : colSize;

            if(j == 0){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res == 0);
                pos += len2;
            }else if(j == vlen - 1){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res + len2 == len1);
            }else{
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res != -1);
                pos = res + len2;
            }
            if(!con) break;
        }
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_nlike(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 1;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        int pos = 0, res;
        con = 1;
        for(long j = 0; j < vlen; j++){
            const char *str1 = col + colSize * i;
            const char *str2 = *(char **)where->content + colSize * j;
            int len1 = stringLen(str1);
            int len2 = stringLen(str2);
            len1 = len1 < colSize ? len1 : colSize;
            len2 = len2 < colSize ? len2 : colSize;

            if(j == 0){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res == -1);
                pos += len2;
            }else if(j == vlen - 1){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= !(res + len2 == len1);
            }else{
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res == -1);
                pos = res + len2;
            }
            if(!con) break;
        }
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_eq(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content, colSize) == 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_neq(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content, colSize) != 0);
        filter[i] &= con;
    }
}


__global__ static void genScanFilter_and_eq_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i, colSize) == 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_neq_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i, colSize) != 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_gth(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content, colSize) > 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_gth_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i, colSize) > 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_lth(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content, colSize) < 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_lth_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i, colSize) < 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_geq(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content, colSize) >= 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_geq_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i, colSize) >= 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_leq(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content, colSize) <= 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_leq_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i, colSize) <= 0);
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_init_int_eq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] == where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_eq_idx(char *col, int *idx, int *st, int *ed, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = *st + tid; i < *ed; i += stride){
        con = ((int *)col)[idx[i]] == where;
        filter[idx[i]] = con;
    }

}

__global__ static void genScanFilter_init_int_neq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] != where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_eq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] == where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_neq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] != where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_eq(char *col, long tupleNum, float where, int * filter){
        int stride = blockDim.x * gridDim.x;
        int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] == where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_neq(char *col, long tupleNum, float where, int * filter){
        int stride = blockDim.x * gridDim.x;
        int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] != where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_eq_vec(char *col, long tupleNum, float *where, int * filter){
        int stride = blockDim.x * gridDim.x;
        int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] == where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_neq_vec(char *col, long tupleNum, float *where, int * filter){
        int stride = blockDim.x * gridDim.x;
        int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] != where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_gth(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] > where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_gth_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] > where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_gth(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        // printf("((float*)col)[i] = %f\n", ((float*)col)[i]);
        con = ((float*)col)[i] > where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_gth_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] > where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_lth(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] < where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_lth_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] < where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_lth(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] < where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_lth_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] < where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_geq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] >= where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_geq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] >= where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_geq(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] >= where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_geq_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] >= where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_leq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] <= where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_int_leq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] <= where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_leq(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] <= where;
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_float_leq_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] <= where[i];
        filter[i] = con;
    }
}

__global__ static void genScanFilter_and_int_eq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] == where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_neq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] != where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_eq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] == where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_neq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] != where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_eq(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] == where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_neq(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] != where;
        filter[i] &= con;
    }
}


__global__ static void genScanFilter_and_float_eq_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] == where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_neq_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] != where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_geq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] >= where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_geq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] >= where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_geq(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] >= where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_geq_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] >= where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_leq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] <= where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_leq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] <= where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_leq(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] <= where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_leq_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] <= where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_gth(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] > where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_gth_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] > where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_gth(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] > where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_gth_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] > where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_lth(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] < where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_int_lth_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] < where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_lth(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] < where;
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_and_float_lth_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] < where[i];
        filter[i] &= con;
    }
}

__global__ static void genScanFilter_init_in(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, *(char **)where->content + colSize * j, colSize) == 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_in_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    // int stride = blockDim.x * gridDim.x;
    // int tid = blockIdx.x * blockDim.x + threadIdx.x;
    // int con = 0;

    // for(long i = tid; i < tupleNum; i += stride){
    //     int vlen = *((*(int ***)where->content)[i]);
    //     char *str_st = (*(char ***)where->content)[i] + sizeof(int);
    //     con = 0;
    //     for(long j = 0; j < vlen; j++)
    //         con |= (stringCmp(col + colSize * i, str_st + colSize * j, colSize) == 0);
    //     filter[i] = con;
    // }

    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;
    // printf("tupleNum =%d\n", tupleNum);
    for(long i = tid; i < tupleNum; i += stride){
        int vlen = where->num;
        // printf("[in_vec scan] in_vec num = %d\n", vlen);
        char *str_st = where->column;
        // char *str_st = (*(char ***)where->content)[0] + sizeof(int);
        con = 0;
        // printf("con = %d\n", con);
        for(long j = 0; j < vlen; j++){
            con |= (stringCmp(col + colSize * i, str_st + colSize * j, colSize) == 0);
        }
        filter[i] = con;
        // if(con == 1)
        //     printf("[%d] = 1\n", i);
    }
}


__global__ static void genScanFilter_init_nin(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, *(char **)where->content + colSize * j, colSize) == 0);
        filter[i] = ~con;
    }
}

__global__ static void genScanFilter_init_nin_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;

    for(long i = tid; i < tupleNum; i += stride){
        int vlen = *((*(int ***)where->content)[i]);
        char *str_st = (*(char ***)where->content)[i] + sizeof(int);
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, str_st + colSize * j, colSize) == 0);
        filter[i] = ~con;
    }
}

__global__ static void genScanFilter_init_like(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 1;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        int pos = 0, res;
        con = 1;
        for(long j = 0; j < vlen; j++){
            const char *str1 = col + colSize * i;
            const char *str2 = *(char **)where->content + colSize * j;
            int len1 = stringLen(str1);
            int len2 = stringLen(str2);
            len1 = len1 < colSize ? len1 : colSize;
            len2 = len2 < colSize ? len2 : colSize;

            if(j == 0){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res == 0);
                pos += len2;
            }else if(j == vlen - 1){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res + len2 == len1);
            }else{
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res != -1);
                pos = res + len2;
            }
            if(!con) break;
        }
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_nlike(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 1;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        int pos = 0, res;
        con = 1;
        for(long j = 0; j < vlen; j++){
            const char *str1 = col + colSize * i;
            const char *str2 = *(char **)where->content + colSize * j;
            int len1 = stringLen(str1);
            int len2 = stringLen(str2);
            len1 = len1 < colSize ? len1 : colSize;
            len2 = len2 < colSize ? len2 : colSize;

            if(j == 0){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res == -1);
                pos += len2;
            }else if(j == vlen - 1){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= !(res + len2 == len1);
            }else{
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res == -1);
                pos = res + len2;
            }
            if(!con) break;
        }
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_eq(char *col, int colSize,long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content,colSize) == 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_neq(char *col, int colSize,long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content,colSize) != 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_eq_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i,colSize) == 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_neq_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i,colSize) != 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_gth(char *col, int colSize,long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content,colSize) > 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_gth_vec(char *col, int colSize,long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i,colSize) > 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_lth(char *col, int colSize,long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content,colSize) < 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_lth_vec(char *col, int colSize,long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i, colSize) < 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_geq(char *col, int colSize,long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content,colSize) >= 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_geq_vec(char *col, int colSize,long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i, colSize) >= 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_leq(char *col, int colSize,long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, where->content,colSize) <= 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_init_leq_vec(char *col, int colSize,long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize*i, str_vec + colSize * i, colSize) <= 0);
        filter[i] = con;
    }
}

__global__ static void genScanFilter_or_in(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, *(char **)where->content + colSize * j, colSize) == 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_in_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;

    for(long i = tid; i < tupleNum; i += stride){
        int vlen = *((*(int ***)where->content)[i]);
        char *str_st = (*(char ***)where->content)[i] + sizeof(int);
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, str_st + colSize * j, colSize) == 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_nin(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, *(char **)where->content + colSize * j, colSize) == 0);
        filter[i] |= ~con;
    }
}

__global__ static void genScanFilter_or_nin_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 0;

    for(long i = tid; i < tupleNum; i += stride){
        int vlen = *((*(int ***)where->content)[i]);
        char *str_st = (*(char ***)where->content)[i] + sizeof(int);
        con = 0;
        for(long j = 0; j < vlen; j++)
            con |= (stringCmp(col + colSize * i, str_st + colSize * j, colSize) == 0);
        filter[i] |= ~con;
    }
}

__global__ static void genScanFilter_or_like(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 1;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        int pos = 0, res;
        con = 1;
        for(long j = 0; j < vlen; j++){
            const char *str1 = col + colSize * i;
            const char *str2 = *(char **)where->content + colSize * j;
            int len1 = stringLen(str1);
            int len2 = stringLen(str2);
            len1 = len1 < colSize ? len1 : colSize;
            len2 = len2 < colSize ? len2 : colSize;

            if(j == 0){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res == 0);
                pos += len2;
            }else if(j == vlen - 1){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res + len2 == len1);
            }else{
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res != -1);
                pos = res + len2;
            }
            if(!con) break;
        }
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_nlike(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con = 1;
    int vlen = where->vlen;

    for(long i = tid; i < tupleNum; i += stride){
        int pos = 0, res;
        con = 1;
        for(long j = 0; j < vlen; j++){
            const char *str1 = col + colSize * i;
            const char *str2 = *(char **)where->content + colSize * j;
            int len1 = stringLen(str1);
            int len2 = stringLen(str2);
            len1 = len1 < colSize ? len1 : colSize;
            len2 = len2 < colSize ? len2 : colSize;

            if(j == 0){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res == -1);
                pos += len2;
            }else if(j == vlen - 1){
                if(!len2) continue;
                res = stringFind(str1, str2, len1, len2, pos);
                con &= !(res + len2 == len1);
            }else{
                res = stringFind(str1, str2, len1, len2, pos);
                con &= (res == -1);
                pos = res + len2;
            }
            if(!con) break;
        }
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_eq(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, where->content, colSize) == 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_neq(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, where->content, colSize) != 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_eq_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, str_vec + colSize * i, colSize) == 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_neq_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, str_vec + colSize * i, colSize) != 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_gth(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, where->content, colSize)> 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_gth_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, str_vec + colSize * i, colSize)> 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_lth(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, where->content, colSize) < 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_lth_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, str_vec + colSize * i, colSize) < 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_geq(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, where->content, colSize) >= 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_geq_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, str_vec + colSize * i, colSize) >= 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_leq(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, where->content, colSize) <= 0);
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_leq_vec(char *col, int colSize, long tupleNum, struct whereExp * where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    char *str_vec = *((char **) where->content);
    for(long i = tid; i<tupleNum;i+=stride){
        con = (stringCmp(col+colSize *i, str_vec + colSize * i, colSize) <= 0);
        filter[i] |= con;
    }
}


__global__ static void genScanFilter_or_int_eq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] == where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_neq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] != where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_eq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] == where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_neq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] != where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_eq(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] == where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_neq(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] != where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_eq_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] == where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_neq_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] != where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_gth(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] > where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_gth_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] > where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_gth(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] > where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_gth_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] > where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_lth(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] < where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_lth_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] < where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_lth(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] < where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_lth_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] < where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_geq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] >= where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_geq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] >= where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_geq(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] >= where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_geq_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] >= where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_leq(char *col, long tupleNum, int where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] <= where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_int_leq_vec(char *col, long tupleNum, int *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((int*)col)[i] <= where[i];
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_leq(char *col, long tupleNum, float where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] <= where;
        filter[i] |= con;
    }
}

__global__ static void genScanFilter_or_float_leq_vec(char *col, long tupleNum, float *where, int * filter){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int con;

    for(long i = tid; i<tupleNum;i+=stride){
        con = ((float*)col)[i] <= where[i];
        filter[i] |= con;
    }
}

/*
 * countScanNum: count the number of results that each thread generates.
 */

__global__ static void countScanNum(int *filter, long tupleNum, int * count){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int localCount = 0;

    for(long i = tid; i<tupleNum; i += stride){
        localCount += filter[i];
    }

    count[tid] = localCount;

}

__global__ static void countScanNum_idx(int *filter, int *index, int *st, int *ed, int *count)
{
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int localCount = 0;

    for(long i = tid + *st; i< *ed; i += stride){
        localCount += filter[index[i]];
    }

    count[tid] = localCount;
}

/*
 * scan_dict_other: generate the result for dictionary-compressed column.
 */

__global__ static void scan_dict_other(char *col, struct dictHeader * dheader, int byteNum,int colSize, long tupleNum, int *psum, long resultNum, int * filter, char * result){

    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int pos = psum[tid] * colSize;

    for(long i = tid; i<tupleNum; i+= stride){
        if(filter[i] == 1){
            int key = 0;
            memcpy(&key, col + sizeof(struct dictHeader) + i* dheader->bitNum/8, dheader->bitNum/8);
            memcpy(result+pos,&dheader->hash[key],colSize);
            pos += colSize;
        }
    }
}

__global__ static void scan_dict_int(char *col, struct dictHeader * dheader,int byteNum,int colSize, long tupleNum, int *psum, long resultNum, int * filter, char * result){

    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int localCount = psum[tid];

    for(long i = tid; i<tupleNum; i+= stride){
        if(filter[i] == 1){
            int key = 0;
            memcpy(&key, col + sizeof(struct dictHeader) + i*byteNum, byteNum);
            ((int *)result)[localCount] = dheader->hash[key];
            localCount ++;
        }
    }
}

/*
 * scan_other: generate scan result for uncompressed column.
 */

__global__ static void scan_other(char *col, int colSize, long tupleNum, int *psum, long resultNum, int * filter, char * result){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int pos = psum[tid]  * colSize;

    for(long i = tid; i<tupleNum;i+=stride){

        if(filter[i] == 1){
            memcpy(result+pos,col+i*colSize,colSize);
            pos += colSize;
        }
    }
}

__global__ static void scan_other_idx(char *col, int colSize, int *idx, int *st, int *ed, int *psum, long resultNum, int * filter, char * result){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int pos = psum[tid]  * colSize;

    for(long i = tid + *st; i < *ed;i+=stride){

        if(filter[idx[i]] == 1){
            memcpy(result+pos,col+idx[i]*colSize,colSize);
            pos += colSize;
        }
    }
}


__global__ static void scan_int(char *col, int colSize, long tupleNum, int *psum, long resultNum, int * filter, char * result){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int localCount = psum[tid] ;

    for(long i = tid; i<tupleNum;i+=stride){

        if(filter[i] == 1){
            ((int*)result)[localCount] = ((int*)col)[i];
            localCount ++;
        }
    }
}

__global__ static void scan_int_idx(char *col, int colSize, int *idx, int *st, int *ed, int *psum, long resultNum, int * filter, char * result){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int localCount = psum[tid] ;

    for(long i = tid + *st; i < *ed;i+=stride){
        if(filter[idx[i]] == 1){
            ((int*)result)[localCount] = ((int*)col)[idx[i]];
            localCount ++;
        }
    }
}

__global__ void static unpack_rle(char * fact, char * rle, long tupleNum, int dNum){

    int offset = blockIdx.x*blockDim.x + threadIdx.x;
    int stride = blockDim.x * gridDim.x;

    for(int i=offset; i<dNum; i+=stride){

        int fvalue = ((int *)(fact+sizeof(struct rleHeader)))[i];
        int fcount = ((int *)(fact+sizeof(struct rleHeader)))[i + dNum];
        int fpos = ((int *)(fact+sizeof(struct rleHeader)))[i + 2*dNum];

        for(int k=0;k<fcount;k++){
            ((int*)rle)[fpos+ k] = fvalue;
        }
    }
}

/*
 * Construct bitmap buffer based on the index results.
 */
__global__ void static indexScanPackResult(int* posIdx_d, int* bitmapRes_d, int l_offset, int h_offset, int tupleNum){
    int stride = blockDim.x * gridDim.x;
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    int pos;
    for(int i = l_offset+tid; i<=h_offset; i+=stride){
        if (l_offset<=i && i<=h_offset){
            pos = posIdx_d[i];
            bitmapRes_d[pos] = 1;
        }
    }
}

/*
 * Performs index scan
 */
 int indexScanInt (struct tableNode *tn, int columnPos, int idxPos, int filterValue, int* bitmapRes_d, struct statistic *pp){

    //Check assumption (INT enum == 4)
    if (tn->attrType[columnPos] != 4 ){
        printf("[ERROR] Indexing is only supported for INT type!\n");
        exit(-1);
    }
    if (tn->attrSize[columnPos] != sizeof(int)){
        printf("[ERROR] Indexing is only supported for INT type (and size!)!\n");
        exit(-1); 
    }


    //Start timer for Index Step 1 - Get index position 
    struct timespec startInxS1, endInxS1;
    clock_gettime(CLOCK_REALTIME,&startInxS1);

    //Get data size
    long dataSize = tn->tupleNum * tn->attrSize[columnPos];

    //Get index
    int* contentIdx_d;
    if (tn->indexPos == MEM){
        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&contentIdx_d, dataSize));      
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(contentIdx_d, tn->contentIdx[idxPos], dataSize, cudaMemcpyHostToDevice));
    }else if (tn->indexPos == GPU){
        contentIdx_d = tn->contentIdx[idxPos]; 
    }else{
        printf("[ERROR] Index can be on either on host or device!\n");
        exit(-1);
    }

    //Stop timer for Index Step 1 - Get index position 
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endInxS1);
    pp->getIndexPos_idxS1 += (endInxS1.tv_sec - startInxS1.tv_sec)* BILLION + endInxS1.tv_nsec - startInxS1.tv_nsec;    

    
    // Implemenation with 2 binary searches
    // ----------------------------------
    // bool exists = thrust::binary_search(thrust::device, contentIdx_d, contentIdx_d + tn->tupleNum, filterValue); 
    // int l_offset = -1; 
    // int h_offset = -1;
    // if (exists){
    //     thrust::pair<int *, int *> range;
    //     range = thrust::equal_range(thrust::device, contentIdx_d, contentIdx_d + tn->tupleNum, filterValue); 
    //     l_offset = (int) (range.first - contentIdx_d); 
    //     h_offset = (int) (range.second - contentIdx_d) - 1;
    // }
    // ----------------------------------

    // Implemenation with 1 binary search
    // ---------------------------------- 
    
    //Start timer for Index Step 2 - Get range
    struct timespec startInxS2, endInxS2;
    clock_gettime(CLOCK_REALTIME,&startInxS2);
    
    //Get range
    thrust::pair<int *, int *> range; 
    range = thrust::equal_range(thrust::device, contentIdx_d, contentIdx_d + tn->tupleNum, filterValue);     
    int l_offset = -1; 
    int h_offset = -1;

    //Stop timer for Index Step 2 - Get range
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endInxS2);
    pp->getRange_idxS2 += (endInxS2.tv_sec - startInxS2.tv_sec)* BILLION + endInxS2.tv_nsec - startInxS2.tv_nsec;    


    //Start timer for Index Step 3 - Convert mem addrs to elements
    struct timespec startInxS3, endInxS3;
    clock_gettime(CLOCK_REALTIME,&startInxS3);

    //Check if value exists
    bool exists = false; 
    int* firstRangeValue = (int *) malloc(sizeof(int));
    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(firstRangeValue, range.first, sizeof(int), cudaMemcpyDeviceToHost));  
    if (firstRangeValue[0] == filterValue){
        exists = true;
    }

    //Convert addrs to elements
    if (exists){ 
        l_offset = (int) (range.first - contentIdx_d); 
        h_offset = (int) (range.second - contentIdx_d) - 1;
    }  
    
    //Calculate number of selected nodes
    int countResult = (h_offset + 1) - l_offset ;
    
    //Stop timer for Index Step 3 - Convert mem addrs to elements
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endInxS3);
    pp->convertMemToElement_idxS3 += (endInxS3.tv_sec - startInxS3.tv_sec)* BILLION + endInxS3.tv_nsec - startInxS3.tv_nsec;    
        
    // ----------------------------------


    //Start timer for Index Step 4 - Get mapping position 
    struct timespec startInxS4, endInxS4;
    clock_gettime(CLOCK_REALTIME,&startInxS4);

    //Get mapping pos
    int* posIdx_d;
    if (tn->indexPos == MEM){
        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&posIdx_d, dataSize));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(posIdx_d, tn->posIdx[idxPos], dataSize, cudaMemcpyHostToDevice));  
    }else if (tn->indexPos == GPU){
        posIdx_d = tn->posIdx[idxPos];
    }else{
        printf("[ERROR] Index mapping can be on either on host or device!\n");
        exit(-1);
    }

    //Stop timer for Index Step 4 - Get mapping position 
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endInxS4);
    pp->getMapping_idxS4 += (endInxS4.tv_sec - startInxS4.tv_sec)* BILLION + endInxS4.tv_nsec - startInxS4.tv_nsec;    


    //Start timer for Index Step 5 - Set bitmap to zero
    struct timespec startInxS5, endInxS5;
    clock_gettime(CLOCK_REALTIME,&startInxS5);

    //Set everything to false
    CUDA_SAFE_CALL_NO_SYNC(cudaMemset(bitmapRes_d, 0, sizeof(int)* tn->tupleNum)); 

    //Stop timer for Index Step 5 - Set bitmap to zero
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endInxS5);
    pp->setBitmapZeros_idxS5 += (endInxS5.tv_sec - startInxS5.tv_sec)* BILLION + endInxS5.tv_nsec - startInxS5.tv_nsec;    

    //Start timer for Index Step 6 - Build bitmap
    struct timespec startInxS6, endInxS6;
    clock_gettime(CLOCK_REALTIME,&startInxS6);

    //Define Grid and block size
    dim3 grid(2048);
    dim3 block(256);  

    //Construct bitmap filter result
    if (exists){
        indexScanPackResult<<<grid,block>>>(posIdx_d, bitmapRes_d, l_offset, h_offset, tn->tupleNum);
    }

    //Stop timer for Index Step 6 - Build bitmap
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endInxS6);
    pp->buildBitmap_idxS6 += (endInxS6.tv_sec - startInxS6.tv_sec)* BILLION + endInxS6.tv_nsec - startInxS6.tv_nsec;    

    //Return selected rows
    return countResult;
}

/*
 * tableScan Prerequisites:
 *  1. the input data can be fit into GPU device memory
 *  2. input data are stored in host memory
 *
 * Input:
 *  sn: contains the data to be scanned and the predicate information
 *  pp: records statistics such kernel execution time and PCIe transfer time
 *
 * Output:
 *  A new table node
 */


__global__ static void pr_int_array(int *arr, int size)
{
    int stride = blockDim.x * gridDim.x;
    int offset = blockIdx.x * blockDim.x + threadIdx.x;
    for(int i = offset; i < size; i += stride)
        printf("%d, ", arr[i]);
    printf("\n");
}

__global__ static void set_zero(int *filter, long  inNum){
    int stride = blockDim.x * gridDim.x;
    int offset = blockIdx.x * blockDim.x + threadIdx.x;
    //int global_index = threadIdx.x + blockDim.x * threadIdx.y;
    for (int i = offset; i<inNum; i += stride){
        filter[i] = 0;
    }
}

__global__ void andArrays(int* arr1, const int* arr2, int size) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index < size) {
        arr1[index] = arr1[index] & arr2[index];
    }
}

__global__ void L2distance(float* res, const float* search, const char * data, int dim, int num) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    float * dataf = (float *)data;

    if (idx < num) {
        float distance = 0.0;

        for (int i = 0; i < dim; ++i) {
            float diff = search[i] - dataf[idx * dim + i];
            distance += diff * diff;
        }

        res[idx] = sqrt(distance);
        // printf("[L2distance] res[%d] = %f\n", idx, res[idx]);
    }

    // if(idx == 0){
    //     for (int i = 0; i < 10; ++i) {
    //         float f = dataf[i];
    //         printf("d[%d] = %f   ", i, f);
    //         if(i % 10 == 0)
    //             printf("\n");
    //     }
    //     printf("\n");
    // }
}

__global__ void twoColL2Distance(char * res, char * col0, char * col1, int dim, int num) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    float * f0 = (float *)col0;
    float * f1 = (float *)col1;
    float * fres = (float *)res;
    
    if (idx < num) {
        float distance = 0.0;

        for (int i = 0; i < dim; ++i) {
            float diff = f0[idx * dim + i] - f1[idx * dim + i];
            distance += diff * diff;
        }

        fres[idx] = distance;
        // printf("%f\n", distance);
    }
}

// std::vector<int> andVectors(const std::vector<int>& v1, const std::vector<int>& v2) {
//     std::vector<int> result;

//     for (std::size_t i = 0; i < v1.size(); ++i) {
//         result.push_back(v1[i] && v2[i]);
//     }

//     return result;
// }

__global__ void genScanFilter_and_distance(const char* col1, const char* col2, size_t vectorSize, int totalTupleNum, float threshold, int* filter) {
    int index = threadIdx.x + blockIdx.x * blockDim.x;

    if (index < totalTupleNum) {
        const float* vec1 = (float*)col1 + index * vectorSize;
        const float* vec2 = (float*)col2 + index * vectorSize;
        float distance = 0.0f;

        for (size_t i = 0; i < vectorSize; ++i) {
            float diff = vec1[i] - vec2[i];
            distance += diff * diff;
        }

        distance = sqrtf(distance);

        if (distance < threshold) {
            filter[index] = 1;
        } else {
            filter[index] = 0;
        }
    }
}

__global__ void setFilter(int* globalFilter, size_t* nns, int k) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;

    globalFilter[idx] = 0;

    for (int i = 0; i < k; ++i) {
        if (idx == nns[i]) {
            globalFilter[idx] = 1;
            break;
        }
    }
}

__global__ void setZeroKernel(int* globalFilter, size_t numElements) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < numElements) {
        globalFilter[idx] = 0;
    }
}


__global__ void setIndicesKernel(int* globalFilter, const size_t* nns, size_t k) {
    size_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < k) {
        globalFilter[nns[idx]] = 1;
    }
}


struct distanceFilter {
    int colIndex;
    int nearestk;
    std::vector<float> searchVec; 
    int *filter;
};

struct distanceTwoCol {
    int firstColIndex;
    int secondColIndex;
    int projectIndex;
};


struct tableNode * tableScan(struct scanNode *sn, struct statistic *pp,
                             Mempool *host_mp = NULL, Mempool *dev_mp = NULL, Mempool *res_mp = NULL, int *idx = NULL, int *st = NULL, int *ed = NULL, faiss::Index *faiss_index = NULL){

    //Start timer (total tableScan())
    struct timespec startTableScanTotal,endTableScanTotal;
    clock_gettime(CLOCK_REALTIME,&startTableScanTotal);

    struct timespec annsAddStart, annsAddEnd;
    struct timespec annsSearchStart, annsSearchEnd;
    struct timespec readIndexStart, readIndexEnd;
    struct timespec cpu2gpuStart, cpu2gpuEnd;
    struct timespec annsStart, annsEnd;
    struct timespec s, e;
    double tt;
    clock_gettime(CLOCK_REALTIME,&s);

    // char intArray[16384*16];
    // printf("[tableScan.cu] the type of result[0] :%d\n", sn->tn->attrType[0]);
    // printf("[tableScan.cu] the type of result[1] :%d\n", sn->tn->attrType[1]);
    // cudaMemcpy(intArray, sn->tn->content[1], sizeof(float) * 100, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 100; i++){
    //     printf("\t%f", intArray[i]);
    //     if((i+1) % 10 == 0)
    //         printf("\n");
	// }

    printf("\n================ [tableScan.cu] Start ================\n");
    int numProject = sn->projectNum;
    // printf("[tableScan.cu] numProject = %d\n", numProject);
    int numOutputAttr = sn->outputNum;
    // printf("[tableScan.cu] res->attrNum = %d\n", numOutputAttr);

    int disFilterCount = 0, disTwoColProject = 0;
    for (int i = 0; i < numProject; i++) {
        // printf("[tableScan.cu] sn->project->exp[%d].funcType = %d\n", i, sn->project->exp[i].funcType);
        if(sn->project->exp[i].func == DISTANCE and (sn->project->exp[i].funcType == 0 or  sn->project->exp[i].funcType == 1)){
            disFilterCount += 1;
        }
        else if (sn->project->exp[i].func == DISTANCE and sn->project->exp[i].funcType == 2) {
            disTwoColProject += 1;
        }
        
    }
    printf("[tableScan.cu] disFilterCount = %d, disTwoColProject = %d\n", disFilterCount, disTwoColProject);


    struct distanceFilter *dFilter = (struct distanceFilter *)malloc(sizeof(struct distanceFilter) * disFilterCount);
    std::vector<float> searchV;
    struct distanceTwoCol *dTwoCol = (struct distanceTwoCol *)malloc(sizeof(struct distanceTwoCol) * disTwoColProject);
    int ctmp1 = 0, ctmp2 = 0;
    for (int i = 0; i < numProject; i++) {
        if(sn->project->exp[i].func == DISTANCE and (sn->project->exp[i].funcType == 0 or sn->project->exp[i].funcType == 1)){
            /* 
                funType = 0: DISTANCE(v1, EXTRACTION(path))
                funType = 1: DISTANCE(v1, path)
                project one vector column to one float column (both of these two types need filter first)
            */
            dFilter[ctmp1].colIndex = sn->project->exp[i].index;
            int limit = sn->project->exp[i].limit;
            if(limit == -1) //pass limit
                dFilter[ctmp1].nearestk = 5;
            else
                dFilter[ctmp1].nearestk = min(limit * 5, 1024);
            // readFloatArray(dFilter[ctmp1].searchVec, sn->project->exp[i].vecPath);
            readFloatArray(searchV, sn->project->exp[i].vecPath);
            // printf("searchV");
            // printf("%f", searchV[0]);
            // dFilter[ctmp1].searchVec.assign(searchV.begin(), searchV.end());
            // for(int i = 0; i < searchV.size(); i++){
            //     printf("searchV[%d] = %f\n", i, searchV[i]);
            // }

            ctmp1++;
        } 
        else if (sn->project->exp[i].func == DISTANCE and sn->project->exp[i].funcType == 2) {
            /* 
                funType = 2: DISTANCE(v1, v2)
                project two vector columns to one float column
            */
            dTwoCol[ctmp2].firstColIndex = sn->project->exp[i].index;
            dTwoCol[ctmp2].secondColIndex = sn->project->exp[i].secondIndex;
            dTwoCol[ctmp2].projectIndex = i;
            printf("dTwoCol[%d].projectIndex = %d\n", ctmp2, i);
            ctmp2++;
        }
    }

    clock_gettime(CLOCK_REALTIME,&s);

    // std::vector<int> globalFilter(sn->tn->tupleNum, 1);
    // int* globalFilter = (int*)malloc(sizeof(int) * sn->tn->tupleNum);
    int* globalFilter;
    int has_globalFilter = 0;
    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&globalFilter, sizeof(int) * sn->tn->tupleNum));
    const int blockSize = 256;
    const int gridSize = (sn->tn->tupleNum + blockSize - 1) / blockSize;
    setZeroKernel<<<gridSize, blockSize>>>(globalFilter, sn->tn->tupleNum);

    // std::vector<int> filter(sn->tn->tupleNum, 0);

    /*
        DISTANCE(PATH, v1)
        @filter: init to 0, set element to 1 while in nearest neighbor search
        @globalFilter: init to 1, globalFilter &= filter
    */
    for (int i = 0; i < disFilterCount; i++) {
        float *feature = (float *)(sn->tn->content[dFilter[i].colIndex]);
        
        clock_gettime(CLOCK_REALTIME,&e);
        tt = (e.tv_sec - s.tv_sec)* BILLION + e.tv_nsec - s.tv_nsec;
        printf("tt0 = %f\n", tt/(1000*1000));
        clock_gettime(CLOCK_REALTIME,&s);

        size_t feature_num = (size_t)(sn->tn->tupleNum);
        // initial index
        // size_t length = strlen(sn->tn->attrName[i]);
        char prestr[50] = "../../vector_src/init_vector/";
        char endstr[50] = "_index.faissindex";
        char *tmpstr = strcat(prestr, sn->tn->attrName[i]);
        const char* index_path = strcat( tmpstr, endstr);

        // std::cout << "[tableScan.cu] index path = \"" << index_path << "\"" << std::endl;
        int dev_no = 0;
        int k = dFilter[i].nearestk;
        int nq = 1;  //query num
        std::vector<faiss::idx_t> nns(k * nq);
        std::vector<float> dis(k * nq);
        int disColIndex = dFilter[i].colIndex;
        // if index exist
        //   read index from desk 
        // else
        //   train index and save it

        // anns Start
        clock_gettime(CLOCK_REALTIME,&annsStart);
        if(faiss_index != NULL){
            // searching...
            clock_gettime(CLOCK_REALTIME,&annsSearchStart);
            // index->search(nq, dFilter[i].searchVec.data(), k, dis.data(), nns.data());
            faiss_index->search(nq, searchV.data(), k, dis.data(), nns.data());
            clock_gettime(CLOCK_REALTIME,&annsSearchEnd);
            pp->indexSearch += (annsSearchEnd.tv_sec -  annsSearchStart.tv_sec)* BILLION + annsSearchEnd.tv_nsec - annsSearchStart.tv_nsec;
        }
        else if(fileExists(index_path)) {
            printf("[tableScan.cu] Index file exists\n");
            faiss::gpu::StandardGpuResources resources;

            // read faiss index from index_path
            clock_gettime(CLOCK_REALTIME,&readIndexStart);
            faiss::Index *index = faiss::read_index(index_path);
            clock_gettime(CLOCK_REALTIME,&readIndexEnd);
            pp->loadIndex += (readIndexEnd.tv_sec -  readIndexStart.tv_sec)* BILLION + readIndexEnd.tv_nsec - readIndexStart.tv_nsec;

            // index cpu to gpu
            clock_gettime(CLOCK_REALTIME,&cpu2gpuStart);
            index = faiss::gpu::index_cpu_to_gpu(&resources, dev_no, index);
            clock_gettime(CLOCK_REALTIME,&cpu2gpuEnd);
            pp->indexCPU2GPU += (cpu2gpuEnd.tv_sec -  cpu2gpuStart.tv_sec)* BILLION + cpu2gpuEnd.tv_nsec - cpu2gpuStart.tv_nsec;
            
            // add...
            // clock_gettime(CLOCK_REALTIME,&annsAddStart);
            // index->add(feature_num, feature);
            // clock_gettime(CLOCK_REALTIME,&annsAddEnd);
            // pp->indexAddData += (annsAddEnd.tv_sec -  annsAddStart.tv_sec)* BILLION + annsAddEnd.tv_nsec - annsAddStart.tv_nsec;

            // searching...
            clock_gettime(CLOCK_REALTIME,&annsSearchStart);
            // index->search(nq, dFilter[i].searchVec.data(), k, dis.data(), nns.data());
            index->search(nq, searchV.data(), k, dis.data(), nns.data());
            clock_gettime(CLOCK_REALTIME,&annsSearchEnd);
            pp->indexSearch += (annsSearchEnd.tv_sec -  annsSearchStart.tv_sec)* BILLION + annsSearchEnd.tv_nsec - annsSearchStart.tv_nsec;
        }
        else
        {
            printf("[tableScan.cu] Index doesn't exists\n");
            
            // train index
            printf("Train faiss index\n");
            printf("feature_num = %ld\n", feature_num);
            printf("dn->tn->attrSize[%d] = %d\n", disColIndex, sn->tn->attrSize[disColIndex]);
            int d = sn->tn->attrSize[disColIndex] / sizeof(float);
            printf("dimensions = %d\n", d);
            size_t nb = feature_num;
            printf("disColIndex = %d\n", disColIndex);
            int ncentroids = 16384;
            printf("Initial faiss member parameters\n");
            faiss::gpu::StandardGpuResources resources;
            faiss::gpu::GpuIndexIVFPQConfig config;
            config.device = dev_no;
            int m = 16;
            faiss::gpu::GpuIndexIVFPQ index(&resources, d, ncentroids, m, 8, faiss::METRIC_L2, config);
            index.nprobe = 512;

            double t0 = elapsed();
            printf(" Generating %ld vectors in %dD for training\n", nb, d);

            // train index
            struct timespec trainStart, trainEnd;
            clock_gettime(CLOCK_REALTIME,&trainStart);
            index.train(feature_num, feature);
            clock_gettime(CLOCK_REALTIME, &trainEnd);
            pp->trainIndex += (trainEnd.tv_sec - trainStart.tv_sec)* BILLION + trainEnd.tv_nsec - trainStart.tv_nsec;

            // add data to index
            clock_gettime(CLOCK_REALTIME,&annsAddStart);
            index.add(feature_num, feature);
            clock_gettime(CLOCK_REALTIME,&annsAddEnd);
            pp->indexAddData += (annsAddEnd.tv_sec -  annsAddStart.tv_sec)* BILLION + annsAddEnd.tv_nsec - annsAddStart.tv_nsec;

            // save index
            struct timespec saveStart,saveEnd;
            clock_gettime(CLOCK_REALTIME,&saveStart);
            write_index(faiss::gpu::index_gpu_to_cpu(&index), index_path);
            clock_gettime(CLOCK_REALTIME, &saveEnd);
            pp->saveIndex += (saveEnd.tv_sec - saveStart.tv_sec)* BILLION + saveEnd.tv_nsec - saveStart.tv_nsec;
            
            // searching...
            clock_gettime(CLOCK_REALTIME,&annsSearchStart);
            // index.search(nq, dFilter[i].searchVec.data(), k, dis.data(), nns.data());
            index.search(nq, searchV.data(), k, dis.data(), nns.data());
            clock_gettime(CLOCK_REALTIME,&annsSearchEnd);
            pp->indexSearch += (annsSearchEnd.tv_sec -  annsSearchStart.tv_sec)* BILLION + annsSearchEnd.tv_nsec - annsSearchStart.tv_nsec;
        }

        // anns end
        clock_gettime(CLOCK_REALTIME,&annsEnd);
        pp->annsTotalTime += (annsEnd.tv_sec -  annsStart.tv_sec)* BILLION + annsEnd.tv_nsec - annsStart.tv_nsec;

        // for(int j = 0; j < nns.size(); j++){
        //     globalFilter[nns[j]] = 1;
        //     // printf("nns[%d] = %d\n", j, nns[j]);
        // }
        size_t* nns_dev;
        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&nns_dev, sizeof(size_t) * k));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(nns_dev, nns.data(), sizeof(size_t)*k, cudaMemcpyHostToDevice));
        // setFilter<<<1024, 1024>>>(globalFilter, nns_dev, k);
        const int blockSize = 256;
        const int gridSize = (sn->tn->tupleNum + blockSize - 1) / blockSize;
        setZeroKernel<<<gridSize, blockSize>>>(globalFilter, sn->tn->tupleNum);
        const int gridSizeForNNS = (k + blockSize - 1) / blockSize;
        setIndicesKernel<<<gridSizeForNNS, blockSize>>>(globalFilter, nns_dev, k);
        has_globalFilter = 1;

        // save filter[] in dFilter
        // dFilter[i].filter = (int*)malloc(sizeof(int) * sn->tn->tupleNum);
        // memcpy(dFilter[i].filter, filter.data(), sizeof(int) * sn->tn->tupleNum);
        
        // globalFilter &= filter
        // std::transform(globalFilter.begin(), globalFilter.end(), filter.begin(), globalFilter.begin(), [](int a, int b) {
        //     return a & b;
        // });
        // globalFilter = andVectors(globalFilter, filter);

        // reset filter to 0
        // std::fill(filter.begin(), filter.end(), 0);
    }

    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME,&e);
    tt = (e.tv_sec - s.tv_sec)* BILLION + e.tv_nsec - s.tv_nsec;
    printf("tt1 = %f\n", tt/(1000*1000));
    clock_gettime(CLOCK_REALTIME,&s);

    /**
     * now we have distance filter : globalFilter
     * next get where filter and fuse all filters 
     **/


    //Start timer for Other - 01 (tableScan)
    struct timespec startS01,endS01;
    clock_gettime(CLOCK_REALTIME,&startS01);

    struct tableNode *res = NULL;
    int tupleSize = 0;

    if(host_mp == NULL){
        res = (struct tableNode *) malloc(sizeof(struct tableNode));
        CHECK_POINTER(res);
    }else
        res = (struct tableNode *) host_mp->alloc(sizeof(struct tableNode));

    res->totalAttr = sn->outputNum;
    // printf("\nsn->outputNum = %d\n", sn->outputNum);

    if(host_mp == NULL) {
        res->attrType = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->attrType);
        res->attrSize = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->attrSize);
        res->attrTotalSize = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->attrTotalSize);
        res->attrIndex = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->attrIndex);
        res->dataPos = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->dataPos);
        res->dataFormat = (int *) malloc(sizeof(int) * res->totalAttr);
        CHECK_POINTER(res->dataFormat);
        res->content = (char **) malloc(sizeof(char *) * res->totalAttr);
        CHECK_POINTER(res->content);
    }else{
        res->attrType = (int *) host_mp->alloc(sizeof(int) * res->totalAttr);
        res->attrSize = (int *) host_mp->alloc(sizeof(int) * res->totalAttr);
        res->attrTotalSize = (int *) host_mp->alloc(sizeof(int) * res->totalAttr);
        res->attrIndex = (int *) host_mp->alloc(sizeof(int) * res->totalAttr);
        res->dataPos = (int *) host_mp->alloc(sizeof(int) * res->totalAttr);
        res->dataFormat = (int *) host_mp->alloc(sizeof(int) * res->totalAttr);
        res->content = (char **) host_mp->alloc(sizeof(char *) * res->totalAttr);
    }

    res->colIdxNum = 0;

    for(int i=0;i<res->totalAttr;i++){
        int index = sn->outputIndex[i];
        res->attrType[i] = sn->tn->attrType[index];
        res->attrSize[i] = sn->tn->attrSize[index];
        // printf("res->attrSize[%d] = %d\n", i, res->attrSize[i]);
    }

    int *gpuCount = NULL, *gpuFilter = NULL, *gpuPsum = NULL;

    dim3 grid(2048);
    dim3 block(256);

    long totalTupleNum = sn->tn->tupleNum;
    // printf("[InputTable] tupleNum = %ld\n", totalTupleNum);
    int blockNum = totalTupleNum / block.x + 1;

    if(blockNum<2048)
        grid = blockNum;

    if(idx != NULL) {
        int h_st, h_ed;
        CUDA_SAFE_CALL( cudaMemcpy(&h_st, st, sizeof(int), cudaMemcpyDeviceToHost) );
        CUDA_SAFE_CALL( cudaMemcpy(&h_ed, ed, sizeof(int), cudaMemcpyDeviceToHost) );
        CUDA_SAFE_CALL_NO_SYNC(cudaDeviceSynchronize());
        grid = (h_ed - h_st) / block.x + 1;
    }

    int threadNum = grid.x * block.x;
    int attrNum = 0;
    if(sn->filter != NULL and sn->hasWhere != 0)
        attrNum = sn->whereAttrNum;

    char **column;
    int *whereFree, *colWherePos;
    int count;
    if(host_mp == NULL){
        // printf("attrNum = %d\n", attrNum);
        column = (char **) malloc(attrNum * sizeof(char *));
        // printf("Breakpoint\n");
        CHECK_POINTER(column);
        // printf("Breakpoint\n");

        whereFree = (int *)malloc(attrNum * sizeof(int));
        CHECK_POINTER(whereFree);

        colWherePos = (int *)malloc(sn->outputNum * sizeof(int));
        CHECK_POINTER(colWherePos);
    }else{
        column = (char **)host_mp->alloc(attrNum * sizeof(char *));
        whereFree = (int *)host_mp->alloc(attrNum * sizeof(int));
        colWherePos = (int *)host_mp->alloc(sn->outputNum * sizeof(int));
    }

    if(sn->filter != NULL and sn->hasWhere != 0){
        printf("sn->hasWhere != 0\n");
        for(int i=0;i<sn->outputNum;i++)
            colWherePos[i] = -1;

        for(int i=0;i<attrNum;i++){
            whereFree[i] = 1;
            for(int j=0;j<sn->outputNum;j++){
                if(sn->whereIndex[i] == sn->outputIndex[j]){
                    whereFree[i] = -1;
                    colWherePos[j] = i;
                }
            }
        }


        if(dev_mp == NULL){
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuFilter,sizeof(int) * totalTupleNum));
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpuPsum,sizeof(int)*threadNum));
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpuCount,sizeof(int)*threadNum));
        }else{
            gpuFilter = (int *) dev_mp->alloc(sizeof(int) * totalTupleNum);
            gpuPsum   = (int *) dev_mp->alloc(sizeof(int) * threadNum);
            gpuCount  = (int *) dev_mp->alloc(sizeof(int) * threadNum);
        }
    }

    // assert(sn->hasWhere !=0);
    // assert(sn->filter != NULL);
    struct whereCondition *where = sn->filter;

    //Stop timer for Other - 01 (tableScan)
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS01);
    pp->create_tableNode_S01 += (endS01.tv_sec - startS01.tv_sec)* BILLION + endS01.tv_nsec - startS01.tv_nsec;
    //Keeps index col pos
    int idxPos = -1;

    /*
     * The first step is to evaluate the selection predicates and generate a vetor to form the final results.
    */
    if(sn->filter != NULL and sn->hasWhere != 0){
        printf("sn->filter != NULL and sn->hasWhere != 0\n");

        //Start timer for Step 1 - Copy where clause 
        struct timespec startS1, endS1;
        clock_gettime(CLOCK_REALTIME,&startS1);

        struct whereExp * gpuExp = NULL;
        // printf("gpuExp address: %p\n", &gpuExp);
        
        // if(dev_mp == NULL)
        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuExp, sizeof(struct whereExp)));
        // else
        //     gpuExp = (struct whereExp *) dev_mp->alloc(sizeof(struct whereExp));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuExp, &where->exp[0], sizeof(struct whereExp), cudaMemcpyHostToDevice));
        // printf("gpuExp pointer address: %p\n", gpuExp);
        /*
         * Currently we evaluate the predicate one by one.
         * When consecutive predicates are accessing the same column, we don't release the GPU device memory
         * that store the accessed column until all these predicates have been evaluated. Otherwise the device
         * memory will be released immediately after the corresponding predicate has been evaluated.
         *
         * (@whereIndex, @prevWhere), (@index,  @prevIndex), (@format, @prevFormat) are used to decide
         * whether two consecutive predicates access the same column with the same format.
         */

        int whereIndex = where->exp[0].index;
        int index = sn->whereIndex[whereIndex];
        int prevWhere = whereIndex;
        int prevIndex = index;

        int format = sn->tn->dataFormat[index];
        int prevFormat = format;

        if( (where->exp[0].relation == EQ_VEC || where->exp[0].relation == NOT_EQ_VEC || where->exp[0].relation == GTH_VEC || where->exp[0].relation == LTH_VEC || where->exp[0].relation == GEQ_VEC || where->exp[0].relation == LEQ_VEC) &&
            (where->exp[0].dataPos == MEM || where->exp[0].dataPos == MMAP || where->exp[0].dataPos == PINNED) )
        {
            char vec_addr_g[32];
            size_t vec_size = sn->tn->attrSize[index] * sn->tn->tupleNum;
            CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) vec_addr_g, vec_size) );
            CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy(*((void **)vec_addr_g), *((void **) where->exp[0].content), vec_size, cudaMemcpyHostToDevice) );

            /* free memory here? */
            free( *((void **) where->exp[0].content) );
            memcpy(where->exp[0].content, vec_addr_g, 32);
            where->exp[0].dataPos = GPU;
        }

        if( (where->exp[0].relation == IN || where->exp[0].relation == LIKE) &&
            (where->exp[0].dataPos == MEM || where->exp[0].dataPos == MMAP || where->exp[0].dataPos == PINNED) )
        {
            char vec_addr_g[32];
            size_t vec_size = sn->tn->attrSize[index] * where->exp[0].vlen;
            CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) vec_addr_g, vec_size) );
            CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy(*((void **)vec_addr_g), *((void **) where->exp[0].content), vec_size, cudaMemcpyHostToDevice) );

            free( *((void **) where->exp[0].content) );
            memcpy(where->exp[0].content, vec_addr_g, 32);
            where->exp[0].dataPos = GPU;
        }

        if( where->exp[0].relation == IN_VEC &&
            (where->exp[0].dataPos == MEM || where->exp[0].dataPos == MMAP || where->exp[0].dataPos == PINNED) )
        {
            // char vec_addr_g[32];
            // size_t vec1_size = sizeof(void *) * sn->tn->tupleNum;
            // void **vec1_addrs = (void **)malloc(vec1_size);
            // for(int i = 0; i < sn->tn->tupleNum; i++) {
            //     // [int: vec_len][char *: string1][char *: string2] ...
            //     size_t vec2_size = *((*(int ***)(where->exp[0].content))[i]) * sn->tn->attrSize[index] + sizeof(int);
            //     CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) &vec1_addrs[i], vec2_size) );
            //     CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy( vec1_addrs[i], (*(char ***)where->exp[0].content)[i], vec2_size, cudaMemcpyHostToDevice) );
            //     free( (*(char ***)where->exp[0].content)[i] );
            // }
            // CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) vec_addr_g, vec1_size) );
            // CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy(*((void **)vec_addr_g), vec1_addrs, vec1_size, cudaMemcpyHostToDevice) );
            // free(vec1_addrs);

            // free(*(char ***)where->exp[0].content);
            // memcpy(where->exp[0].content, vec_addr_g, 32);
            // where->exp[0].dataPos = GPU;


            clock_gettime(CLOCK_REALTIME,&e);
            tt = (e.tv_sec - s.tv_sec)* BILLION + e.tv_nsec - s.tv_nsec;
            printf("tt1.1 = %f\n", tt/(1000*1000));
            clock_gettime(CLOCK_REALTIME,&s);
            printf("[IN_VEC0]\n");
            // char vec_addr_g[32];
            // size_t vec1_size = sizeof(void *);
            // printf("[IN_VEC0]vec1_size = %ld\n", vec1_size);
            // void **vec1_addrs = (void **)malloc(vec1_size);
            // printf("index = %d\n", index);
            // size_t vec2_size = *((*(int ***)(where->exp[0].content))[0]) * sn->tn->attrSize[index] + sizeof(int);
            // size_t vec2_size = *((*(int ***)(where->exp[0].content))[0]) * sn->tn->attrSize[index];
            

            // distinct
            std::unordered_set<std::string> uniqueElements;
            int dataSize = sn->tn->attrSize[index]; // 每个元素的大小
            int numElements = *((*(int ***)(where->exp[0].content))[0]);
            printf("numElements = %d\n", numElements);
            char *data = (*(char ***)where->exp[0].content)[0] + 4;
            
            for (int i = 0; i < numElements; ++i) {
                // 计算当前元素的起始位置
                int elementStart = i * dataSize;
                
                // 从 binaryData 中提取当前元素的数据
                std::string elementData(data + elementStart, dataSize);

                // 如果数据不在哈希集中，添加它
                if (uniqueElements.find(elementData) == uniqueElements.end()) {
                    uniqueElements.insert(elementData);
                }
            }

            where->exp[0].num = uniqueElements.size();
            printf("where->exp[0].num = %d\n", where->exp[0].num);
            // where->exp[0].num = *((*(int ***)(where->exp[0].content))[0]);

            // for (const std::string& element : uniqueElements) {
            //     std::cout << element << std::endl;
            // }
            std::vector<std::string> setVector(uniqueElements.begin(), uniqueElements.end());
            for (size_t i = 0; i < setVector.size(); ++i) {
                std::cout << setVector[i] << "\n";
            }

            std::string concatenatedStrings;
            for (const auto& str : uniqueElements) {
                concatenatedStrings += str;
            }

            size_t elementsSize = setVector.size() * dataSize;
            printf("elementsSize =%ld\n", elementsSize);
            CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) &(where->exp[0].column), elementsSize));
            CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy( where->exp[0].column, concatenatedStrings.data(), elementsSize, cudaMemcpyHostToDevice) );
            // char* host_string = (char*)malloc(2415);
            // cudaMemcpy(host_string, where->exp[0].column, elementsSize, cudaMemcpyDeviceToHost);
            // for(int i = 0; i < 2415; i++){
            //     printf("%c", host_string[i]);
            // }
            // printf("\n");

            where->exp[0].dataPos = GPU;
            
            // add new grammar
            // CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) &(where->exp[0].column), vec2_size) );
            // CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy( where->exp[0].column, (*(char ***)where->exp[0].content)[0] + 4, vec2_size, cudaMemcpyHostToDevice) );

            // printf("[IN_VEC0]vec2_size = %ld\n", vec2_size);
            // CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) &vec1_addrs[0], vec2_size) );
            // CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy( vec1_addrs[0], (*(char ***)where->exp[0].content)[0], vec2_size, cudaMemcpyHostToDevice) );
            // free( (*(char ***)where->exp[0].content)[0] );
            
            // CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) vec_addr_g, vec1_size) );
            // CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy(*((void **)vec_addr_g), vec1_addrs, vec1_size, cudaMemcpyHostToDevice) );
            // printf("vec1_addrs address: %p\n", &(vec1_addrs));
            // printf("vec1_addrs point address: %p\n", vec1_addrs);
            // printf("vec1_addrs point address: %p\n", vec1_addrs[0]);
            // free(vec1_addrs);

            // free(*(char ***)where->exp[0].content);
            // memcpy(where->exp[0].content, vec_addr_g, 32);
            // printf("content address: %p\n", where->exp[0].content);
            // char *addr;
            // memcpy(&addr, where->exp[0].content, sizeof(char *));
            // printf("address: %p\n", addr);
            // char **g_addr;
            // memcpy(&g_addr, vec_addr_g, sizeof(char **));
            // // printf("g_addr: %p\n", g_addr);
            // printf("g_addr p: %p\n",*g_addr);
            // printf("content point address: %p\n", (*(int ***)where->exp[0].content));
            // int vlen;
            // cudaMemcpy(&vlen, *(int**)g_addr, sizeof(int), cudaMemcpyDeviceToHost);
            // printf("vlen = %d\n", vlen);
            
        }

        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuExp, &where->exp[0], sizeof(struct whereExp), cudaMemcpyHostToDevice));

        //Stop for Step 1 - Copy where clause 
        CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
        clock_gettime(CLOCK_REALTIME, &endS1);
        pp->whereMemCopy_s1 += (endS1.tv_sec - startS1.tv_sec)* BILLION + endS1.tv_nsec - startS1.tv_nsec;
                 
       /*   
         * @dNum, @byteNum and @gpuDictFilter are for predicates that need to access dictionary-compressed columns.
         */
        int dNum;
        int byteNum;
        int *gpuDictFilter = NULL;

        /*
         * We will allocate GPU device memory for a column if it is stored in the host pageable or pinned memory.
         * If it is configured to utilize the UVA technique, no GPU device memory will be allocated.
         */

        if(sn->tn->dataPos[index] == MEM || sn->tn->dataPos[index] == MMAP || sn->tn->dataPos[index] == PINNED)
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **) &column[whereIndex], sn->tn->attrTotalSize[index]));

        if(format == UNCOMPRESSED){
            
            //Start timer for Step 2 - Copy data
            struct timespec startS2, endS2;
            clock_gettime(CLOCK_REALTIME,&startS2);

            if(sn->tn->dataPos[index] == MEM || sn->tn->dataPos[index] == MMAP || sn->tn->dataPos[index] == PINNED)
                CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(column[whereIndex], sn->tn->content[index], sn->tn->attrTotalSize[index], cudaMemcpyHostToDevice));
            else if (sn->tn->dataPos[index] == UVA || sn->tn->dataPos[index] == GPU)
                column[whereIndex] = sn->tn->content[index];

            //Stop timer for Step 2 - Copy data
            CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
            clock_gettime(CLOCK_REALTIME, &endS2);
            pp->dataMemCopy_s2 += (endS2.tv_sec - startS2.tv_sec)* BILLION + endS2.tv_nsec - startS2.tv_nsec;
                
            // printf("BreakPoint\n");

            int rel = where->exp[0].relation;
            printf("rel =%d\n", rel);
            if(sn->tn->attrType[index] == INT){
                int whereValue;
                int *whereVec;
                if(rel == EQ || rel == NOT_EQ || rel == GTH || rel == LTH || rel == GEQ || rel == LEQ)
                    whereValue = *((int*) where->exp[0].content);
                else
                    whereVec = *((int **) where->exp[0].content);

                if(rel==EQ){
                    //Check if this column is indexed
                    if (sn->tn->colIdxNum != 0){
                        for (int k=0; k<sn->tn->colIdxNum; k++){
                            if (sn->tn->colIdx[k] == index){
                                idxPos = k; 
                            }
                        }
                    }

                    //Start timer for Step 3 - Scan
                    struct timespec startS3, endS3;
                    clock_gettime(CLOCK_REALTIME,&startS3);
                    
                    // if (idxPos >= 0){

                        //Regular scan
                        //genScanFilter_init_int_eq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);

                        //Index scan!
                        // res->tupleNum = indexScanInt(sn->tn, index, idxPos, whereValue, gpuFilter, pp);
                        
                        /* DEBUG CODE - DO NOT REMOVE FOR NOW */
                        // int* originalRes = (int *)malloc(sizeof(int) * totalTupleNum);
                        // CHECK_POINTER(originalRes); 
                        // CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(originalRes, gpuFilter, sizeof(int) * totalTupleNum, cudaMemcpyDeviceToHost));
                        // printf("This is what is being returned by serial scan:\n");
                        // for (int i=0;i<totalTupleNum;i++){
                        //     if (originalRes[i] != 0 ){
                        //         printf ("Value[%d]: %d \n",i,originalRes[i]);
                        //     }
                        // }
                        // free(originalRes);
                    if(idx != NULL){
                        genScanFilter_init_int_eq_idx<<<grid, block>>>(column[whereIndex], idx, st, ed, whereValue, gpuFilter);
                    }else{
                        genScanFilter_init_int_eq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                    }

                    //Stop timer for Step 3 - Scan
                    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
                    clock_gettime(CLOCK_REALTIME, &endS3);
                    pp->scanTotal_s3 += (endS3.tv_sec - startS3.tv_sec)* BILLION + endS3.tv_nsec - startS3.tv_nsec;

                }else if(rel == NOT_EQ)
                    genScanFilter_init_int_neq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if(rel == GTH)
                    genScanFilter_init_int_gth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if(rel == LTH)
                    genScanFilter_init_int_lth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if(rel == GEQ)
                    genScanFilter_init_int_geq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if (rel == LEQ)
                    genScanFilter_init_int_leq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if (rel == EQ_VEC)
                    genScanFilter_init_int_eq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if (rel == NOT_EQ_VEC)
                    genScanFilter_init_int_neq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if (rel == GTH_VEC)
                    genScanFilter_init_int_gth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if (rel == LTH_VEC)
                    genScanFilter_init_int_lth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if (rel == GEQ_VEC)
                    genScanFilter_init_int_geq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if (rel == LEQ_VEC)
                    genScanFilter_init_int_leq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);

            }else if (sn->tn->attrType[index] == FLOAT){
                // printf("[INFO] FLOAT filter\n");
                float whereValue, *whereVec;
                if(rel == EQ || rel == NOT_EQ || rel == GTH || rel == LTH || rel == GEQ || rel == LEQ){
                    whereValue = *((float*) where->exp[0].content);
                    printf("whereValue = %f\n", whereValue);
                }
                else
                    whereVec = *((float **) where->exp[0].content);

                // parameters for DISTANCE(v1, v2)
                int firstIndex;
                int secondIndex;
                float parameter;
                if(rel == DISTANCE_LTH_VEC){
                    firstIndex = where->exp[0].index;
                    secondIndex = where->exp[0].secondIndex;
                    parameter = where->exp[0].parameter;
                }

                if(rel==EQ)
                    genScanFilter_init_float_eq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if(rel==NOT_EQ)
                    genScanFilter_init_float_neq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if(rel == GTH)
                    genScanFilter_init_float_gth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if(rel == LTH)
                    genScanFilter_init_float_lth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if(rel == GEQ)
                    genScanFilter_init_float_geq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if (rel == LEQ)
                    genScanFilter_init_float_leq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                else if(rel==EQ_VEC)
                    genScanFilter_init_float_eq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if(rel==NOT_EQ_VEC)
                    genScanFilter_init_float_neq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if(rel == GTH_VEC)
                    genScanFilter_init_float_gth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if(rel == LTH_VEC)
                    genScanFilter_init_float_lth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if(rel == GEQ_VEC)
                    genScanFilter_init_float_geq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if (rel == LEQ_VEC)
                    genScanFilter_init_float_leq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                else if(rel == DISTANCE_LTH_VEC){
                    int size = sn->tn->attrSize[firstIndex]/sizeof(float);
                    genScanFilter_and_distance<<<grid,block>>>(column[firstIndex],column[secondIndex], size, totalTupleNum, parameter, gpuFilter);
                }

            }else if (sn->tn->attrType[index] == VECTOR) {
                if(rel == KNN){
                    int k;
                    memcpy(&k, where->exp[0].content, sizeof(int));
                    // get vecPath, load vec
                    readFloatArray(searchV, where->exp[0].videoFeaturePath);
                    // faiss knn search
                    float *feature = (float *)(sn->tn->content[index]);
                    size_t feature_num = (size_t)(sn->tn->tupleNum);
                    // initial index
                    // size_t length = strlen(sn->tn->attrName[i]);
                    char prestr[50] = "../../vector_src/init_vector/";
                    char endstr[50] = "_index.faissindex";
                    char *tmpstr = strcat(prestr, sn->tn->attrName[index]);
                    const char* index_path = strcat( tmpstr, endstr);
                    std::cout << "[tableScan.cu] index path = \"" << index_path << "\"" << std::endl;
                    int dev_no = 0;
                    int nq = searchV.size() * sizeof(float) / sn->tn->attrSize[index];  //query num
                    // for(int i = 0; i < searchV.size(); i++){
                    //     printf("searchV[%d] = %f\n", i, searchV[i]);
                    // }
                    printf("[KNN]search vector num = %d\n", nq);
                    printf("[KNN]search num = %d\n", k);
                    std::vector<faiss::idx_t> nns(k * nq);
                    std::vector<float> dis(k * nq);
                    int disColIndex = index;
                    // if index exist
                    //   read index from desk 
                    // else
                    //   train index and save it

                    // ANNs start
                    clock_gettime(CLOCK_REALTIME, &annsStart);
                    if(faiss_index != NULL){
                        // searching...
                        clock_gettime(CLOCK_REALTIME,&annsSearchStart);
                        // index->search(nq, dFilter[i].searchVec.data(), k, dis.data(), nns.data());
                        faiss_index->search(nq, searchV.data(), k, dis.data(), nns.data());
                        clock_gettime(CLOCK_REALTIME,&annsSearchEnd);
                        pp->indexSearch += (annsSearchEnd.tv_sec -  annsSearchStart.tv_sec)* BILLION + annsSearchEnd.tv_nsec - annsSearchStart.tv_nsec;
                    }
                    else if (fileExists(index_path)) {
                        // printf("[tableScan.cu] Index file exists\n");
                        faiss::gpu::StandardGpuResources resources;

                        // read faiss index from index_path
                        clock_gettime(CLOCK_REALTIME,&readIndexStart);
                        faiss::Index *index = faiss::read_index(index_path);
                        clock_gettime(CLOCK_REALTIME,&readIndexEnd);
                        pp->loadIndex += (readIndexEnd.tv_sec -  readIndexStart.tv_sec)* BILLION + readIndexEnd.tv_nsec - readIndexStart.tv_nsec;
                        
                        clock_gettime(CLOCK_REALTIME,&cpu2gpuStart);
                        index = faiss::gpu::index_cpu_to_gpu(&resources, dev_no, index);
                        clock_gettime(CLOCK_REALTIME,&cpu2gpuEnd);
                        pp->indexCPU2GPU += (cpu2gpuEnd.tv_sec -  cpu2gpuStart.tv_sec)* BILLION + cpu2gpuEnd.tv_nsec - cpu2gpuStart.tv_nsec;
                        
                        // add...
                        // clock_gettime(CLOCK_REALTIME,&annsAddStart);
                        // index->add(feature_num, feature);
                        // clock_gettime(CLOCK_REALTIME,&annsAddEnd);
                        // pp->indexAddData = (annsAddEnd.tv_sec -  annsAddStart.tv_sec)* BILLION + annsAddEnd.tv_nsec - annsAddStart.tv_nsec;
                        
                        // searching...
                        clock_gettime(CLOCK_REALTIME,&annsSearchStart);
                        // index->search(nq, dFilter[i].searchVec.data(), k, dis.data(), nns.data());
                        index->search(nq, searchV.data(), k, dis.data(), nns.data());
                        clock_gettime(CLOCK_REALTIME,&annsSearchEnd);
                        pp->indexSearch += (annsSearchEnd.tv_sec -  annsSearchStart.tv_sec)* BILLION + annsSearchEnd.tv_nsec - annsSearchStart.tv_nsec;
                    }
                    else
                    {
                        // printf("[tableScan.cu] Index doesn't exists\n");
                        
                        // train index
                        // printf("Train faiss index\n");
                        // printf("feature_num = %ld\n", feature_num);
                        // printf("dn->tn->attrSize[%d] = %d\n", disColIndex, sn->tn->attrSize[disColIndex]);
                        int d = sn->tn->attrSize[disColIndex] / sizeof(float);
                        // printf("dimensions = %d\n", d);
                        size_t nb = feature_num;
                        // printf("disColIndex = %d\n", disColIndex);
                        // int ncentroids = int(sqrt(feature_num));
                        int nlist = 16;
                        // printf("Initial faiss member parameters\n");
                        faiss::gpu::StandardGpuResources resources;
                        faiss::gpu::GpuIndexIVFFlatConfig config;
                        config.device = dev_no;
                        faiss::gpu::GpuIndexIVFFlat index(&resources, d, nlist, faiss::METRIC_L2, config);

                        double t0 = elapsed();
                        // printf(" Generating %ld vectors in %dD for training\n", nb, d);

                        // train index
                        struct timespec trainStart, trainEnd;
                        clock_gettime(CLOCK_REALTIME,&trainStart);
                        index.train(feature_num, feature);
                        clock_gettime(CLOCK_REALTIME,&trainEnd);
                        pp->trainIndex += (trainEnd.tv_sec -  trainStart.tv_sec)* BILLION + trainEnd.tv_nsec - trainStart.tv_nsec;
                        

                        // add data to index
                        clock_gettime(CLOCK_REALTIME,&annsAddStart);
                        index.add(feature_num, feature);
                        clock_gettime(CLOCK_REALTIME,&annsAddEnd);
                        pp->indexAddData += (annsAddEnd.tv_sec -  annsAddStart.tv_sec)* BILLION + annsAddEnd.tv_nsec - annsAddStart.tv_nsec;


                        // save index
                        struct timespec saveStart,saveEnd;
                        clock_gettime(CLOCK_REALTIME,&saveStart);
                        write_index(faiss::gpu::index_gpu_to_cpu(&index), index_path);
                        clock_gettime(CLOCK_REALTIME, &saveEnd);
                        pp->saveIndex += (saveEnd.tv_sec - saveStart.tv_sec)* BILLION + saveEnd.tv_nsec - saveStart.tv_nsec;
                        

                        // searching...
                        clock_gettime(CLOCK_REALTIME,&annsSearchStart);
                        // index.search(nq, dFilter[i].searchVec.data(), k, dis.data(), nns.data());
                        index.search(nq, searchV.data(), k, dis.data(), nns.data());
                        clock_gettime(CLOCK_REALTIME,&annsSearchEnd);
                        pp->indexSearch += (annsSearchEnd.tv_sec -  annsSearchStart.tv_sec)* BILLION + annsSearchEnd.tv_nsec - annsSearchStart.tv_nsec;
                    }

                    // for (int i = 0; i < nq; i++) {
                    //     for (int j = 0; j < k; j++) {
                    //         globalFilter[nns[j + i * k]] = 1;
                    //         // printf("nns[%d] = 1\n", j+i*k);
                    //         // printf("index = %d", nns[j + i * k]);
                    //     }
                    // }
                    size_t* nns_dev;
                    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&nns_dev, sizeof(size_t) * nq * k));
                    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(nns_dev, nns.data(), sizeof(size_t) * nq * k, cudaMemcpyHostToDevice));
                    int blockSize = 256;
                    int numBlocks = (totalTupleNum + blockSize - 1) / blockSize;                    
                    setFilter<<<numBlocks, blockSize>>>(globalFilter, nns_dev, nq * k);
                    // CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gFilter, sizeof(int) * sn->tn->tupleNum));
                    has_globalFilter = 1;
                }
            }
            
            else{
                if(rel == EQ)
                    genScanFilter_init_eq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if(rel == NOT_EQ)
                    genScanFilter_init_neq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if (rel == GTH)
                    genScanFilter_init_gth<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if (rel == LTH)
                    genScanFilter_init_lth<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if (rel == GEQ)
                    genScanFilter_init_geq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if (rel == LEQ)
                    genScanFilter_init_leq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if(rel == EQ_VEC)
                    genScanFilter_init_eq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if(rel == NOT_EQ_VEC)
                    genScanFilter_init_neq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if (rel == GTH_VEC)
                    genScanFilter_init_gth_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if (rel == LTH_VEC)
                    genScanFilter_init_lth_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if (rel == GEQ_VEC)
                    genScanFilter_init_geq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if (rel == LEQ_VEC)
                    genScanFilter_init_leq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                else if (rel == IN)
                    genScanFilter_init_in<<<grid, block>>>(column[whereIndex], sn->tn->attrSize[index], totalTupleNum, gpuExp, gpuFilter);
                else if (rel == IN_VEC){
                    printf("sn->tn->attrSize[index] = %d\n", sn->tn->attrSize[index]);
                    printf("whereIndex = %d\n", whereIndex);
                    printf("totalTupleNum = %ld\n", totalTupleNum);
                    clock_gettime(CLOCK_REALTIME,&e);
                    tt = (e.tv_sec - s.tv_sec)* BILLION + e.tv_nsec - s.tv_nsec;
                    printf("tt1.2 = %f\n", tt/(1000*1000));
                    clock_gettime(CLOCK_REALTIME,&s);
                    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
                    genScanFilter_init_in_vec<<<grid, block>>>(column[whereIndex], sn->tn->attrSize[index], totalTupleNum, gpuExp, gpuFilter);
                    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
                }
                else if (rel == LIKE)
                    genScanFilter_init_like<<<grid, block>>>(column[whereIndex], sn->tn->attrSize[index], totalTupleNum, gpuExp, gpuFilter);
            }
        }

        clock_gettime(CLOCK_REALTIME,&e);
        tt = (e.tv_sec - s.tv_sec)* BILLION + e.tv_nsec - s.tv_nsec;
        printf("tt1.3 = %f\n", tt/(1000*1000));
        clock_gettime(CLOCK_REALTIME,&s);

        int dictFilter = 0;
        int dictFinal = OR;
        int dictInit = 1;

        //Start timer for Step 1 - Copy where clause (Part2)
        struct timespec startS12, endS12;
        clock_gettime(CLOCK_REALTIME,&startS12);

        for(int i=1;i<where->expNum;i++){
            whereIndex = where->exp[i].index;
            index = sn->whereIndex[whereIndex];
            format = sn->tn->dataFormat[index];

            // parameters for DISTANCE(v1, v2) < dis
            int firstIndex;
            int secondIndex;
            float parameter;
            if(where->exp[i].relation == DISTANCE_LTH_VEC){
                firstIndex = where->exp[i].index;
                secondIndex = where->exp[i].secondIndex;
                parameter = where->exp[i].parameter;
            }

            if( (where->exp[i].relation == EQ_VEC || where->exp[i].relation == NOT_EQ_VEC || where->exp[i].relation == GTH_VEC || where->exp[i].relation == LTH_VEC || where->exp[i].relation == GEQ_VEC || where->exp[i].relation == LEQ_VEC) &&
                (where->exp[i].dataPos == MEM || where->exp[i].dataPos == MMAP || where->exp[i].dataPos == PINNED) )
            {
                char vec_addr_g[32];
                size_t vec_size = sn->tn->attrSize[index] * sn->tn->tupleNum;
                CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) vec_addr_g, vec_size) );
                CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy(*((void **)vec_addr_g), *((void **) where->exp[i].content), vec_size, cudaMemcpyHostToDevice) );

                free( *((void **) where->exp[i].content) );
                memcpy(where->exp[i].content, vec_addr_g, 32);
                where->exp[i].dataPos = GPU;
            }

            if( (where->exp[i].relation == IN || where->exp[i].relation == LIKE) &&
                (where->exp[i].dataPos == MEM || where->exp[i].dataPos == MMAP || where->exp[i].dataPos == PINNED) )
            {
                char vec_addr_g[32];
                size_t vec_size = sn->tn->attrSize[index] * where->exp[i].vlen;
                CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) vec_addr_g, vec_size) );
                CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy(*((void **)vec_addr_g), *((void **) where->exp[i].content), vec_size, cudaMemcpyHostToDevice) );

                free( *((void **) where->exp[i].content) );
                memcpy(where->exp[i].content, vec_addr_g, 32);
                where->exp[i].dataPos = GPU;
            }

            if( where->exp[i].relation == IN_VEC &&
                (where->exp[i].dataPos == MEM || where->exp[i].dataPos == MMAP || where->exp[i].dataPos == PINNED) )
            {
                char vec_addr_g[32];
                size_t vec1_size = sizeof(void *) * sn->tn->tupleNum;
                void **vec1_addrs = (void **)malloc(vec1_size);
                for(int j = 0; j < sn->tn->tupleNum; j++) {
                    // [int: vec_len][char *: string1][char *: string2] ...
                    size_t vec2_size = *((*(int ***)(where->exp[i].content))[j]) * sn->tn->attrSize[index] + sizeof(int);
                    CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) &vec1_addrs[j], vec2_size) );
                    CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy( vec1_addrs[j], (*(char ***)where->exp[i].content)[j], vec2_size, cudaMemcpyHostToDevice) );
                    free( (*(char ***)where->exp[i].content)[j] );
                }
                CUDA_SAFE_CALL_NO_SYNC( cudaMalloc((void **) vec_addr_g, vec1_size) );
                CUDA_SAFE_CALL_NO_SYNC( cudaMemcpy(*((void **)vec_addr_g), vec1_addrs, vec1_size, cudaMemcpyHostToDevice) );
                free(vec1_addrs);

                free(*(char ***)where->exp[i].content);
                memcpy(where->exp[i].content, vec_addr_g, 32);
                where->exp[i].dataPos = GPU;
            }

            CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuExp, &where->exp[i], sizeof(struct whereExp), cudaMemcpyHostToDevice));

            if(prevIndex != index){

                 /*When the two consecutive predicates access different columns*/

                if(prevFormat == DICT){
                    if(dictInit == 1){
                        transform_dict_filter_init<<<grid,block>>>(gpuDictFilter, column[prevWhere], totalTupleNum, dNum, gpuFilter,byteNum);
                        dictInit = 0;
                    }else if(dictFinal == OR)
                        transform_dict_filter_or<<<grid,block>>>(gpuDictFilter, column[prevWhere], totalTupleNum, dNum, gpuFilter,byteNum);
                    else
                        transform_dict_filter_and<<<grid,block>>>(gpuDictFilter, column[prevWhere], totalTupleNum, dNum, gpuFilter,byteNum);

                    CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuDictFilter));
                    dictFinal = where->andOr;
                }

                if(whereFree[prevWhere] == 1 && (sn->tn->dataPos[prevIndex] == MEM || sn->tn->dataPos[prevIndex] == MMAP || sn->tn->dataPos[prevIndex] == PINNED))
                    CUDA_SAFE_CALL_NO_SYNC(cudaFree(column[prevWhere]));

                if(sn->tn->dataPos[index] == MEM || sn->tn->dataPos[index] == MMAP || sn->tn->dataPos[index] == PINNED)
                    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **) &column[whereIndex] , sn->tn->attrTotalSize[index]));

                if(format == DICT){
                    if(sn->tn->dataPos[index] == MEM || sn->tn->dataPos[index] == MMAP || sn->tn->dataPos[index] == PINNED)
                        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(column[whereIndex], sn->tn->content[index], sn->tn->attrTotalSize[index], cudaMemcpyHostToDevice));
                    else if (sn->tn->dataPos[index] == UVA || sn->tn->dataPos[index] == GPU)
                        column[whereIndex] = sn->tn->content[index];

                    struct dictHeader * dheader = (struct dictHeader *)sn->tn->content[index];
                    dNum = dheader->dictNum;
                    byteNum = dheader->bitNum/8;

                    struct dictHeader * gpuDictHeader = NULL;
                    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuDictHeader,sizeof(struct dictHeader)));
                    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuDictHeader,dheader,sizeof(struct dictHeader), cudaMemcpyHostToDevice));
                    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuDictFilter, dNum * sizeof(int)));

                    genScanFilter_dict_init<<<grid,block>>>(gpuDictHeader,sn->tn->attrSize[index],sn->tn->attrType[index],dNum, gpuExp,gpuDictFilter);
                    dictFilter= -1;
                    CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuDictHeader));

                }else{
                    if(sn->tn->dataPos[index] == MEM || sn->tn->dataPos[index] == MMAP || sn->tn->dataPos[index] == PINNED)
                        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(column[whereIndex], sn->tn->content[index], sn->tn->attrTotalSize[index], cudaMemcpyHostToDevice));
                    else if (sn->tn->dataPos[index] == UVA || sn->tn->dataPos[index] == GPU)
                        column[whereIndex] = sn->tn->content[index];
                }

                prevIndex = index;
                prevWhere = whereIndex;
                prevFormat = format;
            }


            if(format == UNCOMPRESSED){
                int rel = where->exp[i].relation;
                if(sn->tn->attrType[index] == INT){
                    int whereValue;
                    int *whereVec;
                    if(rel == EQ || rel == NOT_EQ || rel == GTH || rel == LTH || rel == GEQ || rel == LEQ)
                        whereValue = *((int*) where->exp[i].content);
                    else
                        whereVec = *((int **) where->exp[i].content);

                    if(where->andOr == AND){
                        if(rel==EQ)
                            genScanFilter_and_int_eq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel==NOT_EQ)
                            genScanFilter_and_int_neq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == GTH)
                            genScanFilter_and_int_gth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == LTH)
                            genScanFilter_and_int_lth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == GEQ)
                            genScanFilter_and_int_geq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if (rel == LEQ)
                            genScanFilter_and_int_leq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel==EQ_VEC)
                            genScanFilter_and_int_eq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel==NOT_EQ_VEC)
                            genScanFilter_and_int_neq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == GTH_VEC)
                            genScanFilter_and_int_gth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == LTH_VEC)
                            genScanFilter_and_int_lth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == GEQ_VEC)
                            genScanFilter_and_int_geq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if (rel == LEQ_VEC)
                            genScanFilter_and_int_leq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                    }else{
                        if(rel==EQ)
                            genScanFilter_or_int_eq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel==NOT_EQ)
                            genScanFilter_or_int_neq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == GTH)
                            genScanFilter_or_int_gth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == LTH)
                            genScanFilter_or_int_lth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == GEQ)
                            genScanFilter_or_int_geq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if (rel == LEQ)
                            genScanFilter_or_int_leq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel==EQ_VEC)
                            genScanFilter_or_int_eq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel==NOT_EQ_VEC)
                            genScanFilter_or_int_neq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == GTH_VEC)
                            genScanFilter_or_int_gth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == LTH_VEC)
                            genScanFilter_or_int_lth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == GEQ_VEC)
                            genScanFilter_or_int_geq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if (rel == LEQ_VEC)
                            genScanFilter_or_int_leq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);

                    }

                } else if (sn->tn->attrType[index] == FLOAT){
                    float whereValue, *whereVec;
                    if(rel == EQ || rel == NOT_EQ || rel == GTH || rel == LTH || rel == GEQ || rel == LEQ)
                        whereValue = *((float*) where->exp[i].content);
                    else
                        whereVec = *((float**) where->exp[i].content);

                    if(where->andOr == AND){
                        if(rel==EQ)
                            genScanFilter_and_float_eq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel==NOT_EQ)
                            genScanFilter_and_float_neq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == GTH)
                            genScanFilter_and_float_gth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == LTH)
                            genScanFilter_and_float_lth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == GEQ)
                            genScanFilter_and_float_geq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if (rel == LEQ)
                            genScanFilter_and_float_leq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel==EQ_VEC)
                            genScanFilter_and_float_eq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel==NOT_EQ_VEC)
                            genScanFilter_and_float_neq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);    
                        else if(rel == GTH_VEC)
                            genScanFilter_and_float_gth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == LTH_VEC)
                            genScanFilter_and_float_lth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == GEQ_VEC)
                            genScanFilter_and_float_geq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if (rel == LEQ_VEC)
                            genScanFilter_and_float_leq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if (rel == DISTANCE_LTH_VEC){
                            int size = sn->tn->attrSize[firstIndex]/sizeof(float);
                            genScanFilter_and_distance<<<grid,block>>>(column[firstIndex],column[secondIndex], size, totalTupleNum, parameter, gpuFilter);
                        }
                    }else if(where->andOr == OR){
                        if(rel==EQ)
                            genScanFilter_or_float_eq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel==NOT_EQ)
                            genScanFilter_or_float_neq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == GTH)
                            genScanFilter_or_float_gth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == LTH)
                            genScanFilter_or_float_lth<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel == GEQ)
                            genScanFilter_or_float_geq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if (rel == LEQ)
                            genScanFilter_or_float_leq<<<grid,block>>>(column[whereIndex],totalTupleNum, whereValue, gpuFilter);
                        else if(rel==EQ_VEC)
                            genScanFilter_or_float_eq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel==NOT_EQ_VEC)
                            genScanFilter_or_float_neq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == GTH_VEC)
                            genScanFilter_or_float_gth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == LTH_VEC)
                            genScanFilter_or_float_lth_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if(rel == GEQ_VEC)
                            genScanFilter_or_float_geq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);
                        else if (rel == LEQ_VEC)
                            genScanFilter_or_float_leq_vec<<<grid,block>>>(column[whereIndex],totalTupleNum, whereVec, gpuFilter);

                    }
                }else{
                    if(where->andOr == AND){
                        if (rel == EQ)
                            genScanFilter_and_eq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == NOT_EQ)
                            genScanFilter_and_neq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == GTH)
                            genScanFilter_and_gth<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == LTH)
                            genScanFilter_and_lth<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == GEQ)
                            genScanFilter_and_geq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == LEQ)
                            genScanFilter_and_leq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == EQ_VEC)
                            genScanFilter_and_eq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == NOT_EQ_VEC)
                            genScanFilter_and_neq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == GTH_VEC)
                            genScanFilter_and_gth_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == LTH_VEC)
                            genScanFilter_and_lth_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == GEQ_VEC)
                            genScanFilter_and_geq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == LEQ_VEC)
                            genScanFilter_and_leq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == IN)
                            genScanFilter_and_in<<<grid, block>>>(column[whereIndex], sn->tn->attrSize[index], totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == IN_VEC)
                            genScanFilter_and_in_vec<<<grid, block>>>(column[whereIndex], sn->tn->attrSize[index], totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == LIKE)
                            genScanFilter_and_like<<<grid, block>>>(column[whereIndex], sn->tn->attrSize[index], totalTupleNum, gpuExp, gpuFilter);
                    }else{
                        if (rel == EQ)
                            genScanFilter_or_eq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == NOT_EQ)
                            genScanFilter_or_neq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == GTH)
                            genScanFilter_or_gth<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == LTH)
                            genScanFilter_or_lth<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == GEQ)
                            genScanFilter_or_geq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == LEQ)
                            genScanFilter_or_leq<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == EQ_VEC)
                            genScanFilter_or_eq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == NOT_EQ_VEC)
                            genScanFilter_or_neq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == GTH_VEC)
                            genScanFilter_or_gth_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == LTH_VEC)
                            genScanFilter_or_lth_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == GEQ_VEC)
                            genScanFilter_or_geq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == LEQ_VEC)
                            genScanFilter_or_leq_vec<<<grid,block>>>(column[whereIndex],sn->tn->attrSize[index],totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == IN)
                            genScanFilter_or_in<<<grid, block>>>(column[whereIndex], sn->tn->attrSize[index], totalTupleNum, gpuExp, gpuFilter);
                        else if (rel == IN_VEC){
                            // printf("sn->tn->attrSize[index] = %d\n", sn->tn->attrSize[index]);
                            genScanFilter_or_in_vec<<<grid, block>>>(column[whereIndex], sn->tn->attrSize[index], totalTupleNum, gpuExp, gpuFilter);
                        }
                        else if (rel == LIKE)
                            genScanFilter_or_like<<<grid, block>>>(column[whereIndex], sn->tn->attrSize[index], totalTupleNum, gpuExp, gpuFilter);
                    }
                }
            }
        }

        //Stop timer for Step 1 - Copy where clause (Part2)
        CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
        clock_gettime(CLOCK_REALTIME, &endS12);
        pp->whereMemCopy_s1 += (endS12.tv_sec - startS12.tv_sec)* BILLION + endS12.tv_nsec - startS12.tv_nsec;            

        if(prevFormat == DICT){
            if (dictInit == 1){
                transform_dict_filter_init<<<grid,block>>>(gpuDictFilter, column[prevWhere], totalTupleNum, dNum, gpuFilter, byteNum);
                dictInit = 0;
            }else if(dictFinal == AND)
                transform_dict_filter_and<<<grid,block>>>(gpuDictFilter, column[prevWhere], totalTupleNum, dNum, gpuFilter, byteNum);
            else
                transform_dict_filter_or<<<grid,block>>>(gpuDictFilter, column[prevWhere], totalTupleNum, dNum, gpuFilter, byteNum);
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuDictFilter));
        }

        if(whereFree[prevWhere] == 1 && (sn->tn->dataPos[prevIndex] == MEM || sn->tn->dataPos[prevIndex] == MMAP || sn->tn->dataPos[prevIndex] == PINNED))
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(column[prevWhere]));

        if(dev_mp == NULL)
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuExp));

    }

    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME,&e);
    tt = (e.tv_sec - s.tv_sec)* BILLION + e.tv_nsec - s.tv_nsec;
    printf("tt2 = %f\n", tt/(1000*1000));
    clock_gettime(CLOCK_REALTIME,&s);


    //Start timer for Step 4 - Count result (PreScan)
    struct timespec startS4, endS4;
    clock_gettime(CLOCK_REALTIME,&startS4);


    // int cntgf = 0;
    // for(int i = 0; i < globalFilter.size(); i++) {
    //     if(globalFilter[i] == 1){
    //         // printf("globalFilter[%d] = 1\n", i);
    //         cntgf += 1;
    //     }
    // }
    // printf("[globalFilter] there are %d tuples to be choosen\n", cntgf);
    
    // if we have where exp, gpuFilter is not NULL
    // we need to AND gpuFilter/globalFilter
    if(gpuFilter != NULL and has_globalFilter == 1){
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuFilter, globalFilter, sizeof(int) * totalTupleNum, cudaMemcpyDeviceToDevice));
    }
    else if(gpuFilter != NULL){
        ;
    }
    else { // else, initial gpuFilter and copy globalFilter to gpuFilter
        if(dev_mp == NULL){
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&gpuFilter,sizeof(int) * totalTupleNum));
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpuPsum,sizeof(int)*threadNum));
            CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void**)&gpuCount,sizeof(int)*threadNum));
        }else{
            gpuFilter = (int *) dev_mp->alloc(sizeof(int) * totalTupleNum);
            gpuPsum   = (int *) dev_mp->alloc(sizeof(int) * threadNum);
            gpuCount  = (int *) dev_mp->alloc(sizeof(int) * threadNum);
        }
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuFilter, globalFilter, sizeof(int) * totalTupleNum, cudaMemcpyDeviceToDevice));
        // printf("[tableScan] no where clause, copy globalFilter to gpuFilter\n\n");
    }

    /* --Optimization Note--
    * We cannot remove this one even if we know the number of selected tuples
    * because counts the tuples per thread (not only total number)
    */

    /* 
    * Count the number of tuples that meets the predicats for each thread
    * and calculate the prefix sum.
    */

    //Start timer for Count Step 4.1 - Count selected rows kernels
    struct timespec startCountS1, endCountS1;
    clock_gettime(CLOCK_REALTIME,&startCountS1);

    // countScanNum<<<grid,block>>>(gpuFilter,totalTupleNum,gpuCount);

    //Stop timer for Count Step 4.1 - Count selected rows kernels


    if(idx == NULL)
        countScanNum<<<grid,block>>>(gpuFilter,totalTupleNum,gpuCount);
    else{
        countScanNum_idx<<<grid, block>>>(gpuFilter, idx, st, ed, gpuCount);
    }
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endCountS1);
    pp->countScanKernel_countS1 += (endCountS1.tv_sec - startCountS1.tv_sec)* BILLION + endCountS1.tv_nsec - startCountS1.tv_nsec;

    //Start timer for Count Step 4.2 - scanImpl time
    struct timespec startCountS2, endCountS2;
    clock_gettime(CLOCK_REALTIME,&startCountS2);
    scanImpl(gpuCount,threadNum, gpuPsum, pp);

    // int * testPsum = (int*)malloc(sizeof(int) * threadNum);
    // cudaMemcpy(testPsum, gpuPsum, sizeof(int) * threadNum, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < threadNum; i++){
    //     printf("gpuPsum[%d] = %d", i, testPsum[i]);
    // }

    //Stop timer for Count Step 4.2 - scanImpl time
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endCountS2);
    pp->scanImpl_countS2 += (endCountS2.tv_sec - startCountS2.tv_sec)* BILLION + endCountS2.tv_nsec - startCountS2.tv_nsec;

    //Stop timer for Step 4 - Count result (PreScan)
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS4);
    pp->preScanTotal_s4 += (endS4.tv_sec -  startS4.tv_sec)* BILLION + endS4.tv_nsec - startS4.tv_nsec;
    pp->preScanCount_s4++;

    int tmp1, tmp2;

    //Start timer for Step 5 - Count result (PreScan)
    struct timespec startS5, endS5;
    clock_gettime(CLOCK_REALTIME,&startS5);

    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(&tmp1, &gpuCount[threadNum-1], sizeof(int), cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(&tmp2, &gpuPsum[threadNum-1], sizeof(int), cudaMemcpyDeviceToHost));    
    count = tmp1+tmp2;
    printf("[tableScan] count = %d\n", count);
    
    if(disTwoColProject != 0)
        count = totalTupleNum;
    res->tupleNum = count;

    

    //End timer for Step 5 - Count result (PreScan)
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS5);
    pp->preScanResultMemCopy_s5 += (endS5.tv_sec -  startS5.tv_sec)* BILLION + endS5.tv_nsec - startS5.tv_nsec;
    
    //Start timer for Other - 02 (mallocRes)
    struct timespec startS02,endS02;
    clock_gettime(CLOCK_REALTIME,&startS02);

    if(dev_mp == NULL)
        CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuCount));

    char **result = NULL, **scanCol = NULL;

    attrNum = sn->outputNum;

    if(host_mp == NULL){
        scanCol = (char **) malloc(attrNum * sizeof(char *));
        CHECK_POINTER(scanCol);
        result = (char **) malloc(attrNum * sizeof(char *));
        CHECK_POINTER(result);
    }else{
        scanCol = (char **)host_mp->alloc(attrNum * sizeof(char *));
        result = (char **)host_mp->alloc(attrNum * sizeof(char *));
    }

    //Stop timer for Other - 02 (mallocRes)
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS02);
    pp->mallocRes_S02 += (endS02.tv_sec - startS02.tv_sec)* BILLION + endS02.tv_nsec - startS02.tv_nsec;

    //Start timer for Step 6 - Copy to device all other columns
    struct timespec startS6, endS6;
    clock_gettime(CLOCK_REALTIME,&startS6);

    // printf("[tableScan] attrNum = %d\n", attrNum);
    
    if(sn->filter != NULL and sn->hasWhere != 0){
        // printf("sn->hasWhere != NULL and sn->hasWhere != 0\n");
        for(int i=0;i<attrNum;i++){

            int pos = colWherePos[i];
            int index = sn->outputIndex[i];
            tupleSize += sn->tn->attrSize[index];

            if(pos != -1){
                scanCol[i] = column[pos];
            }else{
                if(sn->tn->dataPos[index] == MEM || sn->tn->dataPos[index] == MMAP || sn->tn->dataPos[index] == PINNED)
                    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **) &scanCol[i] , sn->tn->attrTotalSize[index]));

                if(sn->tn->dataFormat[index] != DICT){
                    if(sn->tn->dataPos[index] == MEM || sn->tn->dataPos[index] == MMAP || sn->tn->dataPos[index] == PINNED){
                        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(scanCol[i], sn->tn->content[index], sn->tn->attrTotalSize[index], cudaMemcpyHostToDevice));
                    }
                    else
                        scanCol[i] = sn->tn->content[index];

                }else{
                    if(sn->tn->dataPos[index] == MEM || sn->tn->dataPos[index] == MMAP || sn->tn->dataPos[index] == PINNED){
                        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(scanCol[i], sn->tn->content[index], sn->tn->attrTotalSize[index], cudaMemcpyHostToDevice));
                    }
                    else
                        scanCol[i] = sn->tn->content[index];
                }
            }

            if(res_mp == NULL)
                CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **) &result[i], count * sn->tn->attrSize[index]));
            else
                result[i] = (char *) res_mp->alloc(count * sn->tn->attrSize[index]);
        }
    }
    else{
        // printf("[Info] there is no where clause\n");
        int index = 0;
        for(int i=0;i<attrNum;i++){
            if(i < sn->outputNum){
                index = sn->outputIndex[i];
                // printf("index = %d, attrSize = %d\n", sn->outputIndex[i], sn->tn->attrSize[index]);
            } else {
                index = dTwoCol[0].secondColIndex;
            }
            
            // printf("outputIndex[%d] = %d, attrSize = %d\n", i, index, sn->tn->attrSize[index]);
            tupleSize += sn->tn->attrSize[index];
            // printf("tupleSize = %d\n", tupleSize);

            if(sn->tn->dataPos[index] == MEM || sn->tn->dataPos[index] == MMAP || sn->tn->dataPos[index] == PINNED){
                // printf("copy data from host to device\n");
                // printf("sn->tn->attrTotalSize[%d] = %d\n", index, sn->tn->attrTotalSize[index]);
                CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **) &scanCol[i] , sn->tn->attrTotalSize[index]));
                // printf("Breakpoint\n");
                CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(scanCol[i], sn->tn->content[index], sn->tn->attrTotalSize[index], cudaMemcpyHostToDevice));
                // printf("attrTotalSize[%d] = %d\n", index, sn->tn->attrTotalSize[index]);
                // printf("totalTupleNum[%ld] = %d\n", index, totalTupleNum);
                // printf("\n");
                // if(sn->tn->attrType[index] == VECTOR){
                //     float *data = (float*)(sn->tn->content[index]);
                //     for(int i = 0; i < 128; ++i){
                //         printf("data[%d] = %f\n", i, data[i]);
                //     }
                // }
            }
            else
                scanCol[i] = sn->tn->content[index];

            // printf("count = %d\n", count);
            if(res_mp == NULL)
                CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **) &result[i], count * sn->tn->attrSize[index]));
            else
                result[i] = (char *) res_mp->alloc(count * sn->tn->attrSize[index]);
        }
    }
    //End timer for Step 6 - Copy to device all other columns
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS6);
    pp->dataMemCopyOther_s6 += (endS6.tv_sec -  startS6.tv_sec)* BILLION + endS6.tv_nsec - startS6.tv_nsec;

    //Start timer for Step 7 - Materialize result
    struct timespec startS7, endS7;
    clock_gettime(CLOCK_REALTIME,&startS7);

    if(sn->filter != NULL or count != totalTupleNum){
        // printf("[Info] scan column\n");
        // printf("attrNum = %d\n", attrNum);
        for(int i=0; i<attrNum; i++){
            int index = sn->outputIndex[i];
            int format = sn->tn->dataFormat[index];
            if(format == UNCOMPRESSED){
                if (sn->tn->attrSize[index] == sizeof(int)){
                    if(idx == NULL)
                        scan_int<<<grid,block>>>(scanCol[i], sn->tn->attrSize[index], totalTupleNum, gpuPsum, count, gpuFilter, result[i]);
                    else
                        scan_int_idx<<<grid,block>>>(scanCol[i], sn->tn->attrSize[index], idx, st, ed, gpuPsum, count, gpuFilter, result[i]);
                }else{
                    if(idx == NULL)
                        scan_other<<<grid,block>>>(scanCol[i], sn->tn->attrSize[index], totalTupleNum,gpuPsum, count, gpuFilter,result[i]);
                    else
                        scan_other_idx<<<grid,block>>>(scanCol[i], sn->tn->attrSize[index], idx, st, ed, gpuPsum, count, gpuFilter,result[i]);
                }
            }
        }
    } else {
        // printf("[Info] copy column\n");
        for(int i=0; i<attrNum; i++){
            result[i] = scanCol[i];
        }
    }

    // float * test = (float *)malloc(sizeof(float) * 128 * count);
    // cudaMemcpy(test, result[1], sizeof(float) * 128 * count, cudaMemcpyDeviceToHost);
    // for(int i = 0; i < 128; i++){
    //     printf("test[%d] = %f\n", i, test[i]);
    // }

    //End timer for Step 7 - Materialize result
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS7);
    pp->materializeResult_s7 += (endS7.tv_sec -  startS7.tv_sec)* BILLION + endS7.tv_nsec - startS7.tv_nsec;
   
        
    //Start timer for Step 8 - Copy final result
    struct timespec startS8, endS8;
    clock_gettime(CLOCK_REALTIME,&startS8);

    res->tupleSize = tupleSize;

    for(int i=0;i<attrNum;i++){

        int index = sn->outputIndex[i];
        // printf("dataPos[%d] = %d (49 MEM)\n", index, sn->tn->dataPos[index]);

        if(sn->tn->dataPos[index] == MEM || sn->tn->dataPos[index] == MMAP || sn->tn->dataPos[index] == PINNED)
            CUDA_SAFE_CALL_NO_SYNC(cudaFree(scanCol[i]));

        int colSize = res->tupleNum * res->attrSize[i];

        res->attrTotalSize[i] = colSize;
        res->dataFormat[i] = UNCOMPRESSED;

        if(sn->keepInGpu == 1){
            // printf("keepInGpu == 1 (yes)\n");
            res->dataPos[i] = GPU;
            res->content[i] = result[i];
        }else{
            res->dataPos[i] = MEM;
            res->content[i] = (char *)malloc(colSize);
            CHECK_POINTER(res->content[i]);
            memset(res->content[i],0,colSize);
            CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(res->content[i],result[i],colSize ,cudaMemcpyDeviceToHost));
            CUDA_SAFE_CALL(cudaFree(result[i]));
        }
    }

    //End timer for Step 8 - Copy final result
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS8);
    pp->finalResultMemCopy_s8 += (endS8.tv_sec -  startS8.tv_sec)* BILLION + endS8.tv_nsec - startS8.tv_nsec;

    // project result
    // 1.project distance_filter
    float * projectRes  = NULL;
    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **) &projectRes , sizeof(float) * count));

    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing

    for (int i = 0; i < disFilterCount; i++) {
        int projectIndex = dFilter[i].colIndex;
        // printf("\n[project] projectIndex = %d (1?)\n", projectIndex);
        // std::vector<float> search = dFilter[i].searchVec;
        std::vector<float> search = searchV;
        // for(int i = 0; i < search.size(); i++){
        //     printf("search[%d] = %f", i, search[i]);
        //     if(i % 10 == 0)
        //         printf("\n");
        // }
        // printf("\n");

        // cal L2 distance
        // tupleNum = count
        float *gpuSearch = NULL;
        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **) &gpuSearch , sizeof(float) * search.size()));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(gpuSearch, search.data(), sizeof(float) * search.size(), cudaMemcpyHostToDevice));
        int dim = res->attrSize[projectIndex] / sizeof(float);
        // printf("\n[project] dim = %d (128?)\n", dim);
        // printf("[project] count = %d (250?)\n\n", count);

        int blockSize = 256;
        int numBlocks = (count + blockSize - 1) / blockSize;
        L2distance<<<numBlocks, blockSize>>>(projectRes, gpuSearch, res->content[projectIndex], dim, count);
        CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
        // printf("After project res calculation!!! check the parameters and results!!!\n");

        // initial new "result[projectIndex]" column
        res->content[projectIndex] = (char*)projectRes;
        tupleSize = res->attrSize[projectIndex];
        res->attrType[projectIndex] = FLOAT;
        res->attrSize[projectIndex] = sizeof(float);
        res->attrTotalSize[projectIndex] = count * sizeof(float); 
        res->tupleSize += -tupleSize + sizeof(float);
    }

    // printf("there are %d tuples after where clause\n", res->tupleNum);
    // 2.project distance(v1, v2)
    struct disTwoColIndex2Res{
        int projectIndex; /*  */
        char *distanceTwoColRes = NULL;
    };
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing

    struct disTwoColIndex2Res *dTwoColIndex2Res = (struct disTwoColIndex2Res *)malloc(sizeof(struct disTwoColIndex2Res) * disTwoColProject);
    int projectTupleSize = 0;
    for (int i = 0; i < disTwoColProject; i++) {
        
        // test input
        // int output = 10;
        // float * test = (float *)malloc(sizeof(float) * 2048 * output);
        // cudaMemcpy(test, res->content[1], sizeof(float) * 2048 * output, cudaMemcpyDeviceToHost);
        // for(int i = 0; i < 2048 * output; i++){
        //     printf("[tableScan] column[%d] = %f\n", i, test[i]);
        // }
        // cudaMemcpy(test, res->content[2], sizeof(float) * 2048 * output, cudaMemcpyDeviceToHost);
        // for(int i = 0; i < 2048 * output; i++){
        //     printf("[tableScan] column[%d] = %f\n", i, test[i]);
        // }

        dTwoColIndex2Res[i].projectIndex = dTwoCol[i].projectIndex;
        CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **) &(dTwoColIndex2Res[i].distanceTwoColRes) , totalTupleNum * sizeof(float)));
        int dim = res->attrSize[dTwoCol[i].firstColIndex] / sizeof(float);
        CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing

        // printf("dTwoColIndex2Res[i].projectIndex = %d\n", dTwoColIndex2Res[i].projectIndex);
        // printf("sizeof resCol = %d * 4\n", count);
        // printf("dim = %d\n", dim);

        // printf("dTwoCol[i].firstColIndex = %d\n", dTwoCol[i].firstColIndex);
        // printf("dTwoCol[i].secondColIndex = %d\n", dTwoCol[i].secondColIndex);
        twoColL2Distance<<<grid, block>>>(dTwoColIndex2Res[i].distanceTwoColRes, res->content[dTwoCol[i].firstColIndex], res->content[dTwoCol[i].secondColIndex], dim, count);
        CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    }

    struct tableNode *projectResTable = NULL;
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    if(disTwoColProject != 0){
        if(host_mp == NULL){
            projectResTable = (struct tableNode *) malloc(sizeof(struct tableNode));
            CHECK_POINTER(projectResTable);
        }else
            projectResTable = (struct tableNode *) host_mp->alloc(sizeof(struct tableNode));

        projectResTable->totalAttr = sn->outputNum - disTwoColProject;
        projectResTable->tupleNum = totalTupleNum;

        if(host_mp == NULL) {
            projectResTable->attrType = (int *) malloc(sizeof(int) * projectResTable->totalAttr);
            CHECK_POINTER(projectResTable->attrType);
            projectResTable->attrSize = (int *) malloc(sizeof(int) * projectResTable->totalAttr);
            CHECK_POINTER(projectResTable->attrSize);
            projectResTable->attrTotalSize = (int *) malloc(sizeof(int) * projectResTable->totalAttr);
            CHECK_POINTER(projectResTable->attrTotalSize);
            projectResTable->attrIndex = (int *) malloc(sizeof(int) * projectResTable->totalAttr);
            CHECK_POINTER(projectResTable->attrIndex);
            projectResTable->dataPos = (int *) malloc(sizeof(int) * projectResTable->totalAttr);
            CHECK_POINTER(projectResTable->dataPos);
            projectResTable->dataFormat = (int *) malloc(sizeof(int) * projectResTable->totalAttr);
            CHECK_POINTER(res->dataFormat);
            projectResTable->content = (char **) malloc(sizeof(char *) * projectResTable->totalAttr);
            CHECK_POINTER(projectResTable->content);
        }else{
            projectResTable->attrType = (int *) host_mp->alloc(sizeof(int) * projectResTable->totalAttr);
            projectResTable->attrSize = (int *) host_mp->alloc(sizeof(int) * projectResTable->totalAttr);
            projectResTable->attrTotalSize = (int *) host_mp->alloc(sizeof(int) * projectResTable->totalAttr);
            projectResTable->attrIndex = (int *) host_mp->alloc(sizeof(int) * projectResTable->totalAttr);
            projectResTable->dataPos = (int *) host_mp->alloc(sizeof(int) * projectResTable->totalAttr);
            projectResTable->dataFormat = (int *) host_mp->alloc(sizeof(int) * projectResTable->totalAttr);
            projectResTable->content = (char **) host_mp->alloc(sizeof(char *) * projectResTable->totalAttr);
        }

        CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing

        printf("\n[projectResTable] totalAttr = %d\n", projectResTable->totalAttr);

        for(int i=0;i<projectResTable->totalAttr;i++){
            int proIndex = sn->projectIndex[i];
            if(proIndex < 100){
                int index = sn->outputIndex[i];
                projectResTable->attrType[i] = res->attrType[index];
                projectResTable->attrSize[i] = res->attrSize[index];
                projectResTable->attrTotalSize[i] = res->attrTotalSize[index];
                projectResTable->attrIndex[i] = res->attrIndex[index];
                projectResTable->dataPos[i] = res->dataPos[index];
                projectResTable->dataFormat[i] = res->dataFormat[index];
                projectResTable->content[i] = res->content[index];
                res->content[index] = NULL;
                projectTupleSize += res->attrSize[index];
            }
            else{
                int index = proIndex-100;
                projectResTable->attrType[i] = FLOAT;
                printf("[projectResTable] attrType[%d] = FLOAT\n", i);
                projectResTable->attrSize[i] = sizeof(float);
                projectResTable->attrTotalSize[i] =  projectResTable->tupleNum * sizeof(float);
                projectResTable->attrIndex[i] = i; // right??
                projectResTable->dataPos[i] = GPU;
                projectResTable->dataFormat[i] = UNCOMPRESSED;
                int tmp = -1;
                for(int k = 0; k < disTwoColProject; k++){
                    if(dTwoColIndex2Res[k].projectIndex == index){
                        tmp = k;
                        break;
                    }
                }
                // printf("tmp = %d\n", tmp);
                projectResTable->content[i] = dTwoColIndex2Res[tmp].distanceTwoColRes;
                dTwoColIndex2Res[tmp].distanceTwoColRes = NULL;
                projectTupleSize += sizeof(float);
            }
        }
        projectResTable->tupleSize = projectTupleSize;
    }

    //Start timer for Other - 03 (deallocate buffers)
    struct timespec startS03,endS03;
    clock_gettime(CLOCK_REALTIME,&startS03);
    if(dev_mp == NULL){
        CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuPsum));
        CUDA_SAFE_CALL_NO_SYNC(cudaFree(gpuFilter));
    }
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    
    if(host_mp == NULL){
        free(whereFree);
        free(colWherePos);
        free(column);
        free(scanCol);
        free(result);
    }
    //Stop timer for Other - 01 (tableScan)
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME, &endS03);
    pp->deallocateBuffs_S03 += (endS03.tv_sec - startS03.tv_sec)* BILLION + endS03.tv_nsec - startS03.tv_nsec;

    //Stop timer (Global tableScan())
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait to ensure correct timing
    clock_gettime(CLOCK_REALTIME,&endTableScanTotal);
    pp->tableScanTotal += (endTableScanTotal.tv_sec -  startTableScanTotal.tv_sec)* BILLION + endTableScanTotal.tv_nsec - startTableScanTotal.tv_nsec;
    pp->tableScanCount ++;

    // if(sn->filter != NULL and sn->filter->exp[0].relation == KNN){
    //     char disArray[2048];
    //     char intArray[2048];
    //     printf("[tableScan.cu] the type of result[0] :%d\n", res->attrType[0]);
    //     cudaMemcpy(disArray, res->content[0], sizeof(char) * res->attrSize[0] * res->tupleNum, cudaMemcpyDeviceToHost);
    //     for(int i = 0; i < res->tupleNum; i++){
    //         printf("[tableScan.cu] tableName[%d] = ", i);
    //         for(int j = 0; j < 23; j++){
    //             printf("%c", disArray[i*23 + j]);
    //         }
    //         printf("\n");
    //     }
    // }
    

    if(disTwoColProject != 0){
        printf("[tableScan.cu] outputTable tupleNum = %ld\n", projectResTable->tupleNum);
        clock_gettime(CLOCK_REALTIME,&e);
        tt = (e.tv_sec - s.tv_sec)* BILLION + e.tv_nsec - s.tv_nsec;
        printf("tt = %f\n", tt/(1000*1000));
        printf("TableScan Time: %lf\n", pp->tableScanTotal/(1000*1000));
        return projectResTable;
    }

    printf("res->tupleNum = %ld\n", res->tupleNum);

    clock_gettime(CLOCK_REALTIME,&e);
    tt = (e.tv_sec - s.tv_sec)* BILLION + e.tv_nsec - s.tv_nsec;
    printf("tt = %f\n", tt/(1000*1000));
    printf("<--TableScan Time -->    : %lf\n\n", pp->tableScanTotal/(1000*1000));
    return res;
}

/*
 * Creates sorted index for the selected column
 * 
 * --Input--
 * tn -> Table node
 * idxPos -> Position of the indexed column in contentIdx and posIdx
 * columnPos -> Column to be sorted
 *
 * --Output--
 * tn.contentIdx (sorted values)
 * tn.posIdx (position in the original table )
 */
void createIndex (struct tableNode *tn, int idxPos, int columnPos, struct statistic *pp){

    //Start timer for build index
    struct timespec startIdxBuildTime, endIdxBuildTime;
    clock_gettime(CLOCK_REALTIME,&startIdxBuildTime);
 
    //Check assumption (INT enum == 4)
    if (tn->attrType[columnPos] != 4 ){
        printf("[ERROR] Indexing is only supported for INT type!\n");
        exit(-1);
    }
    if (tn->attrSize[columnPos] != sizeof(int)){
        printf("[ERROR] Indexing is only supported for INT type (and size!)!\n");
        exit(-1); 
    }

    //Define Grid and block size
    dim3 grid(2048);
    dim3 block(256);

    //Get data size
    long dataSize = sizeof(int) * tn->tupleNum;

    //Allocate memory for the index (in host)
    tn->contentIdx[idxPos] = (int *)malloc(dataSize); 
    CHECK_POINTER(tn->contentIdx[idxPos]);
    tn->posIdx[idxPos] = (int *)malloc(sizeof(int) * tn->tupleNum); 
    CHECK_POINTER(tn->posIdx[idxPos]);


    //Assign index (in device)
    int* posIdx_d;
    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&posIdx_d, sizeof(int) * tn->tupleNum));
    assign_index<<<grid,block>>>(posIdx_d, tn->tupleNum);


    //Copy values (in device)
    int* contentIdx_d;
    CUDA_SAFE_CALL_NO_SYNC(cudaMalloc((void **)&contentIdx_d, dataSize));
    CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(contentIdx_d, tn->content[columnPos], dataSize, cudaMemcpyHostToDevice));

    //Sort columns
    thrust::sort_by_key(thrust::device, contentIdx_d, contentIdx_d + tn->tupleNum, posIdx_d); //thrust inplace sorting
    CUDA_SAFE_CALL(cudaDeviceSynchronize()); //need to wait for short (or SEGFAULT)

    if (tn->keepInGpuIdx){

        //De-allocate host memory
        free(tn->contentIdx[idxPos]);
        free(tn->posIdx[idxPos]);

        //Store Device pointers
        tn->contentIdx[idxPos] = contentIdx_d;
        tn->posIdx[idxPos] = posIdx_d;

        //Set position
        tn->indexPos = GPU;

    }else{
        
        //Copy index to host
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(tn->contentIdx[idxPos], contentIdx_d, dataSize, cudaMemcpyDeviceToHost));
        CUDA_SAFE_CALL_NO_SYNC(cudaMemcpy(tn->posIdx[idxPos], posIdx_d, sizeof(int) * tn->tupleNum, cudaMemcpyDeviceToHost)); 
    
        //De-allocate device memory
        CUDA_SAFE_CALL_NO_SYNC(cudaFree(contentIdx_d));
        CUDA_SAFE_CALL_NO_SYNC(cudaFree(posIdx_d));
        
        //Set position
        tn->indexPos = MEM;
    }

    //Stop and add 
    clock_gettime(CLOCK_REALTIME, &endIdxBuildTime);
    pp->buildIndexTotal += (endIdxBuildTime.tv_sec -  startIdxBuildTime.tv_sec)* BILLION + endIdxBuildTime.tv_nsec - startIdxBuildTime.tv_nsec;
}
