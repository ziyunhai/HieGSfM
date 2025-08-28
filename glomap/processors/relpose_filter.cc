#include "glomap/processors/relpose_filter.h"

#include "glomap/math/rigid3d.h"
#include "glomap/processors/triplet_extractor.h"

#include <ceres/rotation.h>
#include "colmap/math/math.h"
namespace glomap {

double ComputeLoopRotationError(const Rigid3d& info_one_two,
                                const Rigid3d& info_one_three,
                                const Rigid3d& info_two_three) {
  // Get relative rotation matrices.
  Eigen::Matrix3d rotation1_2, rotation1_3, rotation2_3;
  rotation1_2 = info_one_two.rotation.toRotationMatrix();
  rotation1_3 = info_one_three.rotation.toRotationMatrix();
  rotation2_3 = info_two_three.rotation.toRotationMatrix();
  // Compute loop rotation.
  const Eigen::Matrix3d loop_rotation =
      rotation2_3 * rotation1_2 * rotation1_3.transpose();
  Eigen::Vector3d loop_rotation_angle_axis;
  ceres::RotationMatrixToAngleAxis(
      ceres::ColumnMajorAdapter3x3(loop_rotation.data()),
      loop_rotation_angle_axis.data());

  // Return the angle of the loop rotation which is the error of the
  // concatenated triplet rotation.
  return RadToDeg(loop_rotation_angle_axis.norm());
}

void RemoveTripletEdgesFromInvalidViewPairs(
    const std::tuple<image_t, image_t, image_t>& triplet,
    std::unordered_set<std::pair<image_t, image_t>>* invalid_image_pairs) {
  const std::pair<image_t, image_t> pair_01(std::get<0>(triplet), std::get<1>(triplet));
  const std::pair<image_t, image_t> pair_02(std::get<0>(triplet), std::get<2>(triplet));
  const std::pair<image_t, image_t> pair_12(std::get<1>(triplet), std::get<2>(triplet));
  invalid_image_pairs->erase(pair_01);
  invalid_image_pairs->erase(pair_02);
  invalid_image_pairs->erase(pair_12);
}

void RelPoseFilter::FilterRotations(
    ViewGraph& view_graph,
    const std::unordered_map<image_t, Image>& images,
    double max_angle) {
  int num_invalid = 0;
  for (auto& [pair_id, image_pair] : view_graph.image_pairs) {
    if (image_pair.is_valid == false) continue;

    const Image& image1 = images.at(image_pair.image_id1);
    const Image& image2 = images.at(image_pair.image_id2);

    if (image1.is_registered == false || image2.is_registered == false) {
      continue;
    }

    Rigid3d pose_calc = image2.cam_from_world * Inverse(image1.cam_from_world);

    double angle = CalcAngle(pose_calc, image_pair.cam2_from_cam1);
    if (angle > max_angle) {
      image_pair.is_valid = false;
      num_invalid++;
    }
  }

  LOG(INFO) << "Filtered " << num_invalid << " relative rotation with angle > "
            << max_angle << " degrees";
}

void RelPoseFilter::FilterInlierNum(ViewGraph& view_graph, int min_inlier_num) {
  int num_invalid = 0;
  for (auto& [pair_id, image_pair] : view_graph.image_pairs) {
    if (image_pair.is_valid == false) continue;

    if (image_pair.inliers.size() < min_inlier_num) {
      image_pair.is_valid = false;
      num_invalid++;
    }
  }

  LOG(INFO) << "Filtered " << num_invalid
            << " relative poses with inlier number < " << min_inlier_num;
}

void RelPoseFilter::FilterInlierRatio(ViewGraph& view_graph,
                                      double min_inlier_ratio) {
  int num_invalid = 0;
  for (auto& [pair_id, image_pair] : view_graph.image_pairs) {
    if (image_pair.is_valid == false) continue;

    if (image_pair.inliers.size() / double(image_pair.matches.rows()) <
        min_inlier_ratio) {
      image_pair.is_valid = false;
      num_invalid++;
    }
  }

  LOG(INFO) << "Filtered " << num_invalid
            << " relative poses with inlier ratio < " << min_inlier_ratio;
}

void RelPoseFilter::FilterTripletConsistency(ViewGraph& view_graph,
                              double max_loop_error_degrees) {
  // Initialize a list of invalid view pairs to all view pairs. View pairs
  // deemed valid will be removed from this list.
  
  std::unordered_set<std::pair<image_t, image_t>> invalid_image_pairs;
  std::unordered_map<std::pair<image_t, image_t>, Rigid3d> image_pairs;
  invalid_image_pairs.reserve(view_graph.image_pairs.size());
  for (const auto& [pair_id, image_pair] : view_graph.image_pairs) {
    invalid_image_pairs.insert(std::make_pair(image_pair.image_id1, image_pair.image_id2));
    image_pairs[std::make_pair(image_pair.image_id1, image_pair.image_id2)] = image_pair.cam2_from_cam1;
  }

  // Find all triplets.
  TripletExtractor<image_t> triplet_extractor;
  std::vector<std::vector<std::tuple<image_t, image_t, image_t>>> connected_triplets;
  CHECK(triplet_extractor.ExtractTriplets(invalid_image_pairs,
                                          &connected_triplets))
      << "Could not extract triplets from view pairs.";

  // Examine the cycles of size 3 to determine invalid view pairs from the
  // rotations.
  for (const auto& triplets : connected_triplets) {
    for (const std::tuple<image_t, image_t, image_t>& triplet : triplets) {
      const Rigid3d& info_one_two =
          image_pairs.at(std::pair<image_t, image_t>(std::get<0>(triplet), std::get<1>(triplet)));
      const Rigid3d& info_one_three =
          image_pairs.at(std::pair<image_t, image_t>(std::get<0>(triplet), std::get<2>(triplet)));
      const Rigid3d& info_two_three =
          image_pairs.at(std::pair<image_t, image_t>(std::get<1>(triplet), std::get<2>(triplet)));

      // Compute loop rotation error.
      const double loop_rotation_error_degrees = ComputeLoopRotationError(
          info_one_two, info_one_three, info_two_three);

      // Add the view pairs to the list of valid view pairs if the loop error is
      // within the designated tolerance.
      if (loop_rotation_error_degrees < max_loop_error_degrees) {
        RemoveTripletEdgesFromInvalidViewPairs(triplet, &invalid_image_pairs);
      }
    }
  }

  LOG(INFO) << "Removing " << invalid_image_pairs.size() << " of "
            << image_pairs.size()
            << " view pairs from loop rotation filtering.";

  // Remove any view pairs not in the list of valid edges.
  for (auto& [pair_id, image_pair] : view_graph.image_pairs) {
    if (image_pair.is_valid == false) continue;

    for (const std::pair<image_t, image_t>& image_pair_id : invalid_image_pairs) {
      if ((image_pair.image_id1 == image_pair_id.first && image_pair.image_id2 == image_pair_id.second) || (image_pair.image_id1 == image_pair_id.second && image_pair.image_id2 == image_pair_id.first))
        image_pair.is_valid = false;
    }
  }
}

}  // namespace glomap