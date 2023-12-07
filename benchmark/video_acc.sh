cd ..
python2 translate.py vector_src/sql/pathVideo1.sql vector_src/schema/vector.schema # init driver.cu (physical query plan)
cd src/cuda
# Insert the specified code into line 711
sed -i '702i\
    size_t size = 27 * result->tupleNum;\
    FILE *file = fopen("../../benchmark/video_pred.bin", "wb");\
    if (!file) {\
        perror("Failed to open file");\
        exit(1);\
    }\
    fwrite(final, 1, size, file);\
    fclose(file);
' driver.cu
make

total_time=0


cd ../../benchmark
for ((i=$1; i<$2; i++)); do
    echo $i
    # python init new vector_src/init_vector/videoFeatures
    python3 video_feature_extraction.py $i ../vector_src/init_vector/videoFeatures

    cd ../src/cuda
    ./GPUDATABASE --datadir /home/szr/subquery/vector_src/schema > run.log
    elapsed_time=$(awk '/Total Time:/ {print $3}' run.log)
    total_time=$(echo "$total_time + $elapsed_time" | bc)
    cd ../../benchmark
    # cal acc
    python3 video_pred_acc.py
    python3 video_AP.py $i
done
result=$(($2-$1))
echo "Total execution time for $result operations: $total_time millisecond"
# python3 avg_AP.py