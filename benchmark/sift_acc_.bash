cd ../src/cuda
rm -rf tableScan.cu
cp tableScan_IVFFlat_L2.cu tableScan.cu
rm -rf driver.cu
cp driver_sift_acc.cu driver.cu
make
./GPUDATABASE --datadir ../../vector_src/schema