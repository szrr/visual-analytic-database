arr=("176" "176" "146" "176" "146" "176" "176" "176" "116" "146" "176" "176")

# 1. compile outlierNew.sql, init driver.cu
# python2 translate.py vector_src/sql/outlierNew.sql vector_src/schema/vector.schema # init driver.cu (physical query plan)

# 2. add output codes to driver.cu and compile it

> outlier_pred_complete.txt

cd ../src/cuda
rm driver.cu
cp driver_outlier_acc.cu driver.cu
make

cd ../../outlier_process/columns
for ((i=0; i<12; i++)); do
    # 3. init columns from .npy files
    # TRAIN_VIDEO|TRAIN_FEATURE:VECTOR:19
    # TEST_VIDEO|FRAME_ID:INTEGER|OBJECT_ID:INTEGER|TEST_FEATURE:VECTOR:19
    ./initInt -p testIdCol$i.npy -n TEST_VIDEO0
    ./initInt -p testObjIdCol$i.npy -n TEST_VIDEO1
    ./initVec -p testVecCol$i.npy -n TEST_VIDEO2 -d 19
    cd ../..
    rm ./vector_src/schema/TEST_VIDEO0
    rm ./vector_src/schema/TEST_VIDEO1
    rm ./vector_src/schema/TEST_VIDEO2
    cp ./outlier_process/columns/TEST_VIDEO0 ./vector_src/schema/
    cp ./outlier_process/columns/TEST_VIDEO1 ./vector_src/schema/
    cp ./outlier_process/columns/TEST_VIDEO2 ./vector_src/schema/

    # 4. run src/cuda/GPUDATABASE
    cd ./src/cuda
    ./GPUDATABASE --datadir ../../vector_src/schema
    cd ../../benchmark
    python3 outlier_complete_pred.py ${arr[i]}
    cd ../outlier_process/columns
done

# 5. calculate AuROC
cd ../../benchmark
python3 outlier_acc.py