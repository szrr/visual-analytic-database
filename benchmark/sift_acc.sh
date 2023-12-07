
# init executable file "src/cuda/GPUDATABASE"
cd ..
python2 translate.py vector_src/sql/sift.sql vector_src/schema/vector.schema # init driver.cu (physical query plan)
cd src/cuda
sed -i "458i\\
    printf(\"siftres\\\n\");\\
    FILE *file = fopen(\"../../benchmark/output.txt\", \"w\");\\
    for(int i = 0; i < $2; i++){\\
        fprintf(file, \"%d\\\n\", ((int*)final)[2*i] - 1);\\
    }\\
    fclose(file);\\
" driver.cu
make # compile driver.cu && init GPUDATABASE

total_time=0

cd ../../benchmark
for ((i=0; i<$1; i++)); do
    echo $i
    # init sift search vector
    python3 init_sift_search_vector.py $i
    cd ../src/cuda

    # execute GPUDATABASE and get total time
    ./GPUDATABASE --datadir /home/szr/subquery/vector_src/schema > run.log
    elapsed_time=$(awk '/Total Time:/ {print $3}' run.log)
    total_time=$(echo "$total_time + $elapsed_time" | bc)
    cd ../../benchmark
    python3 sift_acc.py $i
done
echo "Total execution time for $1 operations: $total_time millisecond"
python3 sift_avg_acc.py

