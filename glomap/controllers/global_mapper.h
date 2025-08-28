#pragma once

#include "glomap/controllers/track_establishment.h"
#include "glomap/controllers/track_retriangulation.h"
#include "glomap/estimators/bundle_adjustment.h"
#include "glomap/estimators/global_positioning.h"
#include "glomap/estimators/global_rotation_averaging.h"
#include "glomap/estimators/relpose_estimation.h"
#include "glomap/estimators/view_graph_calibration.h"
#include "glomap/types.h"

#include <colmap/scene/database.h>
#include <colmap/scene/reconstruction_manager.h>
#include "colmap/util/threading.h"

namespace glomap {

struct GlobalMapperOptions {
  // Options for each component
  ViewGraphCalibratorOptions opt_vgcalib;
  RelativePoseEstimationOptions opt_relpose;
  RotationEstimatorOptions opt_ra;
  TrackEstablishmentOptions opt_track;
  GlobalPositionerOptions opt_gp;
  BundleAdjusterOptions opt_ba;
  TriangulatorOptions opt_triangulator;

  // Inlier thresholds for each component
  InlierThresholdOptions inlier_thresholds;

  // Control the number of iterations for each component
  int num_iteration_bundle_adjustment = 2; //3;
  int num_iteration_retriangulation = 1;

  // Control the flow of the global sfm
  bool skip_preprocessing = false;
  bool skip_view_graph_calibration = false;
  bool skip_relative_pose_estimation = false;
  bool skip_rotation_averaging = false;
  bool skip_track_establishment = false;
  bool skip_global_positioning = false;
  bool skip_bundle_adjustment = false;
  bool skip_retriangulation = true;
  bool skip_pruning = true; //true

  // Which images to reconstruct. If no images are specified, all images will
  // be reconstructed by default.
  std::unordered_set<image_t> image_set_ids_;
};

class GlobalMapper : public colmap::Thread {
 public:
  GlobalMapper(const GlobalMapperOptions& options) : options_(options) {}
  GlobalMapper(const GlobalMapperOptions& options,
               const std::string& databasepath,
               const std::string& imagepath,
               std::shared_ptr<colmap::ReconstructionManager> reconstruction_manager) : options_(options),
               database_path_(databasepath), imagepath_(imagepath), reconstruction_manager_(std::move(reconstruction_manager)) {}

  void Run();
  bool Solve(const colmap::Database& database,
             ViewGraph& view_graph,
             std::unordered_map<camera_t, Camera>& cameras,
             std::unordered_map<image_t, Image>& images,
             std::unordered_map<track_t, Track>& tracks);

 private:
  const GlobalMapperOptions options_;
  // const colmap::Database& database_;
  const std::string database_path_;
  const std::string imagepath_;
  std::shared_ptr<colmap::ReconstructionManager> reconstruction_manager_;

};

}  // namespace glomap
