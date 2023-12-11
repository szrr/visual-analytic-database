#include <iostream>
#include <fstream>
#include <vector>

int main() {
    const char* path = "videoFeatures";  // Python 写入的二进制文件的路径

    std::ifstream file(path, std::ios::binary);  // 打开二进制文件

    if (!file) {
        std::cerr << "Error opening file: " << path << std::endl;
        return 1;
    }

    // 获取文件大小
    file.seekg(0, std::ios::end);
    std::streampos fileSize = file.tellg();
    file.seekg(0, std::ios::beg);

    // 计算数组元素数量
    std::size_t count = fileSize / sizeof(float);

    // 创建一个存储读取数据的 vector
    std::vector<float> data(count);

    // 读取数据到 vector
    file.read(reinterpret_cast<char*>(data.data()), fileSize);

    // 关闭文件
    file.close();

    // 在这里，你可以对读取到的数据进行处理，根据之前的 reshape 操作恢复数组的原始形状。

    // 输出读取的数据
    int count0 = 0;
    for (float value : data) {
        std::cout << value << " ";
        count0 += 1;
        if(count0 >= 10)
            break;
    }
    std::cout << std::endl;

    return 0;
}
