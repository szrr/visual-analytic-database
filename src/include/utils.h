#ifndef UTILS_H
#define UTILS_H

#include <string>
#include <vector>

void readFloatArray(std::vector<float>&, char*);

bool fileExists(const std::string& filename);

double elapsed();

#endif
