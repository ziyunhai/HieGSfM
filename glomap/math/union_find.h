#pragma once
#include <cstdint>
#include <unordered_map>

namespace glomap {

// UnionFind class to maintain disjoint sets for creating tracks
template <typename DataType>
class UnionFind {
 public:
  // Find the root of the element x
  DataType Find(DataType x) { // key 2: 递归调用，找到根节点，
    // If x is not in parent map, initialize it with x as its parent
    auto parentIt = parent_.find(x);
    if (parentIt == parent_.end()) { // 没有找到
      parent_.emplace_hint(parentIt, x, x); // 在指定位置插入键值对
      return x;
    }
    // Path compression: set the parent of x to the root of the set containing x
    // 路径压缩： 当查找某个元素的根节点时，将路径上所有节点的父节点直接指向根节点，从而在未来的查询中减少访问深度，提高效率
    if (parentIt->second != x) { // 检查x自己是否是父节点，不是则递归查找其根节点
      parentIt->second = Find(parentIt->second); // 递归调用Find,找到x所属集合的根节点，->second表示根节点
    }
    return parentIt->second;
  }

  // Unite the sets containing x and y
  void Union(DataType x, DataType y) {
    DataType root_x = Find(x);
    DataType root_y = Find(y);
    if (root_x != root_y) parent_[root_x] = root_y; // 把root_x的根节点赋值为root_y
  }

  void Clear() { parent_.clear(); }

 private:
  // Map to store the parent of each element
  std::unordered_map<DataType, DataType> parent_; // key 1: 定义数据结构，<id,root>,通过root判定是否是同一个set
};

}  // namespace glomap
