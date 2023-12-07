import struct

binary_file_path = 'video_pred.bin'
txt_file_path = 'video_pred.txt'

data = []

with open(binary_file_path, 'rb') as bin_file:
    while True:
        char_array = bin_file.read(23)
        float_bytes = bin_file.read(4)

        if not char_array or not float_bytes:
            break

        # 解码char数组和浮点数
        char_string = char_array.decode('utf-8')
        float_value = struct.unpack('f', float_bytes)[0]
        
        data.append((char_string, float_value))

# 对数据按照 float_value 进行排序
sorted_data = sorted(data, key=lambda x: x[1])

# 写入到txt文件
with open(txt_file_path, 'w') as txt_file:
    for idx, (char_string, float_value) in enumerate(sorted_data):
        if idx == len(sorted_data) - 1:
            txt_file.write(f"{char_string} {float_value}")
        else:
            txt_file.write(f"{char_string} {float_value}\n")