
OS_SIZE = $(shell uname -m | sed -e "s/i.86/32/" -e "s/x86_64/64/")
NODE_NAME = $(shell uname -n)

#CUDA_PATH       ?= /usr/local/cuda
# ifeq ($(NODE_NAME),DL190)
# CUDA_PATH       ?= /mnt/sda2/sofoklis/cuda_drivers/cuda-10.0
# else
# CUDA_PATH       ?= /opt/cuda/10.0
# endif
# CUDA_INC_PATH   ?= $(CUDA_PATH)/include
# CUDA_BIN_PATH   ?= $(CUDA_PATH)/bin

CUDA_PATH       ?= /usr/local/cuda
CUDA_INC_PATH   ?= $(CUDA_PATH)/include
CUDA_BIN_PATH   ?= $(CUDA_PATH)/bin

ifeq ($(OS_SIZE),32)
    CUDA_LIB_PATH  ?= $(CUDA_PATH)/lib
else
    CUDA_LIB_PATH  ?= $(CUDA_PATH)/lib64
endif

NVCC            ?= $(CUDA_BIN_PATH)/nvcc

# GENCODE_SM20    := -gencode arch=compute_20,code=sm_20
# GENCODE_SM30    := -gencode arch=compute_30,code=sm_30 -gencode arch=compute_35,code=sm_35
# GENCODE_SM61    := -gencode arch=compute_61,code=sm_61
# GENCODE_SM70    := -gencode arch=compute_70,code=sm_70
GENCODE_SM80    := -gencode arch=compute_80,code=sm_80
# GENCODE_FLAGS   := $(GENCODE_SM20) $(GENCODE_SM30)
# ifeq ($(NODE_NAME),DL190)
# GENCODE_FLAGS   := $(GENCODE_SM61)
# else
# GENCODE_FLAGS   := $(GENCODE_SM70)
# endif
GENCODE_FLAGS   := $(GENCODE_SM80)

ifeq ($(OS_SIZE),32)
    LDFLAGS   := -lcudart -lrt
else
    LDFLAGS   := -lcudart -lrt -lfaiss -lmkl_intel_lp64 -lmkl_intel_thread -lmkl_core -llapack -lcublas -lpthread -lm -ldl -liomp5
endif

SRCS := tableScan.cu inviJoin.cu hashJoin.cu cuckoo.cu materialize.cu groupby.cu orderby.cu driver.cu Mempool.cu knnJoin.cu cartesianProductJoin.cu utils.cu
OBJS := $(SRCS:.cu=.o)
DEPS := $(SRCS:.cu=.d)

all: GPUDATABASE

GPUDATABASE: $(OBJS)
	$(NVCC) -pg -g -G $^ $(LDFLAGS) -o $@

-include $(DEPS)
%.d: %.cu
	@set -e; rm -f $@; \
	$(NVCC) -M $(GENCODE_FLAGS) $< > $@.$$$$; \
	sed 's,\($*\)\.o[ :]*,\1.o $@ : ,g' < $@.$$$$ > $@; \
	rm -f $@.$$$$

%.o: %.cu
	$(NVCC) -c -g -G $(GENCODE_FLAGS) $<

clean:
	rm -rf *.d *.o GPUDATABASE
