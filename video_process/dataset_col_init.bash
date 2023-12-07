# current path must be /your/path/to/subquery

cd ./video_process

# $1:/mnt/data1/svddataset/videos/segment_64
# initial video_name, frame_id and features
# python3 dataset_video_column_initial.py $1

cd ./searchVideo/searchColumns
# $2:tableName
./initText -p video_name.txt -d 23 -n "$2"0
./initInt -p frame_id.npy -n "$2"1
# ./initVec -p features.npy -d 2048 -n "$2"2
./initVec -p features.npy -d 128 -n "$2"2

cp "$2"0 ../../../vector_src/schema
cp "$2"1 ../../../vector_src/schema
cp "$2"2 ../../../vector_src/schema