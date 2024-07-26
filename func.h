#pragma once

#include <string>

int calc(int x, int y);

inline
int calc2(int x)
{
    std::string s2(x, 'b');
    s2.resize(x / 2);
    return s2.size();
}
