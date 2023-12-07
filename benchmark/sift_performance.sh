


total_time=0

cd ../src/cuda
rm -rf driver.cu
cp driver_sift_performance.cu driver.cu
make

cd ../../benchmark
for ((i=$1; i<$2; i++)); do
    echo $i
    # python init new vector_src/init_vector/videoFeatures
    python3 init_sift_search_vector.py $i

    cd ../src/cuda
    ./GPUDATABASE --datadir /home/szr/subquery/vector_src/schema > run.log
    elapsed_time=$(awk '/Total Time:/ {print $3}' run.log)
    total_time=$(echo "$total_time + $elapsed_time" | bc)
    cd ../../benchmark
done
result=$(($2-$1))
avg_time=$(echo "scale=2; $total_time / $result" | bc)
echo "Total execution time for $result operations: total $total_time ms, avg $avg_time ms"
