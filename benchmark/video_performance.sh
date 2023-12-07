total_time=0

cd ../src/cuda
rm -rf driver.cu
cp driver_video_performance.cu driver.cu
make

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
avg_time=$(echo "scale=2; $total_time / $result" | bc)
echo "Total execution time for $result operations: total $total_time ms, avg $avg_time ms"
