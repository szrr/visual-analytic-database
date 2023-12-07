def calculate_average_from_AP():
    with open('AP.txt', 'r') as file:
        lines = file.readlines()

    float_values = []

    for line in lines:
        split_line = line.split()
        if len(split_line) > 1:  # 检查这行是否有足够的列
            try:
                float_values.append(float(split_line[1]))
            except ValueError:
                pass  # 如果第二列不是一个float，就跳过

    average = sum(float_values) / len(float_values) if float_values else 0
    return average


with open('mAP.txt', 'a') as file:
    file.write(f'mAP = {calculate_average_from_AP()}\n')