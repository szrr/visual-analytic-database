cd ./video_process
python3 search_video_column_initial.py $1
cd ./searchVideo/searchColumns

# do
#   # 使用 tr 命令将参数中的英文转换为大写
#   upper_arg=$(echo "$2" | tr '[:lower:]' '[:upper:]')
#   echo "$upper_arg"
# done

./initInt -p frame_id.npy -n "$2"0
./initVec -p features.npy -d 2048 -n "$2"1
cp "$2"0 ../../../vector_src/schema
cp "$2"1 ../../../vector_src/schema