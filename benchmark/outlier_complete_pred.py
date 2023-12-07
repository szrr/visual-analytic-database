import sys
def generate_complete_file(max_id, filename="outlier_pred.txt", output_filename="outlier_pred_complete.txt"):
    # 将存在的ID和它们的值读入一个字典
    existing_ids = {}
    with open(filename, "r") as f:
        for line in f:
            idx, value = line.strip().split()
            existing_ids[int(idx)] = float(value)

    # 创建一个输出文件并写入补充的ID和值
    with open(output_filename, "a") as f:
        for i in range(1, max_id+1):
            if i in existing_ids:
                f.write(f"{i} {existing_ids[i]:.6f}\n")
            else:
                f.write(f"{i} 0.000000\n")

max_id = sys.argv[1]
generate_complete_file(int(max_id))