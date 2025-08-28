#pragma once
#include "glomap/controllers/option_manager.h"

namespace glomap {
class HierarchicalGlobalMapper {
 public:
  HierarchicalGlobalMapper() {}

  bool Run(const colmap::Database& database,
           OptionManager& options);
};
}