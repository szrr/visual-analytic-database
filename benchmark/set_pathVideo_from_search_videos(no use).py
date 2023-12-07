import sys

def insert_to_sql(i, txt_file, sql_file):
    # 获取txt文件的第i行
    with open(txt_file, 'r') as f:
        lines = f.readlines()
        video_name = lines[i].strip()

    # 读取SQL文件
    with open(sql_file, 'r') as f:
        sql_content = f.readlines()

    # 将视频名称写入SQL文件的第一行
    modified_line = f"select video_name, VIDEO_SIMILARITY(VIDEO_EXTRACTION(path\"/home/szr/subquery/gtvideos/{video_name}\"), d_feature) as score\n"
    sql_content[0] = modified_line

    # 修改SQL文件的第六行
    modified_line_6 = f"    where kNN(VIDEO_EXTRACTION(path\"/home/szr/subquery/gtvideos/{video_name}\"), d_feature) <= 20\n"
    sql_content[5] = modified_line_6

    # 保存修改后的SQL文件
    with open(sql_file, 'w') as f:
        f.writelines(sql_content)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python script_name.py index")
        sys.exit(1)

    index = int(sys.argv[1])  # 因为数组索引从0开始
    insert_to_sql(index, "search_videos.txt", "../vector_src/sql/pathVideo1.sql")