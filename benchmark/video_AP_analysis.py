def analyse_AP():
    count = 0
    with open('AP.txt', 'r') as file:
        lines = file.readlines()

    with open('AP_badcases1.txt', 'w') as bad_cases_file:
        for line in lines:
            split_line = line.split()
            if len(split_line) > 1:  # 检查这行是否有足够的列
                try:
                    if float(split_line[1]) <= 0.5:
                        count += 1
                        bad_cases_file.write(line)
                except ValueError:
                    pass  # 如果第二列不是一个float，就跳过

    print("count = ", count)

def analyse_badcases():
    count = 0
    ap = []
    with open('AP.txt', 'r') as file:
        lines = file.readlines()

    for line in lines:
        split_line = line.split()
        if len(split_line) > 1:  # 检查这行是否有足够的列
            try:
                if float(split_line[1]) <= 0.5:
                    count += 1
                    ap.append(float(1.0))
                else:
                    ap.append(float(split_line[1]))
            except ValueError:
                pass  # 如果第二列不是一个float，就跳过

    average = sum(ap) / len(ap) if ap else 0
    
    print("count =", count)
    print("avg =", average)

analyse_AP()
analyse_badcases()