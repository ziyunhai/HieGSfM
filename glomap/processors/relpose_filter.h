
#pragma once

#include "glomap/scene/types_sfm.h"

namespace glomap {

class TwoViewInfo {
 public:
  TwoViewInfo()
      : position_2(Eigen::Vector3d::Zero()),
        rotation_2(Eigen::Vector3d::Zero()),
        visibility_score(1) {}

  Eigen::Vector3d position_2;
  Eigen::Vector3d rotation_2;

  // The visibility score is computed based on the inlier features from 2-view
  // geometry estimation. This score is similar to the number of verified
  // matches, but has a spatial weighting to encourage good coverage of the
  // image by the inliers. The visibility score here is the sum of the
  // visibility scores for each image.
  int visibility_score;
};

struct RelPoseFilter {
  // Filter relative pose based on rotation angle
  // max_angle: in degree
  static void FilterRotations(ViewGraph& view_graph,
                              const std::unordered_map<image_t, Image>& images,
                              double max_angle = 5.0);

  // Filter relative pose based on number of inliers
  // min_inlier_num: in degree
  static void FilterInlierNum(ViewGraph& view_graph, int min_inlier_num = 30);

  // Filter relative pose based on rate of inliers
  // min_weight: minimal ratio of inliers
  static void FilterInlierRatio(ViewGraph& view_graph,
                                double min_inlier_ratio = 0.25);

  static void FilterTripletConsistency(ViewGraph& view_graph,
                                       double max_loop_error = 5.0);
};

}  // namespace glomap
