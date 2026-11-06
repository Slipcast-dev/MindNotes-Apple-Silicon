#include <iostream>
#include <vector>

// Sum of the numbers in a vector.
template <typename T>
T sum(const std::vector<T>& values) {
    T total{};
    for (const auto& v : values) total += v;
    return total;
}

int main() {
    std::vector<int> numbers{1, 2, 3, 0x10};
    std::cout << "sum = " << sum(numbers) << std::endl;
    return 0;
}
