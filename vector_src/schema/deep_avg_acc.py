def calculate_average_acc():
    with open('../../benchmark/deep_acc.txt', 'r') as file:
        lines = file.readlines()

    float_values = []

    for line in lines:
        try:
            print(float(line))
            float_values.append(float(line))
        except ValueError:
            pass  # 如果第二列不是一个float，就跳过

    average = sum(float_values) / len(float_values) if float_values else 0
    return average

print("avg_acc =", calculate_average_acc())